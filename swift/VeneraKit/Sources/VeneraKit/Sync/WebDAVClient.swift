import Foundation
import ZIPFoundation

/// WebDAV 客户端（Basic Auth + PROPFIND/GET/PUT/MKCOL），供数据同步与
/// 远程漫画库使用。对齐原版 webdav_client fork 的能力面。
public final class WebDAVClient: @unchecked Sendable {
    public let baseURL: URL
    public let username: String
    public let password: String
    private let session: URLSession

    public init(url: String, username: String, password: String) throws {
        var string = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.hasSuffix("/") { string += "/" }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            throw JSRuntimeException(message: "Invalid WebDAV URL: \(url)")
        }
        self.baseURL = url
        self.username = username
        self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    private func makeRequest(method: String, path: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw JSRuntimeException(message: "Invalid WebDAV path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JSRuntimeException(message: "Invalid response")
        }
        return (data, httpResponse)
    }

    /// 列出目录下的文件名（PROPFIND depth 1）。
    public func list(_ path: String = "/") async throws -> [String] {
        let body = """
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
        """
        var request = try makeRequest(method: "PROPFIND", path: path, body: Data(body.utf8))
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request)
        guard response.statusCode == 207 else {
            throw SyncError.http(status: response.statusCode)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        var names: [String] = []
        // 兼容 D:/d: 命名空间前缀与无前缀的 <href>
        for match in text.matches(of: try Regex("<(?:[Dd]:)?href>([^<]+)</(?:[Dd]:)?href>")) {
            let href = match.output.count > 1 ? String(match.output[1].substring ?? "") : ""
            let decoded = href.removingPercentEncoding ?? href
            var name = decoded
            if name.hasPrefix("/") { name = String(name.dropFirst()) }
            while name.hasSuffix("/") { name.removeLast() }
            if let last = name.split(separator: "/").last {
                names.append(String(last))
            }
        }
        // 第一个 href 是目录本身
        if !names.isEmpty { names.removeFirst() }
        return names
    }

    public func get(_ path: String) async throws -> Data {
        let request = try makeRequest(method: "GET", path: path, body: nil)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw SyncError.http(status: response.statusCode)
        }
        return data
    }

    public func put(_ path: String, _ data: Data) async throws {
        let request = try makeRequest(method: "PUT", path: path, body: data)
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncError.http(status: response.statusCode)
        }
    }

    public func makeDirectory(_ path: String) async throws {
        let request = try makeRequest(method: "MKCOL", path: path, body: nil)
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 405 else {
            throw SyncError.http(status: response.statusCode)
        }
    }
}

/// 同步自动化三档（对齐原版 WebdavSyncMode）。
public enum WebdavSyncMode: String, CaseIterable, Sendable {
    case realtime
    case dataSaver
    case manual
}

public enum SyncError: Error, CustomStringConvertible {
    case http(status: Int)
    case notConfigured
    case invalidArchive

    public var description: String {
        switch self {
        case .http(let status): return "HTTP \(status)"
        case .notConfigured: return "WebDAV not configured"
        case .invalidArchive: return "Invalid backup archive"
        }
    }
}

/// 数据同步引擎（对齐 utils/data_sync.dart + data.dart 的 export/import）。
public final class DataSync: @unchecked Sendable {
    public static let shared = DataSync()

    private init() {}

