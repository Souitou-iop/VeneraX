import Foundation
import CryptoKit

/// 磁盘 LRU 缓存（cache.db + 缓存目录）。与原版 CacheManager 职责一致：
/// 按 cacheKey 存取文件、过期清理、总大小上限（设置 `cacheSize` MB）。
/// 磁盘布局为本端内部实现（缓存不参与同步）。
///
/// 性能与一致性要点：
/// - init 不做全目录同步扫描（首次访问发生在图片下载路径上，逐文件 stat
///   会阻塞调用线程）；扫描+孤儿清理作为后台任务补齐 `currentSize`。
/// - `set` 的文件写入在锁外执行（原子写），锁内只做 DB 记录与账目更新，
///   大图片写盘不再串行化并发缓存读。
/// - 孤儿扫描只删除「修改时间早于扫描开始」的无记录文件，扫描期间新写入
///   的条目（记录或文件尚未互相可见）不会被误删。
public final class CacheManager: @unchecked Sendable {
    public static let shared = CacheManager()

    private let db: SQLiteDatabase
    private let directory: String
    private let lock = NSLock()
    /// 扫描完成前：本进程 set/delete 的增量账目（从 0 起步）。扫描完成后
    /// 合并「启动前旧文件总量」变为权威值。
    private var currentSize: Int = 0
    /// 初始目录扫描是否已完成（完成后 currentSize 为权威值）。
    private var initialScanCompleted = false

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
          last_access INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0
        )
        """)
        // 旧库迁移：size 列作为账目真相源（磁盘 attributes 在锁外原子写
        // 覆盖后会立即反映新大小，不能用于替换扣减）。存量行 size=0。
        let columns = (try? db.select("PRAGMA table_info(cache);")) ?? []
        let hasSizeColumn = columns.contains { $0["name"]?.textValue == "size" }
        if !hasSizeColumn {
            db.executeRaw("ALTER TABLE cache ADD COLUMN size INTEGER NOT NULL DEFAULT 0;")
        }
        // 后台补齐账目并清理孤儿（对齐原版启动扫描：删除无 DB 记录的残留
        // 文件，只统计有记录的）。完成前 get/set 的增量账目仍然正确。
        Task.detached(priority: .utility) { [weak self] in
            await self?.performInitialScan()
        }
    }

    private func filePath(_ dir: String, _ name: String) -> String {
        AppPaths.join(directory, dir, name)
    }

    private func hashKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 缓存文件的两段式 hash 路径形如 `<2位hex>/<64位hex>`。孤儿清理只处理
    /// 符合该形状的文件：Caches 目录可能被其他子系统使用，不能全删。
    private static let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{2}/[0-9a-f]{64}$")

    private static func isManagedCachePath(_ relativePath: String) -> Bool {
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        return hexPattern.firstMatch(in: relativePath, range: range) != nil
    }

    /// 启动后台扫描：对齐原版 `_scanDir` ——只统计 DB 有记录的「进程启动前
    /// 已存在」的文件（mtime 早于扫描开始），删除无记录的孤儿（崩溃残留、
    /// 外部清理留下的半文件等）。
    private func performInitialScan() {
        let scanStart = Date()
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
            lock.lock()
            initialScanCompleted = true
            lock.unlock()
            return
        }
        // 先枚举后快照 DB：枚举后才写入的记录必然能命中快照，其文件也
        // 因 mtime 晚于 scanStart 而不会被当作孤儿。
        var files: [(relative: String, size: Int, modified: Date)] = []
        for case let file as String in enumerator {
            guard Self.isManagedCachePath(file) else { continue }
            let absolute = AppPaths.join(directory, file)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: absolute),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = attributes[.size] as? Int,
                  let modified = attributes[.modificationDate] as? Date
            else { continue }
            files.append((file, size, modified))
        }
        var managed = Set<String>()
        if let rows = try? db.select("select dir, name from cache;") {
            for row in rows {
                if let dir = row["dir"]?.textValue, let name = row["name"]?.textValue {
                    managed.insert("\(dir)/\(name)")
                }
            }
        }
        var total = 0
        var orphans: [String] = []
        for file in files {
            if managed.contains(file.relative) {
                // 只统计启动前已存在的旧条目；启动后新写入的已计入
                // currentSize 增量账，合并时相加即权威值，不重复计算。
                if file.modified < scanStart {
                    total += file.size
                }
            } else if file.modified < scanStart {
                orphans.append(AppPaths.join(directory, file.relative))
            }
        }
        for orphan in orphans {
            try? FileManager.default.removeItem(atPath: orphan)
        }
        if !orphans.isEmpty {
            Log.info("Cache", "Removed \(orphans.count) unmanaged cache files")
        }
        lock.lock()
        if !initialScanCompleted {
            // currentSize 在扫描期间是本进程增量（0 起步），合并旧文件总量
            // 即权威值。极端时序（扫描期间替换/删除未入账旧文件）会留下
            // 一个有界的单向偏差，最坏效果是提前一轮 LRU 淘汰或 UI 数字
            // 暂时偏小，随后续写入收敛。
            currentSize += total
            initialScanCompleted = true
        }
        lock.unlock()
        evictIfNeeded()
    }

    /// 命中缓存返回文件 URL；过期则删除并返回 nil。
    public func get(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = try? db.selectFirst("select dir, name, expires from cache where key = ?;", [.text(key)]) else { return nil }
        guard let dir = row["dir"]?.textValue, let name = row["name"]?.textValue else { return nil }
        let expires = row["expires"]?.doubleValue ?? 0
        if expires > 0 && Date().timeIntervalSince1970 > expires {
            deleteUnlocked(key: key, dir: dir, name: name)
            return nil
        }
        let url = URL(fileURLWithPath: filePath(dir, name))
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 悬空记录（写入失败/文件被外部删除）自愈：连带账目一起清。
            deleteUnlocked(key: key, dir: dir, name: name)
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
    /// 文件写入在锁外（原子写自洽），锁内仅做 DB 记录与账目。
    public func set(_ key: String, _ data: Data, type: String? = nil, expires: TimeInterval = 0) {
        let hash = hashKey(key)
        let dir = String(hash.prefix(2))
        let name = hash
        let fileURL = URL(fileURLWithPath: filePath(dir, name))
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Cache", "Failed to write cache: \(error)")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        // 替换扣减以 DB size 列为准：文件已在锁外覆盖写入，此刻磁盘
        // attributes 反映的是新大小；DB 记录仍是替换前的旧值。并发同 key
        // 写入时 last-write-wins，账目随 DB 序列化保持精确。
        var oldSize = 0
        var oldURL: URL?
        if let existing = try? db.selectFirst("select dir, name, size from cache where key = ?;", [.text(key)]),
           let oldDir = existing["dir"]?.textValue, let oldName = existing["name"]?.textValue
        {
            oldURL = URL(fileURLWithPath: filePath(oldDir, oldName))
            oldSize = existing["size"]?.intValue ?? 0
        }
        // Replace accounting must subtract the old size even when the hashed
        // path is unchanged. Otherwise repeated refreshes inflate currentSize
        // and trigger premature eviction.
        if let oldURL, oldURL.path != fileURL.path {
            try? FileManager.default.removeItem(at: oldURL)
        }
        let accessTime = Int(Date().timeIntervalSince1970)
        let values: [SQLiteValue] = [
            .text(key), .text(dir), .text(name), .double(expires),
            type.map { .text($0) } ?? .null, .int(accessTime), .int(data.count)
        ]
        try? db.execute("""
        insert or replace into cache (key, dir, name, expires, type, last_access, size) values (?, ?, ?, ?, ?, ?, ?);
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
        // 先读后删：磁盘大小只在删除前可得。账目以 DB size 列为真相源
        // （并发 set 锁外覆盖写会让磁盘值提前变成新大小）；磁盘值仅兜底
        // 兼容迁移前的存量行（size=0）。
        let recorded = (try? db.selectFirst("select size from cache where key = ?;", [.text(key)]))?["size"]?.intValue ?? 0
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(atPath: path)
        try? db.execute("delete from cache where key = ?;", [.text(key)])
        currentSize = max(0, currentSize - (recorded > 0 ? recorded : onDisk))
    }

    /// 清空全部缓存。目录删除可能涉及上万文件，调用方（设置页）应在后台
    /// 任务中调用，避免阻塞主线程。
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        try? db.execute("delete from cache;")
        currentSize = 0
        // 清空后账目即权威，无需等待（可能已在运行的）初始扫描覆盖回 0。
        initialScanCompleted = true
    }

    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentSize
    }

    /// 上限变更后立即生效（对齐原版 setLimitSize）：淘汰当前已超限的部分，
    /// 而不是等到下一次写入才触发。设置页保存 cacheSize 后调用。
    public func applyLimit() {
        lock.lock()
        defer { lock.unlock() }
        evictIfNeeded()
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
