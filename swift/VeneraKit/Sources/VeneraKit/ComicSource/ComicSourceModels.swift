import Foundation

// MARK: - 数据模型（对齐 models.dart）

/// 漫画列表条目（JS Comic 构造器产物）。
public struct Comic: Hashable, Sendable {
    public var id: String
    public var title: String
    public var cover: String
    public var subtitle: String
    public var tags: [String]
    public var description: String
    public var sourceKey: String
    public var maxPage: Int?
    public var language: String?
    public var favoriteId: String?
    public var stars: Double?

    public init(
        id: String,
        title: String,
        cover: String,
        subtitle: String = "",
        tags: [String] = [],
        description: String = "",
        sourceKey: String,
        maxPage: Int? = nil,
        language: String? = nil,
        favoriteId: String? = nil,
        stars: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.subtitle = subtitle
        self.tags = tags
        self.description = description
        self.sourceKey = sourceKey
        self.maxPage = maxPage
        self.language = language
        self.favoriteId = favoriteId
        self.stars = stars
    }

    public static func fromJSON(_ json: JSON, sourceKey: String) -> Comic? {
        guard let id = json["id"].stringValue, !id.isEmpty else { return nil }
        return Comic(
            id: id,
            title: json["title"].stringValue ?? "",
            cover: json["cover"].stringValue ?? "",
            subtitle: json["subtitle"].stringValue ?? json["subTitle"].stringValue ?? "",
            tags: json["tags"].arrayValue?.compactMap { $0.stringValue } ?? [],
            description: json["description"].stringValue ?? "",
            sourceKey: sourceKey,
            maxPage: json["maxPage"].intValue,
            language: json["language"].stringValue,
            favoriteId: json["favoriteId"].stringValue,
            stars: json["stars"].doubleValue
        )
    }

    public var json: JSON {
        .object([
            "id": .string(id),
            "title": .string(title),
            "cover": .string(cover),
            "subtitle": .string(subtitle),
            "tags": .array(tags.map { .string($0) }),
            "description": .string(description),
            "sourceKey": .string(sourceKey),
            "maxPage": maxPage.map { .int($0) } ?? .null,
            "language": language.map { .string($0) } ?? .null,
            "favoriteId": favoriteId.map { .string($0) } ?? .null,
            "stars": stars.map { .double($0) } ?? .null,
        ])
    }
}

/// 章节集合：平铺 `Map<id, title>` 或分组 `Map<group, Map<id, title>>`
/// （对齐 ComicChapters；混合时平铺项归入「默认」组）。
/// 章节顺序 = JS 对象键枚举序（原版依赖 Dart Map 保插入序）。Swift 字典
/// 不保序，正式路径由 `ComicSource.loadComicInfo` 在 JS 侧把 chapters 对象
/// 转成保序 entries 数组后走 `fromEntries`；字典 init 仅为兜底（序不可考，
/// 按键名排序保证确定性）。
public struct ComicChapters: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Group: Hashable, Sendable {
        public let name: String
        public let chapters: [Entry]

