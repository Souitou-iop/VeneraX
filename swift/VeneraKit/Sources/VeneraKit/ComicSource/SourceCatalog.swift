import Foundation

public struct CatalogSourceItem: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let version: String
    public let url: String
    public let description: String
    public let author: String

    public init(
        key: String,
        name: String,
        version: String,
        url: String,
        description: String = "",
        author: String = ""
    ) {
        self.key = key
        self.name = name
        self.version = version
        self.url = url
        self.description = description
        self.author = author
    }

    public static func fromJson(_ json: JSON) -> CatalogSourceItem? {
        guard let key = json["key"].stringValue,
              let name = json["name"].stringValue,
              let version = json["version"].stringValue,
              let url = json["url"].stringValue else { return nil }
        return CatalogSourceItem(
            key: key,
            name: name,
            version: version,
            url: url,
            description: json["description"].stringValue ?? "",
            author: json["author"].stringValue ?? ""
        )
    }
}

/// 漫画源目录与在线市场管理器（对齐 source_library.dart + comic_source_update_tasks.dart）。
public final class SourceCatalogManager: @unchecked Sendable {
    public static let shared = SourceCatalogManager()

    public static let defaultCatalogURL = "https://raw.githubusercontent.com/kyosee/venera-sources/main/index.json"
    public let onChange = CallbackRegistry<Void>()

    private let stateLock = NSLock()
    private var storedAvailableUpdates: [String: String] = [:]
    private var storedCatalogSources: [CatalogSourceItem] = []
    private var checking = false

    public var availableUpdates: [String: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedAvailableUpdates
    }

    public var catalogSources: [CatalogSourceItem] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedCatalogSources
    }

    public var isChecking: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return checking
    }

    private init() {}

    public var catalogURL: String {
        get {
            AppData.shared.settings["comicSourceListUrl"].stringValue ?? Self.defaultCatalogURL
        }
        set {
            AppData.shared.settings["comicSourceListUrl"] = .string(newValue)
            AppData.shared.saveData(sync: true)
        }
    }

    public func fetchCatalog() async throws -> [CatalogSourceItem] {
        guard let url = URL(string: catalogURL) else { return [] }
        _ = url
        setChecking(true)
        defer { setChecking(false) }

        let response = await HTTPClient.shared.request(method: "GET", url: catalogURL)
        guard let status = response.status, (200..<300).contains(status),
              let text = String(data: response.body, encoding: .utf8),
              let json = JSON.decode(text),
              let list = json.arrayValue else {
            return []
        }

        let items = list.compactMap { CatalogSourceItem.fromJson($0) }

        // 检查更新
        var updates: [String: String] = [:]
        let installed = ComicSourceManager.shared.all()
        for item in items {
            if let inst = installed.first(where: { $0.key == item.key }) {
                if compareVersions(item.version, inst.version) > 0 {
                    updates[item.key] = item.version
                }
            }
        }
        storeCatalog(items, updates: updates)
        onChange.emit(())
        return items
    }

    private func setChecking(_ value: Bool) {
        stateLock.lock()
        checking = value
        stateLock.unlock()
    }

    private func storeCatalog(_ items: [CatalogSourceItem], updates: [String: String]) {
        stateLock.lock()
        storedCatalogSources = items
        storedAvailableUpdates = updates
        stateLock.unlock()
    }

    private func clearAvailableUpdate(for key: String) {
        stateLock.lock()
        storedAvailableUpdates.removeValue(forKey: key)
        stateLock.unlock()
    }

    public func compareVersions(_ v1: String, _ v2: String) -> Int {
        let p1 = v1.split(separator: ".").compactMap { Int($0) }
        let p2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(p1.count, p2.count)
        for i in 0..<maxLen {
            let num1 = i < p1.count ? p1[i] : 0
            let num2 = i < p2.count ? p2[i] : 0
            if num1 != num2 {
                return num1 > num2 ? 1 : -1
            }
        }
        return 0
    }

    public func installSource(from item: CatalogSourceItem) async throws {
        let sourceURL = SourceURL(item.url)
        let response = await HTTPClient.shared.request(method: "GET", url: sourceURL.url, headers: sourceURL.headers(["cache-time": "no"]))
        guard let status = response.status, (200..<300).contains(status),
              let script = String(data: response.body, encoding: .utf8), !script.isEmpty else {
            throw JSRuntimeException(message: "Failed to download script from \(item.url)")
        }

        let fileName = "\(item.key).js"
        let filePath = AppPaths.join(AppPaths.comicSourcePath, fileName)
        try FileIO.writeStringAtomic(filePath, script)

        await ComicSourceManager.shared.loadFromDirectory()
        clearAvailableUpdate(for: item.key)
        onChange.emit(())
    }

    public func updateAll() async {
        let updates = availableUpdates
        for (key, _) in updates {
            if let item = catalogSources.first(where: { $0.key == key }) {
                try? await installSource(from: item)
            }
        }
    }
}
