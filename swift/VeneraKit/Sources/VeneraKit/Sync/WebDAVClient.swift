import Foundation
import ZIPFoundation

/// A single immediate WebDAV child returned by PROPFIND.
public struct WebDAVResource: Sendable, Equatable {
    public let name: String
    public let href: String
    public let isCollection: Bool

    public init(name: String, href: String, isCollection: Bool) {
        self.name = name
        self.href = href
        self.isCollection = isCollection
    }
}

/// URL/path rules shared by WebDAV browsing and migration.
public enum WebDAVPath {
    /// Joins raw path components without allowing a child to escape the
    /// configured WebDAV base URL. Leading slashes are intentionally ignored:
    /// `/venerax/` is a path inside `https://host/webdav/`, not a host root.
    public static func join(_ parts: String...) -> String {
        join(parts)
    }

    public static func join(_ parts: [String]) -> String {
        parts
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    public static func normalizedDirectory(_ path: String) -> String {
        let joined = join(path)
        return joined.isEmpty ? "/" : "/\(joined)/"
    }

    fileprivate static func segments(_ path: String) throws -> [String] {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.contains(".") && !segments.contains("..") else {
            throw JSRuntimeException(message: "Invalid WebDAV path: \(path)")
        }
        return segments
    }
}

/// WebDAV 客户端（Basic Auth + PROPFIND/GET/PUT/MKCOL），供数据同步与
/// 远程漫画库使用。对齐原版 webdav_client fork 的能力面。
public final class WebDAVClient: @unchecked Sendable {
    public let baseURL: URL
    public let username: String
    public let password: String
    private let session: URLSession
    private let maxAttempts = 3

    public init(url: String, username: String, password: String, session: URLSession? = nil) throws {
        var string = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.hasSuffix("/") { string += "/" }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.query == nil,
              url.fragment == nil
        else {
            throw JSRuntimeException(message: "Invalid WebDAV URL: \(url)")
        }
        self.baseURL = url
        self.username = username
        self.password = password
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Resolves a raw WebDAV path relative to `baseURL`, preserving a base
    /// path such as `/webdav/venerax/` and percent-encoding each component.
    public func url(for path: String) throws -> URL {
        var result = baseURL
        for segment in try WebDAVPath.segments(path) {
            result.appendPathComponent(segment, isDirectory: false)
        }
        return result
    }

    private func makeRequest(method: String, path: String, body: Data?) throws -> URLRequest {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = method == "PROPFIND" ? 30 : 90
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw JSRuntimeException(message: "Invalid response")
                }
                if attempt + 1 < maxAttempts && Self.shouldRetry(status: httpResponse.statusCode) {
                    try await Self.backoff(attempt: attempt, retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    continue
                }
                try Task.checkCancellation()
                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where attempt + 1 < maxAttempts && Self.shouldRetry(error: error) {
                lastError = error
                try await Self.backoff(attempt: attempt, retryAfter: nil)
            } catch {
                throw error
            }
        }
        throw lastError ?? JSRuntimeException(message: "WebDAV request failed")
    }

