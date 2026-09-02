import CryptoKit
import Foundation

/// One configured WebDAV comic library.
///
/// The JSON shape intentionally mirrors Flutter's `WebdavLibraryConfig` so
/// this value can travel through the shared app-data/WebDAV backup.
public struct WebdavLibraryConfig: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceKey: String
    public var name: String
    public var url: String
    public var user: String
    public var pass: String
    public var root: String
    public var enabled: Bool
    public var detectLinkedFolders: Bool

    public init(
        id: String,
        sourceKey: String,
        name: String,
        url: String,
        user: String,
        pass: String,
        root: String = "",
        enabled: Bool = true,
        detectLinkedFolders: Bool = false
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.name = name
        self.url = url
        self.user = user
        self.pass = pass
        self.root = root
        self.enabled = enabled
        self.detectLinkedFolders = detectLinkedFolders
    }

    /// Normalized root path used by WebDAV browsing.
    public var rootPath: String {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return withLeadingSlash.hasSuffix("/") ? withLeadingSlash : "\(withLeadingSlash)/"
    }

    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let host = URL(string: url)?.host ?? url
        return root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : "\(host):/\(root)"
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
            "detectLinkedFolders": .bool(detectLinkedFolders),
        ])
    }

    public static func fromJson(_ json: JSON) -> WebdavLibraryConfig? {
        guard let url = json["url"].stringValue, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = json["user"].stringValue ?? ""
        let root = json["root"].stringValue ?? ""
        let id = json["id"].stringValue ?? stableWebdavLibraryId(normalizedURL, user, root)
        return WebdavLibraryConfig(
            id: id,
            // Flutter uses this fallback for records written before sourceKey
            // was persisted. Existing sourceKey values are always preserved.
            sourceKey: json["sourceKey"].stringValue?.isEmpty == false
                ? json["sourceKey"].stringValue!
                : WebDAVLibraryStore.legacySourceKey,
            name: json["name"].stringValue ?? "",
            url: normalizedURL,
            user: user,
            pass: json["pass"].stringValue ?? "",
            root: root,
            enabled: json["enabled"].boolValue ?? true,
            // Missing Flutter field means false, matching the Dart default.
            detectLinkedFolders: json["detectLinkedFolders"].boolValue ?? false
        )
    }
}

/// Same normalization and MD5 seed as Flutter's `stableWebdavLibraryId`.
///
/// The result is intentionally truncated to 12 hexadecimal characters.
public func stableWebdavLibraryId(_ url: String, _ user: String, _ root: String) -> String {
    var normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while normalizedURL.hasSuffix("/") {
        normalizedURL.removeLast()
    }

    var normalizedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalizedRoot.hasSuffix("/") {
        normalizedRoot.removeLast()
    }
    if !normalizedRoot.hasPrefix("/") {
        normalizedRoot = "/\(normalizedRoot)"
    }

    let seed = "\(normalizedURL)|\(user.trimmingCharacters(in: .whitespacesAndNewlines))|\(normalizedRoot)"
    let digest = Insecure.MD5.hash(data: Data(seed.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
}

/// WebDAV comic-library configuration store shared with the Flutter app.
public final class WebDAVLibraryStore: @unchecked Sendable {
    public static let shared = WebDAVLibraryStore()

    /// Canonical Flutter setting key.
    public static let settingsKey = "webdavComicLibraries"
    /// Key used by the earlier Swift migration.
    public static let legacySettingsKey = "webdavLibraries"
    public static let legacySourceKey = "webdav_library"
    public static let sourceKeyPrefix = "webdav_library_"

    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()

    private init() {}

    public func all() -> [WebdavLibraryConfig] {
        lock.lock()
        defer { lock.unlock() }

        let settings = AppData.shared.settings
        // Prefer the canonical key whenever it is an array, including an empty
        // array. An empty canonical list is an intentional deletion, not a cue
        // to resurrect stale data from the legacy key.
        let raw = settings[Self.settingsKey].arrayValue ?? settings[Self.legacySettingsKey].arrayValue ?? []
        var seenSourceKeys = Set<String>()
        var seenIDs = Set<String>()
        return raw.compactMap { json in
            guard let config = WebdavLibraryConfig.fromJson(json),
                  seenSourceKeys.insert(config.sourceKey).inserted,
                  seenIDs.insert(config.id).inserted else { return nil }
            return config
        }
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
        root: String = "",
        detectLinkedFolders: Bool = false
    ) -> WebdavLibraryConfig {
        var list = all()
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = stableWebdavLibraryId(trimmedURL, trimmedUser, trimmedRoot)
        let sourceKey = "\(Self.sourceKeyPrefix)\(id)"
        let config = WebdavLibraryConfig(
            id: id,
            sourceKey: sourceKey,
            name: name.trimmingCharacters(in: .whitespaces),
            url: trimmedURL,
            user: trimmedUser,
            pass: pass,
            root: trimmedRoot,
            enabled: true,
            detectLinkedFolders: detectLinkedFolders
        )

        if let index = list.firstIndex(where: { $0.id == id }) {
            // Match Flutter's add semantics: the same stable address/account/
            // root updates the existing record instead of creating a duplicate.
            list[index] = config
        } else {
            list.append(config)
        }
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
        enabled: Bool? = nil,
        detectLinkedFolders: Bool? = nil
    ) -> WebdavLibraryConfig? {
        var list = all()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return nil }
        var config = list[idx]
        if let name { config.name = name.trimmingCharacters(in: .whitespaces) }
        if let url { config.url = url.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let user { config.user = user.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let pass { config.pass = pass }
        if let root { config.root = root.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let enabled { config.enabled = enabled }
        if let detectLinkedFolders { config.detectLinkedFolders = detectLinkedFolders }
        list[idx] = config
        save(list)
        return config
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
        let insertIndex = min(max(newIndex, 0), list.count)
        list.insert(item, at: insertIndex)
        save(list)
    }

    private func save(_ list: [WebdavLibraryConfig]) {
        // Always write the canonical Flutter key. The legacy key is left alone
        // so an older Swift build can still read its previous data if needed.
        AppData.shared.settings[Self.settingsKey] = .array(list.map { $0.toJson() })
        AppData.shared.saveData(sync: true)
        onChange.emit(())
    }
}