        public init(name: String, chapters: [Entry]) {
            self.name = name
            self.chapters = chapters
        }
    }

    /// 非分组结构时的有序章节。
    public let flatEntries: [Entry]?
    /// 分组结构（组与组内章节均按源声明顺序）。
    public let groupEntries: [Group]?

    public init(flatEntries: [Entry]) {
        self.flatEntries = flatEntries
        self.groupEntries = nil
    }

    public init(groupEntries: [Group]) {
        self.flatEntries = nil
        self.groupEntries = groupEntries
    }

    /// 兜底解析：字典层键序已丢失，按键名排序保证确定性（正式路径勿用）。
    public init(_ raw: JSON) {
        if let flatMap = raw.objectValue {
            let isGrouped = flatMap.values.contains { $0.objectValue != nil }
            if isGrouped {
                let groups = flatMap.keys.sorted().compactMap { name -> Group? in
                    guard let value = raw[name].objectValue else { return nil }
                    let chapters = value.keys.sorted().compactMap { key -> Entry? in
                        value[key]?.stringValue.map { Entry(id: key, title: $0) }
                    }
                    return Group(name: name, chapters: chapters)
                }
                self.init(groupEntries: groups)
            } else {
                let entries = flatMap.keys.sorted().compactMap { key -> Entry? in
                    flatMap[key]?.stringValue.map { Entry(id: key, title: $0) }
                }
                self.init(flatEntries: entries)
            }
        } else {
            self.init(flatEntries: [])
        }
    }

    /// 保序解析：从 JS 侧提取的 `[[id, title], ...]` 或
    /// `[[groupName, [[id, title], ...]], ...]` 保留插入序。
    public static func fromEntries(_ raw: JSON) -> ComicChapters? {
        guard let list = raw.arrayValue else {
            return nil
        }
        var flat: [Entry] = []
        var groups: [Group] = []
        for item in list {
            guard let pair = item.arrayValue, pair.count >= 2 else { continue }
            let first = pair[0].stringValue ?? ""
            if let nested = pair[1].arrayValue {
                let entries = nested.compactMap { sub -> Entry? in
                    guard let p = sub.arrayValue, p.count >= 2,
                          let id = p[0].stringValue, let title = p[1].stringValue else { return nil }
                    return Entry(id: id, title: title)
                }
                groups.append(Group(name: first, chapters: entries))
            } else if let title = pair[1].stringValue {
                flat.append(Entry(id: first, title: title))
            }
        }
        if !groups.isEmpty {
            if !flat.isEmpty {
                groups.append(Group(name: "默认", chapters: flat))
            }
            return ComicChapters(groupEntries: groups)
        }
        return ComicChapters(flatEntries: flat)
    }

    public var isGrouped: Bool { groupEntries != nil }

    public var isEmpty: Bool {
        if let flatEntries { return flatEntries.isEmpty }
        if let groupEntries { return groupEntries.allSatisfy { $0.chapters.isEmpty } }
        return true
    }

    public var groupNames: [String] {
        groupEntries?.map(\.name) ?? []
    }

    public var ids: [String] {
        if let flatEntries { return flatEntries.map(\.id) }
        if let groupEntries { return groupEntries.flatMap { $0.chapters.map(\.id) } }
        return []
    }

    public var titles: [String] {
        if let flatEntries { return flatEntries.map(\.title) }
        if let groupEntries { return groupEntries.flatMap { $0.chapters.map(\.title) } }
        return []
    }

    public func entries(inGroup groupName: String?) -> [Entry] {
        if let groupEntries {
            if let groupName, let found = groupEntries.first(where: { $0.name == groupName }) {
                return found.chapters
            }
            return groupEntries.first?.chapters ?? []
        }
        return flatEntries ?? []
    }

    public func titleAt(_ ep: Int, group: String? = nil) -> String? {
        let list = entries(inGroup: group)
        guard ep >= 1, ep <= list.count else { return nil }
        return list[ep - 1].title
    }

    public func idAt(_ ep: Int, group: String? = nil) -> String? {
        let list = entries(inGroup: group)
        guard ep >= 1, ep <= list.count else { return nil }
        return list[ep - 1].id
    }

    public func toJson() -> JSON {
        if let groupEntries {
            var groupObj: [String: JSON] = [:]
            for group in groupEntries {
                var chObj: [String: JSON] = [:]
                for entry in group.chapters {
                    chObj[entry.id] = .string(entry.title)
                }
                groupObj[group.name] = .object(chObj)
            }
            return .object(groupObj)
        } else if let flatEntries {
            var chObj: [String: JSON] = [:]
            for entry in flatEntries {
                chObj[entry.id] = .string(entry.title)
            }
            return .object(chObj)
        }
        return .object([:])
    }

    public static func fromJson(_ json: JSON) -> ComicChapters {
        ComicChapters(json)
    }
}

