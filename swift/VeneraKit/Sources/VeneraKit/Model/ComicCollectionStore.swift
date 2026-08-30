import Foundation

public enum CollectionDisplayMode: String, Sendable, CaseIterable {
    case flat
    case tabs

    public static func fromName(_ name: String?) -> CollectionDisplayMode {
        guard let name else { return .flat }
        return CollectionDisplayMode(rawValue: name) ?? .flat
    }
}

public struct CollectionMember: Equatable, Sendable, Identifiable {
    public var id: String { "\(sourceKey)/\(comicId)" }
    public var sourceKey: String
    public var comicId: String
    public var displayName: String
    public var cachedTitle: String
    public var cachedSubtitle: String
    public var cachedCover: String

    public init(
        sourceKey: String,
        comicId: String,
        displayName: String = "",
        cachedTitle: String = "",
        cachedSubtitle: String = "",
        cachedCover: String = ""
    ) {
        self.sourceKey = sourceKey
        self.comicId = comicId
        self.displayName = displayName
        self.cachedTitle = cachedTitle
        self.cachedSubtitle = cachedSubtitle
        self.cachedCover = cachedCover
    }

    public var label: String {
        let dn = displayName.trimmingCharacters(in: .whitespaces)
        if !dn.isEmpty { return dn }
        let ct = cachedTitle.trimmingCharacters(in: .whitespaces)
        if !ct.isEmpty { return ct }
        return comicId
    }

    public func toJson() -> JSON {
        .object([
            "sourceKey": .string(sourceKey),
            "comicId": .string(comicId),
            "displayName": .string(displayName),
            "cachedTitle": .string(cachedTitle),
            "cachedSubtitle": .string(cachedSubtitle),
            "cachedCover": .string(cachedCover),
        ])
    }

    public static func fromJson(_ json: JSON) -> CollectionMember? {
        guard let sourceKey = json["sourceKey"].stringValue,
              let comicId = json["comicId"].stringValue else { return nil }
        return CollectionMember(
            sourceKey: sourceKey,
            comicId: comicId,
            displayName: json["displayName"].stringValue ?? "",
            cachedTitle: json["cachedTitle"].stringValue ?? "",
            cachedSubtitle: json["cachedSubtitle"].stringValue ?? "",
            cachedCover: json["cachedCover"].stringValue ?? ""
        )
    }
}

public struct ComicCollection: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceKey: String
    public var name: String
    public var customCover: String
    public var displayMode: CollectionDisplayMode
    public var members: [CollectionMember]
    public let createdAt: Date

    public init(
        id: String,
        sourceKey: String,
        name: String,
        members: [CollectionMember],
        customCover: String = "",
        displayMode: CollectionDisplayMode = .flat,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.name = name
        self.members = members
        self.customCover = customCover
        self.displayMode = displayMode
        self.createdAt = createdAt
    }

    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        for m in members {
            let t = m.cachedTitle.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return id
    }

    public func contains(sourceKey: String, comicId: String) -> Bool {
        members.contains { $0.sourceKey == sourceKey && $0.comicId == comicId }
    }

    public var displayCover: String {
        let c = customCover.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { return c }
        for m in members {
            let cv = m.cachedCover.trimmingCharacters(in: .whitespaces)
            if !cv.isEmpty { return cv }
        }
        return ""
    }

    public func toComic() -> Comic {
        Comic(
            id: id,
            title: displayName,
            cover: displayCover,
            subtitle: "\(members.count) comics",
            tags: ["Collection"],
            description: "",
            sourceKey: sourceKey
        )
    }

    public func toJson() -> JSON {
        .object([
            "id": .string(id),
            "sourceKey": .string(sourceKey),
            "name": .string(name),
            "customCover": .string(customCover),
            "displayMode": .string(displayMode.rawValue),
            "members": .array(members.map { $0.toJson() }),
            "createdAt": .int(Int(createdAt.timeIntervalSince1970 * 1000)),
        ])
    }

    public static func fromJson(_ json: JSON) -> ComicCollection? {
        guard let id = json["id"].stringValue,
              let sourceKey = json["sourceKey"].stringValue else { return nil }
        let name = json["name"].stringValue ?? ""
        let customCover = json["customCover"].stringValue ?? ""
        let mode = CollectionDisplayMode.fromName(json["displayMode"].stringValue)
        let members = json["members"].arrayValue?.compactMap { CollectionMember.fromJson($0) } ?? []
        let ms = json["createdAt"].intValue ?? 0
        let createdAt = ms > 0 ? Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0) : Date()

        return ComicCollection(
            id: id,
            sourceKey: sourceKey,
            name: name,
            members: members,
            customCover: customCover,
            displayMode: mode,
            createdAt: createdAt
        )
    }
}

