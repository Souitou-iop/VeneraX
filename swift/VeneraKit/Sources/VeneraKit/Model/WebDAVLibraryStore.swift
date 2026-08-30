import Foundation

public struct WebdavLibraryConfig: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceKey: String
    public var name: String
    public var url: String
    public var user: String
    public var pass: String
    public var root: String
    public var enabled: Bool

    public init(
        id: String,
        sourceKey: String,
        name: String,
        url: String,
        user: String,
        pass: String,
        root: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.name = name
        self.url = url
        self.user = user
        self.pass = pass
        self.root = root
        self.enabled = enabled
    }

    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let host = URL(string: url)?.host ?? url
        return root.isEmpty ? host : "\(host):/\(root)"
    }

    public func toJson() -> JSON {
        .object([
            "id": .string(id),
            "sourceKey": .string(sourceKey),
            "name": .string(name),
            "url": .string(url),
            "user": .string(user),
            "pass": .string(pass),
            "root": .string(root),
            "enabled": .bool(enabled),
        ])
    }

    public static func fromJson(_ json: JSON) -> WebdavLibraryConfig? {
        guard let id = json["id"].stringValue,
              let url = json["url"].stringValue else { return nil }
        return WebdavLibraryConfig(
            id: id,
            sourceKey: json["sourceKey"].stringValue ?? "webdav_\(id)",
            name: json["name"].stringValue ?? "",
            url: url,
            user: json["user"].stringValue ?? "",
            pass: json["pass"].stringValue ?? "",
            root: json["root"].stringValue ?? "",
            enabled: json["enabled"].boolValue ?? true
        )
    }
}

/// WebDAV 远程漫画库配置与存储管理器（对齐 webdav_library_store.dart）。
public final class WebDAVLibraryStore: @unchecked Sendable {
    public static let shared = WebDAVLibraryStore()

    public static let settingsKey = "webdavLibraries"
    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()

    private init() {}

    public func all() -> [WebdavLibraryConfig] {
        lock.lock()
        defer { lock.unlock() }
        let raw = AppData.shared.settings[Self.settingsKey].arrayValue ?? []
        return raw.compactMap { WebdavLibraryConfig.fromJson($0) }
    }

    public func find(id: String) -> WebdavLibraryConfig? {
        all().first { $0.id == id }
    }

    @discardableResult
    public func add(
        name: String,
        url: String,
        user: String,
        pass: String,
        root: String = ""
    ) -> WebdavLibraryConfig {
        var list = all()
        let id = UUID().uuidString.prefix(8).lowercased()
        let sourceKey = "webdav_\(id)"
        let config = WebdavLibraryConfig(
            id: String(id),
            sourceKey: sourceKey,
            name: name.trimmingCharacters(in: .whitespaces),
            url: url.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            pass: pass,
            root: root.trimmingCharacters(in: .whitespaces),
            enabled: true
        )
        list.append(config)
        save(list)
        return config
    }

    @discardableResult
    public func update(
        id: String,
        name: String? = nil,
        url: String? = nil,
        user: String? = nil,
        pass: String? = nil,
        root: String? = nil,
        enabled: Bool? = nil
    ) -> WebdavLibraryConfig? {
        var list = all()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return nil }
        var c = list[idx]
        if let name { c.name = name.trimmingCharacters(in: .whitespaces) }
        if let url { c.url = url.trimmingCharacters(in: .whitespaces) }
        if let user { c.user = user.trimmingCharacters(in: .whitespaces) }
        if let pass { c.pass = pass }
        if let root { c.root = root.trimmingCharacters(in: .whitespaces) }
        if let enabled { c.enabled = enabled }
        list[idx] = c
        save(list)
        return c
    }

    public func remove(id: String) {
        var list = all()
        list.removeAll { $0.id == id }
        save(list)
    }

    public func reorder(oldIndex: Int, newIndex: Int) {
        var list = all()
        guard list.indices.contains(oldIndex) else { return }
        let item = list.remove(at: oldIndex)
        let insertIndex = min(newIndex, list.count)
        list.insert(item, at: insertIndex)
        save(list)
    }

    private func save(_ list: [WebdavLibraryConfig]) {
        AppData.shared.settings[Self.settingsKey] = .array(list.map { $0.toJson() })
        AppData.shared.saveData(sync: true)
        onChange.emit(())
    }
}
