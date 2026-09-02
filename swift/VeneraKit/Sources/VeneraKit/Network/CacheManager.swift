import Foundation
import CryptoKit

/// 磁盘 LRU 缓存（cache.db + 缓存目录）。与原版 CacheManager 职责一致：
/// 按 cacheKey 存取文件、过期清理、总大小上限（设置 `cacheSize` MB）。
/// 磁盘布局为本端内部实现（缓存不参与同步）。
public final class CacheManager: @unchecked Sendable {
    public static let shared = CacheManager()

    private let db: SQLiteDatabase
    private let directory: String
    private let lock = NSLock()
    private var currentSize: Int = 0

    init(dataPath: String = AppPaths.dataPath, cachePath: String = AppPaths.cachePath) {
        let path = AppPaths.join(dataPath, "cache.db")
        db = DatabaseGateway.shared.openManagedRecovering(path)
        self.directory = cachePath
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: cachePath), withIntermediateDirectories: true)
        db.executeRaw("""
        CREATE TABLE IF NOT EXISTS cache (
          key TEXT PRIMARY KEY NOT NULL,
          dir TEXT NOT NULL,
          name TEXT NOT NULL,
          expires INTEGER NOT NULL,
          type TEXT,
          last_access INTEGER NOT NULL DEFAULT 0
        )
        """)
        currentSize = scanDirectory()
        evictIfNeeded()
    }

    private func filePath(_ dir: String, _ name: String) -> String {
        AppPaths.join(directory, dir, name)
    }

    private func hashKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func scanDirectory() -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return 0 }
        var total = 0
        for case let file as String in enumerator {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.join(directory, file)),
               (attributes[.type] as? FileAttributeType) == .typeRegular,
               let size = attributes[.size] as? Int
            {
                total += size
            }
        }
        return total
    }

    /// 命中缓存返回文件 URL；过期则删除并返回 nil。
    public func get(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = try? db.selectFirst("select * from cache where key = ?;", [.text(key)]) else { return nil }
        guard let dir = row["dir"]?.textValue, let name = row["name"]?.textValue else { return nil }
        let expires = row["expires"]?.doubleValue ?? 0
        if expires > 0 && Date().timeIntervalSince1970 > expires {
            deleteUnlocked(key: key, dir: dir, name: name)
            return nil
        }
        let url = URL(fileURLWithPath: filePath(dir, name))
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? db.execute("delete from cache where key = ?;", [.text(key)])
            return nil
        }
        // Touch on hit so eviction is genuinely least-recently-used rather
        // than oldest-expiry-first. Keep it inside the existing lock.
        let now = Int(Date().timeIntervalSince1970)
        try? db.execute("update cache set last_access = ? where key = ?;", [.int(now), .text(key)])
        return url
    }

    /// 读取缓存内容。
    public func getData(_ key: String) -> Data? {
        guard let url = get(key) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 写入缓存。expires 为秒级 Unix 时间戳（0 = 永不过期）。
    public func set(_ key: String, _ data: Data, type: String? = nil, expires: TimeInterval = 0) {
        lock.lock()
        defer { lock.unlock() }
        let hash = hashKey(key)
        let dir = String(hash.prefix(2))
        let name = hash
        let fileURL = URL(fileURLWithPath: filePath(dir, name))
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Capture the old size before the atomic write. For the same hashed
        // path, reading attributes afterwards would already return the new size.
        var oldSize = 0
        var oldURL: URL?
        if let existing = try? db.selectFirst("select dir, name from cache where key = ?;", [.text(key)]),
           let oldDir = existing["dir"]?.textValue, let oldName = existing["name"]?.textValue
        {
            oldURL = URL(fileURLWithPath: filePath(oldDir, oldName))
            oldSize = (try? FileManager.default.attributesOfItem(atPath: oldURL?.path ?? "")[.size] as? Int) ?? 0
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Cache", "Failed to write cache: \(error)")
            return
        }
        // Replace accounting must subtract the old file size even when the
        // hashed path is unchanged. Otherwise repeated refreshes inflate
        // currentSize and trigger premature eviction.
        if let oldURL, oldURL.path != fileURL.path {
            try? FileManager.default.removeItem(at: oldURL)
        }
        let accessTime = Int(Date().timeIntervalSince1970)
        let values: [SQLiteValue] = [
            .text(key), .text(dir), .text(name), .double(expires),
            type.map { .text($0) } ?? .null, .int(accessTime)
        ]
        try? db.execute("""
        insert or replace into cache (key, dir, name, expires, type, last_access) values (?, ?, ?, ?, ?, ?);
        """, values)
        currentSize = max(0, currentSize - oldSize + data.count)
        evictIfNeeded()
    }

    public func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let row = try? db.selectFirst("select dir, name from cache where key = ?;", [.text(key)]),
           let dir = row["dir"]?.textValue, let name = row["name"]?.textValue
        {
            deleteUnlocked(key: key, dir: dir, name: name)
        }
    }

    private func deleteUnlocked(key: String, dir: String, name: String) {
        let path = filePath(dir, name)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(atPath: path)
        try? db.execute("delete from cache where key = ?;", [.text(key)])
        currentSize = max(0, currentSize - fileSize)
    }

    /// 清空全部缓存。
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        try? db.execute("delete from cache;")
        currentSize = 0
    }

    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentSize
    }

    /// 超出设置上限时按过期时间从早到晚清理。
    private func evictIfNeeded() {
        let limitMB = AppData.shared.settings["cacheSize"].intValue ?? 2048
        let limit = limitMB * 1024 * 1024
        guard currentSize > limit else { return }
        let now = Int(Date().timeIntervalSince1970)
        // Expired entries first; among live entries evict least recently used.
        // Never-expiring entries sort last instead of starving expiring items.
        let rows = (try? db.select("""
            select key, dir, name, expires, last_access
            from cache
            order by
              case when expires > 0 and expires <= \(now) then 0 else 1 end asc,
              case when expires = 0 then 1 else 0 end asc,
              last_access asc,
              expires asc;
            """)) ?? []
        for row in rows {
            guard currentSize > limit else { break }
            guard let key = row["key"]?.textValue, let dir = row["dir"]?.textValue, let name = row["name"]?.textValue else { continue }
            deleteUnlocked(key: key, dir: dir, name: name)
        }
    }
}