/// 漫画详情（JS ComicDetails 构造器产物）。
public struct ComicDetails: Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var cover: String
    public var description: String
    public var tags: [String: [String]]
    public var chapters: ComicChapters?
    public var sourceKey: String
    public var isFavorite: Bool?
    public var subId: String?
    public var thumbnails: [String]?
    public var recommend: [Comic]
    public var commentCount: Int?
    public var likesCount: Int?
    public var isLiked: Bool?
    public var uploader: String?
    public var updateTime: String?
    public var uploadTime: String?
    public var url: String?
    public var stars: Double?
    public var maxPage: Int?

    public init(
        id: String,
        title: String,
        subtitle: String,
        cover: String,
        description: String,
        tags: [String: [String]],
        chapters: ComicChapters?,
        sourceKey: String,
        isFavorite: Bool? = nil,
        subId: String? = nil,
        thumbnails: [String]? = nil,
        recommend: [Comic] = [],
        commentCount: Int? = nil,
        likesCount: Int? = nil,
        isLiked: Bool? = nil,
        uploader: String? = nil,
        updateTime: String? = nil,
        uploadTime: String? = nil,
        url: String? = nil,
        stars: Double? = nil,
        maxPage: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.description = description
        self.tags = tags
        self.chapters = chapters
        self.sourceKey = sourceKey
        self.isFavorite = isFavorite
        self.subId = subId
        self.thumbnails = thumbnails
        self.recommend = recommend
        self.commentCount = commentCount
        self.likesCount = likesCount
        self.isLiked = isLiked
        self.uploader = uploader
        self.updateTime = updateTime
        self.uploadTime = uploadTime
        self.url = url
        self.stars = stars
        self.maxPage = maxPage
    }

    public static func fromJSON(_ json: JSON, id: String, sourceKey: String) -> ComicDetails {
        var tags: [String: [String]] = [:]
        if let rawTags = json["tags"].objectValue {
            for (namespace, values) in rawTags {
                tags[namespace] = values.arrayValue?.compactMap { $0.stringValue } ?? []
            }
        }
        var chapters: ComicChapters?
        if !json["chapters"].isNull, json["chapters"].objectValue != nil {
            chapters = ComicChapters(json["chapters"])
        }
        return ComicDetails(
            id: id,
            title: json["title"].stringValue ?? "",
            subtitle: json["subtitle"].stringValue ?? json["subTitle"].stringValue ?? "",
            cover: json["cover"].stringValue ?? "",
            description: json["description"].stringValue ?? "",
            tags: tags,
            chapters: chapters,
            sourceKey: sourceKey,
            isFavorite: json["isFavorite"].boolValue,
            subId: json["subId"].stringValue,
            thumbnails: json["thumbnails"].arrayValue?.compactMap { $0.stringValue },
            recommend: json["recommend"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: sourceKey) } ?? [],
            commentCount: json["commentCount"].intValue,
            likesCount: json["likesCount"].intValue,
            isLiked: json["isLiked"].boolValue,
            uploader: json["uploader"].stringValue,
            updateTime: json["updateTime"].stringValue,
            uploadTime: json["uploadTime"].stringValue,
            url: json["url"].stringValue,
            stars: json["stars"].doubleValue,
            maxPage: json["maxPage"].intValue
        )
    }

    public func toJson() -> JSON {
        var map: [String: JSON] = [
            "id": .string(id),
            "title": .string(title),
            "subtitle": .string(subtitle),
            "cover": .string(cover),
            "description": .string(description),
            "sourceKey": .string(sourceKey),
        ]
        var tagMap: [String: JSON] = [:]
        for (k, v) in tags {
            tagMap[k] = .array(v.map { .string($0) })
        }
        map["tags"] = .object(tagMap)
        if let chapters {
            map["chapters"] = chapters.toJson()
        }
        if let isFavorite { map["isFavorite"] = .bool(isFavorite) }
        if let subId { map["subId"] = .string(subId) }
        if let thumbnails { map["thumbnails"] = .array(thumbnails.map { .string($0) }) }
        if !recommend.isEmpty { map["recommend"] = .array(recommend.map { $0.json }) }
        if let commentCount { map["commentCount"] = .int(commentCount) }
        if let likesCount { map["likesCount"] = .int(likesCount) }
        if let isLiked { map["isLiked"] = .bool(isLiked) }
        if let uploader { map["uploader"] = .string(uploader) }
        if let updateTime { map["updateTime"] = .string(updateTime) }
        if let uploadTime { map["uploadTime"] = .string(uploadTime) }
        if let url { map["url"] = .string(url) }
        if let stars { map["stars"] = .double(stars) }
        if let maxPage { map["maxPage"] = .int(maxPage) }
        return .object(map)
    }

    public static func fromJson(_ json: JSON) -> ComicDetails? {
        guard let id = json["id"].stringValue, !id.isEmpty else { return nil }
        let sourceKey = json["sourceKey"].stringValue ?? ""
        return fromJSON(json, id: id, sourceKey: sourceKey)
    }
}

/// 评论（JS Comment 构造器产物）。
public struct Comment: Sendable {
    public var userName: String
    public var avatar: String?
    public var content: String
    public var time: String?
    public var replyCount: Int?
    public var id: String?
    public var isLiked: Bool?
    public var score: Double?
    public var voteStatus: Int?

    public static func fromJSON(_ json: JSON) -> Comment {
        Comment(
            userName: json["userName"].stringValue ?? "",
            avatar: json["avatar"].stringValue,
            content: json["content"].stringValue ?? "",
            time: json["time"].stringValue ?? (json["time"].intValue.map(String.init)),
            replyCount: json["replyCount"].intValue,
            id: json["id"].stringValue ?? json["id"].intValue.map(String.init),
            isLiked: json["isLiked"].boolValue,
            score: json["score"].doubleValue,
            voteStatus: json["voteStatus"].intValue
        )
    }
}

/// 源设置表单项（settings 声明）。
public struct SourceSetting: Sendable {
    public enum ItemType: String, Sendable {
        case select, `switch`, input, callback
    }

    public var key: String
    public var title: String
    public var type: ItemType
    public var defaultValue: JSON
    public var options: [(value: String, text: String)]

    public static func parse(from json: JSON, key: String) -> SourceSetting? {
        guard let typeString = json["type"].stringValue, let type = ItemType(rawValue: typeString) else {
            return nil
        }
        var options: [(String, String)] = []
        if let rawOptions = json["options"].arrayValue {
            for option in rawOptions {
                if let value = option["value"].stringValue {
                    options.append((value, option["text"].stringValue ?? value))
                }
            }
        }
        return SourceSetting(
            key: key,
            title: json["title"].stringValue ?? key,
            type: type,
            defaultValue: json["default"],
            options: options
        )
    }
}