/// 漫画合集管理器（对齐原版 comic_collection_store.dart）。
public final class ComicCollectionStore: @unchecked Sendable {
    public static let shared = ComicCollectionStore()

    public static let settingsKey = "comicCollections"
    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()

    private init() {}

    public static func isCollectionSourceKey(_ key: String) -> Bool {
        key.hasPrefix("collection_")
    }

    public func all() -> [ComicCollection] {
        lock.lock()
        defer { lock.unlock() }
        let raw = AppData.shared.settings[Self.settingsKey].arrayValue ?? []
        return raw.compactMap { ComicCollection.fromJson($0) }
    }

    public func find(id: String) -> ComicCollection? {
        all().first { $0.id == id }
    }

    public func findBySourceKey(_ key: String) -> ComicCollection? {
        all().first { $0.sourceKey == key }
    }

    @discardableResult
    public func create(
        name: String,
        members: [CollectionMember],
        customCover: String = "",
        displayMode: CollectionDisplayMode = .flat
    ) -> ComicCollection {
        var list = all()
        let id = UUID().uuidString.prefix(8).lowercased()
        let sourceKey = "collection_\(id)"
        let collection = ComicCollection(
            id: String(id),
            sourceKey: sourceKey,
            name: name.trimmingCharacters(in: .whitespaces),
            members: sanitizeMembers(members, existing: []),
            customCover: customCover.trimmingCharacters(in: .whitespaces),
            displayMode: displayMode,
            createdAt: Date()
        )
        list.append(collection)
        save(list)
        return collection
    }

    @discardableResult
    public func update(
        id: String,
        name: String? = nil,
        customCover: String? = nil,
        displayMode: CollectionDisplayMode? = nil,
        members: [CollectionMember]? = nil
    ) -> ComicCollection? {
        var list = all()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return nil }
        var c = list[idx]
        if let name { c.name = name.trimmingCharacters(in: .whitespaces) }
        if let customCover { c.customCover = customCover.trimmingCharacters(in: .whitespaces) }
        if let displayMode { c.displayMode = displayMode }
        if let members { c.members = sanitizeMembers(members, existing: []) }
        list[idx] = c
        save(list)
        return c
    }

    @discardableResult
    public func addMembers(id: String, incoming: [CollectionMember]) -> Int {
        var list = all()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return 0 }
        var c = list[idx]
        let before = c.members.count
        let sanitized = sanitizeMembers(incoming, existing: c.members)
        c.members.append(contentsOf: sanitized)
        let added = c.members.count - before
        if added > 0 {
            list[idx] = c
            save(list)
        }
        return added
    }

    public func removeMember(id: String, sourceKey: String, comicId: String) {
        var list = all()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].members.removeAll { $0.sourceKey == sourceKey && $0.comicId == comicId }
        save(list)
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

    private func sanitizeMembers(_ incoming: [CollectionMember], existing: [CollectionMember]) -> [CollectionMember] {
        var seen = Set(existing.map { $0.id })
        var result: [CollectionMember] = []
        for m in incoming {
            if m.sourceKey.isEmpty || m.comicId.isEmpty { continue }
            if Self.isCollectionSourceKey(m.sourceKey) { continue }
            if seen.insert(m.id).inserted {
                result.append(m)
            }
        }
        return result
    }

    private func save(_ list: [ComicCollection]) {
        AppData.shared.settings[Self.settingsKey] = .array(list.map { $0.toJson() })
        AppData.shared.saveData(sync: true)
        onChange.emit(())
    }
}