    private static func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    private static func shouldRetry(error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private static func backoff(attempt: Int, retryAfter: String?) async throws {
        let seconds = retryAfter.flatMap(Double.init).map { min(max($0, 0), 5) }
            ?? (0.25 * pow(2, Double(attempt)))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Lists immediate children and preserves whether each item is a DAV
    /// collection. This is needed by migration: an archive file with the same
    /// name must not be mistaken for an existing comic directory.
    public func listResources(_ path: String = "/") async throws -> [WebDAVResource] {
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
        let resources = try WebDAVPROPFINDParser.parse(data)
        let targetPath = try url(for: path).path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return resources.filter { resource in
            let hrefPath = URL(string: resource.href)?.path ?? resource.href
            let normalized = (hrefPath.removingPercentEncoding ?? hrefPath)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            return normalized != targetPath
        }
    }

    /// 列出目录下的文件名（PROPFIND depth 1）。
    public func list(_ path: String = "/") async throws -> [String] {
        try await listResources(path).map(\.name)
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

private final class WebDAVPROPFINDParser: NSObject, XMLParserDelegate {
    private var currentHref = ""
    private var currentText = ""
    private var currentCollection = false
    private var insideResponse = false
    private(set) var resources: [WebDAVResource] = []

    static func parse(_ data: Data) throws -> [WebDAVResource] {
        let parserDelegate = WebDAVPROPFINDParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw JSRuntimeException(message: parser.parserError?.localizedDescription ?? "Invalid WebDAV XML")
        }
        return parserDelegate.resources
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = elementName.lowercased()
        if name == "response" {
            insideResponse = true
            currentHref = ""
            currentCollection = false
        } else if insideResponse && name == "collection" {
            currentCollection = true
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if insideResponse && name == "href" {
            currentHref = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if name == "response" {
            if !currentHref.isEmpty {
                let decoded = currentHref.removingPercentEncoding ?? currentHref
                var path = URL(string: decoded)?.path ?? decoded
                while path.hasSuffix("/") { path.removeLast() }
                let itemName = path.split(separator: "/").last.map(String.init) ?? ""
                if !itemName.isEmpty {
                    resources.append(WebDAVResource(name: itemName, href: currentHref, isCollection: currentCollection))
                }
            }
            insideResponse = false
        }
        currentText = ""
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

    private var pendingPublish: (fileName: String, size: Int?)? {
        let value = AppData.shared.implicitValue("webdavPendingPublish")
        guard case .object(let object) = value,
              let fileName = object["fileName"]?.stringValue,
              !fileName.isEmpty else { return nil }
        return (fileName, object["size"]?.intValue)
    }

    private func setPendingPublish(fileName: String, size: Int) {
        AppData.shared.setImplicitValue("webdavPendingPublish", .object([
            "fileName": .string(fileName),
            "size": .int(size),
        ]))
    }

    private func clearPendingPublish() {
        AppData.shared.setImplicitValue("webdavPendingPublish", .null)
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

        // 导出前合并 WAL。缓存不是 Flutter `.venera` 协议的一部分，不能把
        // 设备私有缓存带到另一台设备；只 checkpoint 会让它继续占用无意义的启动时间。
        for db in ["history.db", "local_favorite.db", "local.db", "read_later.db", "cookie.db"] {
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
        // Flutter 协议：压缩包内设置成员固定命名为 appdata.json（原版
        // `zipFile.addFile("appdata.json", appdataFile)`，即使磁盘源文件是
        // syncdata.json）。此前导出为 syncdata.json 成员，Flutter 端导入
        // 只认 appdata.json，导致设置在 Swift→Flutter 方向被静默跳过。
        entries.append(sync ? "syncdata.json" : "appdata.json")
        // 中继文件：本端无对应子系统（domain 库 / 图片翻译），但必须原样
        // 带回，Flutter↔Flutter 多设备链路经过 Swift 设备时数据才不丢
        // （对齐原版「存在即打包」的存在性守卫）。
        for relay in ["image_translation.db", "image_translation_prefs.json", "data/venera.db"] {
            if FileIO.exists(AppPaths.join(dataPath, relay)) {
                entries.append(relay)
            }
        }
        // 合集封面（对齐原版 coverDir 打包）：配置在 appdata.json 里只存文件名
        // （collection://<名>），文件本体以 collection_covers/<名> 成员中继，
        // 否则另一台设备的合集封面指向空文件。隐藏文件（.DS_Store 等）不带。
        let coverDir = AppPaths.join(dataPath, ComicCollectionStore.coverDirName)
        if let coverFiles = try? FileManager.default.contentsOfDirectory(atPath: coverDir) {
            for file in coverFiles where !file.hasPrefix(".") {
                entries.append("\(ComicCollectionStore.coverDirName)/\(file)")
            }
        }
        // source_type_map.json：注册表非空才打包（对齐原版条件）。
        let registry = SourcePlatformResolver.shared.snapshot()
        if !registry.isEmpty {
            entries.append("source_type_map.json")
        }

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
        // source_type_map.json 先行生成到暂存目录。内容包裹在 "types" 键下
        // （对齐原版 jsonEncode({'types': sourceTypeRegistry})，否则 Flutter
        // 端读取 data['types'] 得到空映射）。
        if !registry.isEmpty {
            var registryMap: [String: JSON] = [:]
            for (intKey, sourceKey) in registry {
                registryMap[String(intKey)] = .string(sourceKey)
            }
            try? FileIO.writeStringAtomic(
                temporary.appendingPathComponent("source_type_map.json").path,
                (try? JSON.object(["types": .object(registryMap)]).encodedString()) ?? "{}"
            )
        }

        for entry in entries {
            let relativePath: String
            let absolutePath: String
            if entry.hasPrefix("comic_source/") {
                relativePath = entry
                absolutePath = AppPaths.join(sourceDirectory, String(entry.dropFirst("comic_source/".count)))
            } else if entry == "syncdata.json" || entry == "appdata.json" {
                // zip 成员名固定为 appdata.json（Flutter 协议），磁盘源文件按模式取。
                relativePath = "appdata.json"
                absolutePath = AppPaths.join(dataPath, entry)
            } else if entry == "source_type_map.json" {
                // 生成于暂存目录而非 dataPath（此前按 dataPath 解析导致永远跳过）。
                relativePath = entry
                absolutePath = temporary.appendingPathComponent(entry).path
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
    public func importAppData(_ data: Data, restoreLocalComics: Bool = true) throws {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("venera-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var dbFiles: [String: String] = [:]
        var sourceFiles: [String: String] = [:]
        var relayFiles: [String: String] = [:]
        var settingsJSON: JSON?
        var importedCovers = false

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
                // `syncLocalComics` is a receiving-device policy. A backup may
                // contain local.db, but an opted-out device must not replace its
                // own local library manifest (Flutter restoreLocalComics).
                if name == "local.db" && !restoreLocalComics { continue }
                // 中继文件：本端无对应子系统（domain 库 / 图片翻译），原样
                // 落盘保存、导出时带回，保证多设备链路经过 Swift 不断。
                if name == "data/venera.db" || name == "image_translation.db" {
                    relayFiles[AppPaths.join(AppPaths.dataPath, name)] = path
                    continue
                }
                guard ["history.db", "local_favorite.db", "local.db", "read_later.db", "cookie.db"].contains(name) else { continue }
                dbFiles[AppPaths.join(AppPaths.dataPath, name)] = path
            } else if name.hasPrefix("comic_source/") {
                sourceFiles[name] = path
            } else if name.hasPrefix("\(ComicCollectionStore.coverDirName)/") {
                // 合集封面中继：配置只存文件名，文件本体原样落盘供解析。
                relayFiles[AppPaths.join(AppPaths.dataPath, name)] = path
                importedCovers = true
            } else if name == "syncdata.json" || name == "appdata.json" {
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    settingsJSON = JSON.decode(text)
                }
            } else if name == "image_translation_prefs.json" {
                // 同上：中继保留（原内容为 per-comic 图片翻译偏好）。
                relayFiles[AppPaths.join(AppPaths.dataPath, name)] = path
            } else if name == "source_type_map.json" {
                if let text = try? String(contentsOfFile: path, encoding: .utf8),
                   let json = JSON.decode(text), case .object(let map) = json
                {
                    // 原版格式为 {"types": {intKey: sourceKey}}；平铺形式仅为
                    // 本端旧导出的防御性回退。
                    let rawTypes: [String: JSON]
                    if case .object(let wrapped)? = map["types"] {
                        rawTypes = wrapped
                    } else {
                        rawTypes = map
                    }
                    let registry = rawTypes.compactMap { key, value -> (Int, String)? in
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
            // 中继文件原样落盘（含 data/venera.db 的子目录创建）
            for (destination, source) in relayFiles {
                let directory = (destination as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                FileIO.deleteIgnoringErrors(destination)
                try? FileManager.default.copyItem(atPath: source, toPath: destination)
            }
            if let settingsJSON {
                AppData.shared.syncData(settingsJSON)
            } else {
                AppData.shared.saveData(sync: false)
            }
            // 合集封面剪枝（对齐原版「复制后按新配置清理」）：settings 刚被
            // 应用，合集列表已是新配置；不再被任何 customCover 引用的封面
            // 文件是另一台设备弃用的死数据，不清会随每次同步永久堆积。
            // 仅当备份携带封面目录时执行（无封面成员的备份不触碰本地封面）。
            if importedCovers {
                var referenced = Set<String>()
                for collection in ComicCollectionStore.shared.all() {
                    let cover = collection.customCover.trimmingCharacters(in: .whitespaces)
                    if cover.hasPrefix(ComicCollectionStore.localCoverScheme) {
                        referenced.insert(String(cover.dropFirst(ComicCollectionStore.localCoverScheme.count)))
                    }
                }
                let targetDir = AppPaths.join(AppPaths.dataPath, ComicCollectionStore.coverDirName)
                if let files = try? FileManager.default.contentsOfDirectory(atPath: targetDir) {
                    for file in files where !referenced.contains(file) {
                        FileIO.deleteIgnoringErrors(AppPaths.join(targetDir, file))
                    }
                }
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
        let fileName = "\(days)-\(version).\(SyncProtocol.platformTag).venera"
        setPendingPublish(fileName: fileName, size: data.count)
        try await client.put(fileName, data)
        AppData.shared.settings["dataVersion"] = .int(version)
        clearPendingPublish()
        try await pruneOldBackups(
            client,
            keep: AppData.shared.settings["webdavBackupRetention"].intValue ?? SyncProtocol.backupRetentionPerPlatform,
            newFileName: fileName
        )
        appendSyncLog(action: "upload", success: true, fileName: fileName, error: nil)
    }

    /// 下载最新备份并导入。
    public func download() async throws {
        guard let config else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: config.url, username: config.user, password: config.password)
        guard let latest = try await remoteLatest(client) else { return }
        if let claim = pendingPublish,
           SyncProtocol.isOwnPendingPublish(
                claimedFileName: claim.fileName,
                claimedSize: claim.size,
                remoteFileName: latest.name,
                remoteSize: nil
           ) {
            if latest.version > dataVersion {
                AppData.shared.settings["dataVersion"] = .int(latest.version)
                AppData.shared.saveData(sync: false)
            }
            clearPendingPublish()
            return
        }
        clearPendingPublish()
        guard latest.version > dataVersion else { return }
        let data = try await client.get(latest.name)
        try await withApplyingBackup {
            try importAppData(data, restoreLocalComics: AppData.shared.settings["syncLocalComics"].boolValue ?? true)
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
            try importAppData(data, restoreLocalComics: AppData.shared.settings["syncLocalComics"].boolValue ?? true)
        }
        let version = RemoteBackupInfo.fromFileName(fileName).version
        AppData.shared.settings["dataVersion"] = .int(max(version, dataVersion))
        appendSyncLog(action: "download", success: true, fileName: fileName, error: nil)
    }

    /// 每个平台保留 N 份（与 Flutter backupsBeyondPlatformRetention 对齐）。
    public func pruneOldBackups(_ client: WebDAVClient, keep: Int, newFileName: String? = nil) async throws {
        let names = try await client.list("/")
        let backups = names.filter { $0.hasSuffix(".venera") }
        let currentFileName = newFileName ?? "\(Int(Date().timeIntervalSince1970 / 86400))-\(dataVersion).\(SyncProtocol.platformTag).venera"
        let stale = SyncProtocol.backupsBeyondPlatformRetention(
            fileNames: backups.map(Optional.some),
            newFileName: currentFileName,
            keepPerPlatform: keep
        )
        for fileName in stale {
            _ = try? await client.delete(fileName)
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
