import Foundation

public enum LocalComicStatus: String, Sendable, CaseIterable {
    case downloaded
    case downloading
    case notDownloaded
}

public enum LocalSortType: String, Sendable, CaseIterable {
    case defaultSort = "default"
    case name = "name"
    case nameDesc = "name_desc"
    case timeDesc = "time_desc"
    case timeAsc = "time_asc"
    case author = "author"
    case lastRead = "last_read"

    public static func fromString(_ value: String) -> LocalSortType {
        LocalSortType(rawValue: value) ?? .defaultSort
    }
}

/// 本地漫画模型（对齐原版 local.dart 中的 LocalComic）。
/// 包含通过下载管理器落盘的在线漫画与用户自导入（CBZ/ZIP/目录）的本地漫画。
public struct LocalComic: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var tags: [String]
    /// 存储目录名（相对 LocalManager.shared.path，或包含路径分隔符的绝对路径）
    public var directory: String
    /// 章节表（有序字典/分组支持）
    public var chapters: ComicChapters?
    /// 封面文件名（相对 baseDir）
    public var cover: String
    /// 0 为本地导入，非 0 为注册表源 key 对应的 int
    public var comicType: Int
    /// 已下载的章节 ID 列表
    public var downloadedChapters: [String]
    public var createdAt: Date
    public var description: String

    public init(
        id: String,
        title: String,
        subtitle: String,
        tags: [String],
        directory: String,
        chapters: ComicChapters?,
        cover: String,
        comicType: Int,
        downloadedChapters: [String],
        createdAt: Date = Date(),
        description: String = ""
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.directory = directory
        self.chapters = chapters
        self.cover = cover
        self.comicType = comicType
        self.downloadedChapters = downloadedChapters
        self.createdAt = createdAt
        self.description = description
    }

    public var hasChapters: Bool { chapters != nil && !(chapters?.isEmpty ?? true) }

    public var sourceKey: String {
        ComicID(id: id, type: comicType).sourceKey ?? "local"
    }

    public var isPureLocal: Bool { comicType == ComicID.local }

    /// 漫画存放的绝对根目录路径
    public var baseDir: String {
        if directory.contains("/") || directory.contains("\\") {
            return directory
        }
        return AppPaths.join(LocalManager.shared.path, directory)
    }

    /// 封面文件的绝对路径或 URL
    public var coverPath: String {
        if cover.hasPrefix("file://") {
            return String(cover.dropFirst("file://".count))
        }
        if cover.hasPrefix("/") {
            return cover
        }
        return AppPaths.join(baseDir, cover)
    }

    public var coverURL: String {
        if cover.isEmpty { return "" }
        if cover.hasPrefix("http://") || cover.hasPrefix("https://") || cover.hasPrefix("file://") {
            return cover
        }
        return "file://\(coverPath)"
    }

    /// 检查当前漫画的下载/落盘状态
    public var status: LocalComicStatus {
        if LocalManager.shared.isDownloading(id: id, type: comicType) {
            return .downloading
        }
        let dir = baseDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .notDownloaded
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir), !contents.isEmpty else {
            return .notDownloaded
        }
        let hasContent = contents.contains { item in
            let itemPath = AppPaths.join(dir, item)
            var subIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: itemPath, isDirectory: &subIsDir) {
                if !subIsDir.boolValue { return true }
                let subContents = (try? FileManager.default.contentsOfDirectory(atPath: itemPath)) ?? []
                return !subContents.isEmpty
            }
            return false
        }
        return hasContent ? .downloaded : .notDownloaded
    }

    public func toComic() -> Comic {
        Comic(
            id: id,
            title: title,
            cover: coverURL,
            subtitle: subtitle,
            tags: tags,
            description: description,
            sourceKey: sourceKey
        )
    }

    public func toJson() -> JSON {
        var map: [String: JSON] = [
            "id": .string(id),
            "title": .string(title),
            "subTitle": .string(subtitle),
            "tags": .array(tags.map { .string($0) }),
            "directory": .string(directory),
            "cover": .string(cover),
            "sourceKey": .string(sourceKey),
            "comicType": .int(comicType),
            "downloadedChapters": .array(downloadedChapters.map { .string($0) }),
            "created_at": .int(Int(createdAt.timeIntervalSince1970 * 1000)),
            "description": .string(description),
        ]
        if let chapters {
            map["chapters"] = chapters.toJson()
        }
        return .object(map)
    }

    public static func fromRow(_ row: [String: SQLiteValue]) -> LocalComic {
        let id = row["id"]?.textValue ?? ""
        let title = row["title"]?.textValue ?? ""
        let subtitle = row["subtitle"]?.textValue ?? ""
        let directory = row["directory"]?.textValue ?? ""
        let cover = row["cover"]?.textValue ?? ""
        let comicType = row["comic_type"]?.intValue ?? 0
        let description = row["description"]?.textValue ?? ""

        var tags: [String] = []
        if let tagsText = row["tags"]?.textValue, let json = JSON.decode(tagsText), let list = json.arrayValue {
            tags = list.compactMap { $0.stringValue }
        }

        var downloadedChapters: [String] = []
        if let dlText = row["downloadedChapters"]?.textValue, let json = JSON.decode(dlText), let list = json.arrayValue {
            downloadedChapters = list.compactMap { $0.stringValue }
        }

        var chapters: ComicChapters?
        if let chaptersText = row["chapters"]?.textValue, let json = JSON.decode(chaptersText), !json.isNull {
            chapters = ComicChapters.fromJson(json)
        }

        let createdAtMs = row["created_at"]?.int64Value ?? 0
        let createdAt = createdAtMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0)
            : Date()

        return LocalComic(
            id: id,
            title: title,
            subtitle: subtitle,
            tags: tags,
            directory: directory,
            chapters: chapters,
            cover: cover,
            comicType: comicType,
            downloadedChapters: downloadedChapters,
            createdAt: createdAt,
            description: description
        )
    }
}