    /// webdav 设置：[url, user, password]。
    public var config: (url: String, user: String, password: String)? {
        let raw = AppData.shared.settings["webdav"].arrayValue ?? []
        let values = raw.compactMap { $0.stringValue }
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty }) else { return nil }
        return (values[0], values[1], values[2])
    }

    public var isConfigured: Bool { config != nil }

    private var dataVersion: Int {
        AppData.shared.settings["dataVersion"].intValue ?? 0
    }

    // MARK: - 同步模式（implicitData，设备本地不参与同步）

    /// 本设备上传自动化档位。存 implicitData（对齐原版 `_syncModeKey`），
    /// 读穿旧版 `webdavAutoSync` 布尔迁移。
    public var syncMode: WebdavSyncMode {
        if let name = AppData.shared.implicitValue("webdavSyncMode").stringValue,
           let mode = WebdavSyncMode(rawValue: name) {
            return mode
        }
        if let legacy = AppData.shared.implicitValue("webdavAutoSync").boolValue {
            return legacy ? .realtime : .manual
        }
        return .realtime
    }

    public func setSyncMode(_ mode: WebdavSyncMode) {
        AppData.shared.setImplicitValue("webdavSyncMode", .string(mode.rawValue))
        // 旧版布尔保持一致（QR 配置与降级安装仍会读取）。
        AppData.shared.setImplicitValue("webdavAutoSync", .bool(mode != .manual))
        AppData.shared.writeImplicitData()
        if mode == .realtime {
            settlePendingChanges()
        }
    }

    /// dataSaver 档：累积中的未上传变更标记。realtime 档即时上传用不到。
    private let pendingLock = NSLock()
    private var pendingUploadTask: Task<Void, Never>?
    private var lastAutoUploadAt: Date?
    /// 导入/下载回放期间抑制自动上传（对齐原版 isApplyingBackup）。
    public private(set) var isApplyingBackup = false

    /// 本地发生变更（saveData(sync:true) 时调用）。realtime 档防抖 2s 上传。
    public func noteLocalChange() {
        guard syncMode == .realtime, isConfigured, !isApplyingBackup else { return }
        pendingLock.lock()
        pendingUploadTask?.cancel()
        pendingUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.runAutoUpload()
        }
        pendingLock.unlock()
    }

    /// 进入自动档/回前台时立即结算待上传变更（对齐 settlePendingChanges）。
    public func settlePendingChanges() {
        guard syncMode != .manual, isConfigured, !isApplyingBackup else { return }
        pendingLock.lock()
        pendingUploadTask?.cancel()
        pendingUploadTask = Task { [weak self] in
            await self?.runAutoUpload()
        }
        pendingLock.unlock()
    }

    private func runAutoUpload() async {
        guard isConfigured, !isApplyingBackup else { return }
        do {
            try await upload(force: false)
        } catch {
            appendSyncLog(action: "upload", success: false, fileName: nil, error: error.localizedDescription)
        }
    }

    // MARK: - 同步日志

    private let logsLock = NSLock()
    private var _syncLogs: [[String: JSON]] = []

    public var syncLogs: [[String: JSON]] {
        logsLock.lock()
        defer { logsLock.unlock() }
        return _syncLogs
    }

    private func appendSyncLog(action: String, success: Bool, fileName: String?, error: String?) {
        var entry: [String: JSON] = [
            "time": .int(Int(Date().timeIntervalSince1970 * 1000)),
            "action": .string(action),
            "success": .bool(success),
        ]
        if let fileName { entry["fileName"] = .string(fileName) }
        if let error { entry["error"] = .string(error) }
        logsLock.lock()
        _syncLogs.append(entry)
        if _syncLogs.count > 200 {
            _syncLogs.removeFirst(_syncLogs.count - 200)
        }
        logsLock.unlock()
    }

    /// 标记备份回放开始/结束（下载/导入期间抑制自动上传）。
    private func setApplyingBackup(_ value: Bool) {
        pendingLock.lock()
        isApplyingBackup = value
        pendingLock.unlock()
    }

    private func withApplyingBackup<T>(_ body: () async throws -> T) async rethrows -> T {
        setApplyingBackup(true)
        defer { setApplyingBackup(false) }
        return try await body()
    }

    // MARK: - 打包

    /// 导出全部数据为 `.venera` ZIP。sync=true 时 appdata 剔除设备本地键
    /// （对齐 exportAppData(sync: true) 的 syncdata.json）。
    public func exportAppData(sync: Bool) throws -> Data {
        // 快照必须反映当前内存状态：先刷新 appdata/syncdata 再打包
        AppData.shared.saveData(sync: false)
        let dataPath = AppPaths.dataPath

        let syncLocal = AppData.shared.settings["syncLocalComics"].boolValue ?? true
        let includeLocalComics = !sync || syncLocal

        // 导出前合并 WAL
        for db in ["history.db", "local_favorite.db", "read_later.db", "cookie.db", "cache.db", "local.db"] {
            if FileIO.exists(AppPaths.join(dataPath, db)) {
                _ = try? DatabaseGateway.shared.openManaged(AppPaths.join(dataPath, db)).checkpoint()
            }
        }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("venera-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var entries: [String] = []
        for db in ["history.db", "local_favorite.db", "read_later.db", "cookie.db"] {
            if FileIO.exists(AppPaths.join(dataPath, db)) {
                entries.append(db)
            }
        }
        if includeLocalComics && FileIO.exists(AppPaths.join(dataPath, "local.db")) {
            entries.append("local.db")
        }
        entries.append(sync ? "syncdata.json" : "appdata.json")
        entries.append("source_type_map.json")

        // 漫画源脚本与数据
        let sourceDirectory = AppPaths.comicSourcePath
        if let files = try? FileManager.default.contentsOfDirectory(atPath: sourceDirectory) {
            for file in files where file.hasSuffix(".js") || file.hasSuffix(".data") {
                entries.append("comic_source/\(file)")
            }
        }

        let archiveURL = temporary.appendingPathComponent("backup.venera")
        guard let archive = try? Archive(url: archiveURL, accessMode: .create, preferredEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }
        // source_type_map.json 先行生成
        let registry = SourcePlatformResolver.shared.snapshot()
        var registryMap: [String: JSON] = [:]
        for (intKey, sourceKey) in registry {
            registryMap[String(intKey)] = .string(sourceKey)
        }
        try? FileIO.writeStringAtomic(
            temporary.appendingPathComponent("source_type_map.json").path,
            (try? JSON.object(registryMap).encodedString()) ?? "{}"
        )

        for entry in entries {
            let relativePath: String
            let absolutePath: String
            if entry.hasPrefix("comic_source/") {
                relativePath = entry
                absolutePath = AppPaths.join(sourceDirectory, String(entry.dropFirst("comic_source/".count)))
            } else if entry == "syncdata.json" || entry == "appdata.json" {
                relativePath = entry
                absolutePath = AppPaths.join(dataPath, entry)
            } else {
                relativePath = entry
                absolutePath = AppPaths.join(dataPath, entry)
            }
            guard FileIO.exists(absolutePath) else { continue }
            let fileURL = URL(fileURLWithPath: absolutePath)
            _ = try? archive.addEntry(with: relativePath, fileURL: fileURL)
        }
        return try Data(contentsOf: archiveURL)
    }

    // MARK: - 导入

    /// 导入 `.venera` 备份：关闭连接 → 换库 → 应用 appdata（syncData 语义，
    /// 不回传服务器）。settings 键级兼容。
    public func importAppData(_ data: Data) throws {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("venera-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var dbFiles: [String: String] = [:]
        var sourceFiles: [String: String] = [:]
        var settingsJSON: JSON?

        for entry in archive where entry.type == .file {
            let name = entry.path
            guard name.hasPrefix("/") == false, !name.contains("..") else { continue }
            let destinationURL = temporary.appendingPathComponent(name)
            try? FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            _ = try? archive.extract(entry, to: destinationURL)
            let path = destinationURL.path
            if name.hasSuffix(".db") {
                dbFiles[AppPaths.join(AppPaths.dataPath, name)] = path
            } else if name.hasPrefix("comic_source/") {
                sourceFiles[name] = path
            } else if name == "syncdata.json" || name == "appdata.json" {
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    settingsJSON = JSON.decode(text)
                }
            } else if name == "source_type_map.json" {
                if let text = try? String(contentsOfFile: path, encoding: .utf8),
                   let json = JSON.decode(text), case .object(let map) = json
                {
                    let registry = map.compactMap { key, value -> (Int, String)? in
                        guard let intKey = Int(key), let sourceKey = value.stringValue else { return nil }
                        return (intKey, sourceKey)
                    }
                    var converted: [Int: String] = [:]
                    for (intKey, sourceKey) in registry {
                        converted[intKey] = sourceKey
                    }
                    SourcePlatformResolver.shared.registerLegacyIntSourceKeys(converted)
                }
            }
        }

        try DatabaseGateway.shared.runExclusive {
            if !dbFiles.isEmpty {
                try DatabaseGateway.shared.restoreDatabaseFiles(dbFiles)
            }
            // 漫画源脚本与数据落盘
            try? FileManager.default.createDirectory(atPath: AppPaths.comicSourcePath, withIntermediateDirectories: true)
            for (relative, source) in sourceFiles {
                let fileName = String(relative.dropFirst("comic_source/".count))
                let destination = AppPaths.join(AppPaths.comicSourcePath, fileName)
                FileIO.deleteIgnoringErrors(destination)
                try? FileManager.default.copyItem(atPath: source, toPath: destination)
            }
            if let settingsJSON {
                AppData.shared.syncData(settingsJSON)
            } else {
                AppData.shared.saveData(sync: false)
            }
            if dbFiles.keys.contains(where: { $0.hasSuffix("local.db") }) {
                LocalManager.shared.ensureSchema()
                LocalManager.shared.ensureDirectory()
                LocalManager.shared.onChange.emit(())
            }
        }
    }

    // MARK: - 同步（上传/下载）

    /// 当前远端最新备份文件名与版本。
    public func remoteLatest(_ client: WebDAVClient) async throws -> (name: String, version: Int)? {
        let names = try await client.list("/")
        var best: (String, Int)?
        for name in names where name.hasSuffix(".venera") {
            let version = RemoteBackupInfo.fromFileName(name).version
            if best == nil || version > best!.1 {
                best = (name, version)
            }
        }
        return best
    }

    /// 上传（force = 手动/导入后的「以本机为准」）。
    public func upload(force: Bool) async throws {
        guard let config else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: config.url, username: config.user, password: config.password)
        let latest = try await remoteLatest(client)
        let remoteMax = latest?.version ?? 0
        if SyncProtocol.shouldSkipStaleUpload(force: force, localVersion: dataVersion, remoteMaxVersion: remoteMax) {
            // 本地落后：转下载追赶（对齐 #86）
            try await download()
            return
        }
        let version = SyncProtocol.nextSyncVersion(dataVersion, remoteMax)
        let data = try exportAppData(sync: true)
        let days = Int(Date().timeIntervalSince1970 / 86400)
        let fileName = "\(days)-\(version).ios.venera"
        try await client.put("/\(fileName)", data)
        AppData.shared.settings["dataVersion"] = .int(version)
        try await pruneOldBackups(client, keep: AppData.shared.settings["webdavBackupRetention"].intValue ?? 10)
        appendSyncLog(action: "upload", success: true, fileName: fileName, error: nil)
    }

    /// 下载最新备份并导入。
    public func download() async throws {
        guard let config else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: config.url, username: config.user, password: config.password)
        guard let latest = try await remoteLatest(client) else { return }
        guard latest.version > dataVersion else { return }
        let data = try await client.get("/\(latest.name)")
        try await withApplyingBackup {
            try importAppData(data)
        }
        AppData.shared.settings["dataVersion"] = .int(latest.version)
        appendSyncLog(action: "download", success: true, fileName: latest.name, error: nil)
    }

    // MARK: - 连接测试 / 远程备份管理

    /// 探测 WebDAV 凭据（不做任何写入/同步）。
    public func testConnection() async throws {
        guard let config else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: config.url, username: config.user, password: config.password)
        _ = try await client.list("/")
    }

    /// 服务器上全部备份（按版本倒序）。
    public func listRemoteBackups() async throws -> [RemoteBackupInfo] {
        guard let config else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: config.url, username: config.user, password: config.password)
        let names = try await client.list("/")
        return names.filter { $0.hasSuffix(".venera") }
            .map { RemoteBackupInfo.fromFileName($0) }
            .sorted { $0.version > $1.version }
    }

    /// 下载指定备份并覆盖本地（对齐 downloadSpecificBackup）。
    public func downloadSpecificBackup(_ fileName: String) async throws {
        guard let config else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: config.url, username: config.user, password: config.password)
        let data = try await client.get("/\(fileName)")
        try await withApplyingBackup {
            try importAppData(data)
        }
        let version = RemoteBackupInfo.fromFileName(fileName).version
        AppData.shared.settings["dataVersion"] = .int(max(version, dataVersion))
        appendSyncLog(action: "download", success: true, fileName: fileName, error: nil)
    }

    /// 每平台保留 N 份（对齐 webdavBackupRetention）。
    public func pruneOldBackups(_ client: WebDAVClient, keep: Int) async throws {
        let names = try await client.list("/")
        let backups = names.filter { $0.hasSuffix(".venera") && $0.contains(".ios.") }
            .map { RemoteBackupInfo.fromFileName($0) }
            .sorted { $0.version > $1.version }
        guard backups.count > keep else { return }
        for info in backups.suffix(backups.count - keep) {
            _ = try? await client.delete("/\(info.fileName)")
        }
    }
}

extension WebDAVClient {
    /// DELETE（保留清理用）。
    public func delete(_ path: String) async throws {
        let request = try makeRequest(method: "DELETE", path: path, body: nil)
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
            throw SyncError.http(status: response.statusCode)
        }
    }
}
