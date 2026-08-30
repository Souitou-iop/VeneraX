import Foundation

/// 本地漫画管理器（对齐原版 local.dart 中的 LocalManager）。
/// 负责 `local.db` 读写、存储目录管理、章节删除与文件查找。
public final class LocalManager: @unchecked Sendable {
    public static let shared = LocalManager()

    public let onChange = CallbackRegistry<Void>()

    private var dbPath: String { AppPaths.join(AppPaths.dataPath, "local.db") }
    private var db: SQLiteDatabase {
        DatabaseGateway.shared.openManagedRecovering(dbPath)
    }

    public var path: String {
        get { AppPaths.localComicsPath }
        set { AppPaths.setLocalComicsPath(newValue) }
    }

    public init() {
        ensureSchema()
        ensureDirectory()
    }

    public func ensureDirectory() {
        let dir = path
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    public func ensureSchema() {
        db.executeRaw("""
        CREATE TABLE IF NOT EXISTS comics (
            id TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            tags TEXT NOT NULL,
            directory TEXT NOT NULL,
            chapters TEXT NOT NULL,
            cover TEXT NOT NULL,
            comic_type INTEGER NOT NULL,
            downloadedChapters TEXT NOT NULL,
            created_at INTEGER,
            description TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, comic_type)
        );
        """)
        let columns = (try? db.tableColumns("comics")) ?? []
        if !columns.contains("description") {
            db.executeRaw("ALTER TABLE comics ADD COLUMN description TEXT NOT NULL DEFAULT '';")
        }
    }

    // MARK: - 查询

    public func find(id: String, type: Int) -> LocalComic? {
        guard let row = try? db.selectFirst(
            "SELECT * FROM comics WHERE id = ? AND comic_type = ?;",
            [.text(id), .int(type)]
        ) else { return nil }
        return LocalComic.fromRow(row)
    }

    public func findByName(_ name: String) -> LocalComic? {
        guard let row = try? db.selectFirst(
            "SELECT * FROM comics WHERE title = ? OR directory = ? LIMIT 1;",
            [.text(name), .text(name)]
        ) else { return nil }
        return LocalComic.fromRow(row)
    }

    public func search(_ keyword: String) -> [LocalComic] {
        let pattern = "%\(keyword)%"
        let rows = (try? db.select(
            "SELECT * FROM comics WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ? ORDER BY created_at DESC;",
            [.text(pattern), .text(pattern), .text(pattern)]
        )) ?? []
        return rows.map(LocalComic.fromRow)
    }

    public func getRecent(_ limit: Int = 20) -> [LocalComic] {
        let rows = (try? db.select(
            "SELECT * FROM comics ORDER BY created_at DESC LIMIT ?;",
            [.int(limit)]
        )) ?? []
        return rows.map(LocalComic.fromRow)
    }

    public var count: Int {
        (try? db.selectValue("SELECT COUNT(*) FROM comics;"))?.intValue ?? 0
    }

    public func getComics(_ sortType: LocalSortType = .defaultSort) -> [LocalComic] {
        switch sortType {
        case .author:
            var all = (try? db.select("SELECT * FROM comics;"))?.map(LocalComic.fromRow) ?? []
            all.sort { $0.subtitle.localizedStandardCompare($1.subtitle) == .orderedAscending }
            return all
        case .lastRead:
            var all = (try? db.select("SELECT * FROM comics;"))?.map(LocalComic.fromRow) ?? []
            all.sort { a, b in
                let timeA = HistoryManager.shared.findHistory(id: a.id, type: a.comicType)?.time ?? Date.distantPast
                let timeB = HistoryManager.shared.findHistory(id: b.id, type: b.comicType)?.time ?? Date.distantPast
                return timeA > timeB
            }
            return all
        case .name:
            let rows = (try? db.select("SELECT * FROM comics ORDER BY title ASC;")) ?? []
            return rows.map(LocalComic.fromRow)
        case .nameDesc:
            let rows = (try? db.select("SELECT * FROM comics ORDER BY title DESC;")) ?? []
            return rows.map(LocalComic.fromRow)
        case .timeAsc:
            let rows = (try? db.select("SELECT * FROM comics ORDER BY created_at ASC;")) ?? []
            return rows.map(LocalComic.fromRow)
        case .timeDesc, .defaultSort:
            let rows = (try? db.select("SELECT * FROM comics ORDER BY created_at DESC;")) ?? []
            return rows.map(LocalComic.fromRow)
        }
    }

    public func getComicsByStatus(_ status: LocalComicStatus, _ sortType: LocalSortType = .defaultSort) -> [LocalComic] {
        getComics(sortType).filter { $0.status == status }
    }

    // MARK: - 增删改

    public func findValidId(comicType: Int) -> String {
        guard let row = try? db.selectFirst(
            "SELECT id FROM comics WHERE comic_type = ? ORDER BY CAST(id AS INTEGER) DESC LIMIT 1;",
            [.int(comicType)]
        ), let idText = row["id"]?.textValue, let idInt = Int(idText) else {
            return "1"
        }
        return String(idInt + 1)
    }

    public func add(_ comic: LocalComic, id: String? = nil) {
        let finalId = id ?? comic.id
        var downloaded = comic.downloadedChapters
        if let existing = find(id: finalId, type: comic.comicType) {
            var set = Set(existing.downloadedChapters)
            set.formUnion(downloaded)
            downloaded = Array(set)
        }
        let tagsJson = (try? JSON.array(comic.tags.map { .string($0) }).encodedString()) ?? "[]"
        let chaptersJson = comic.chapters.map { (try? $0.toJson().encodedString()) ?? "{}" } ?? "{}"
        let dlJson = (try? JSON.array(downloaded.map { .string($0) }).encodedString()) ?? "[]"
        let createdAtMs = Int64(comic.createdAt.timeIntervalSince1970 * 1000)

        try? db.execute("""
        INSERT OR REPLACE INTO comics
        (id, title, subtitle, tags, directory, chapters, cover, comic_type, downloadedChapters, created_at, description)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .text(finalId),
            .text(comic.title),
            .text(comic.subtitle),
            .text(tagsJson),
            .text(comic.directory),
            .text(chaptersJson),
            .text(comic.cover),
            .int(comic.comicType),
            .text(dlJson),
            .int(Int(createdAtMs)),
            .text(comic.description),
        ])
        onChange.emit(())
    }

    public func remove(id: String, type: Int) {
        try? db.execute("DELETE FROM comics WHERE id = ? AND comic_type = ?;", [.text(id), .int(type)])
        onChange.emit(())
    }

    public func deleteComicChapters(_ comic: LocalComic, chapters: [String]) {
        guard !chapters.isEmpty else { return }
        let toRemove = Set(chapters)
        let remaining = comic.downloadedChapters.filter { !toRemove.contains($0) }
        if !remaining.isEmpty {
            let dlJson = (try? JSON.array(remaining.map { .string($0) }).encodedString()) ?? "[]"
            try? db.execute(
                "UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;",
                [.text(dlJson), .text(comic.id), .int(comic.comicType)]
            )
        } else {
            try? db.execute(
                "DELETE FROM comics WHERE id = ? AND comic_type = ?;",
                [.text(comic.id), .int(comic.comicType)]
            )
        }

        for chapter in chapters {
            let chDirName = Self.getChapterDirectoryName(chapter)
            let chapterPath = AppPaths.join(comic.baseDir, chDirName)
            if FileManager.default.fileExists(atPath: chapterPath) {
                try? FileManager.default.removeItem(atPath: chapterPath)
            }
        }
        onChange.emit(())
    }

    public func batchDeleteComics(
        _ comics: [LocalComic],
        removeFiles: Bool = true,
        removeFavoriteAndHistory: Bool = true
    ) {
        guard !comics.isEmpty else { return }
        try? db.transaction {
            for c in comics {
                try? db.execute("DELETE FROM comics WHERE id = ? AND comic_type = ?;", [.text(c.id), .int(c.comicType)])
            }
        }

        if removeFavoriteAndHistory {
            for c in comics {
                let folders = LocalFavoritesManager.shared.getFoldersContaining(id: c.id, type: c.comicType)
                for folder in folders {
                    LocalFavoritesManager.shared.removeFavorite(id: c.id, type: c.comicType, folder: folder)
                }
                HistoryManager.shared.removeFromHistory(id: c.id, type: c.comicType)
            }
        }

        if removeFiles {
            for c in comics {
                let dir = c.baseDir
                if FileManager.default.fileExists(atPath: dir) {
                    try? FileManager.default.removeItem(atPath: dir)
                }
            }
        }
        onChange.emit(())
    }

    // MARK: - 目录与路径辅助

    public static func getChapterDirectoryName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var result = ""
        for scalar in name.unicodeScalars {
            if invalidChars.contains(scalar) {
                result.append("_")
            } else {
                result.append(String(scalar))
            }
        }
        return result.isEmpty ? "_" : result
    }

    public static func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var result = ""
        for scalar in name.unicodeScalars {
            if invalidChars.contains(scalar) {
                result.append("_")
            } else {
                result.append(String(scalar))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func findValidDirectoryName(base: String, name: String) -> String {
        var sanitized = Self.sanitizeFileName(name)
        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80))
        }
        var candidate = sanitized
        var index = 1
        while FileManager.default.fileExists(atPath: AppPaths.join(base, candidate)) {
            candidate = "\(sanitized)_\(index)"
            index += 1
        }
        return candidate
    }

    public func findValidDirectory(id: String, type: Int, title: String) -> String {
        if let existing = find(id: id, type: type) {
            return existing.baseDir
        }
        let dirName = findValidDirectoryName(base: path, name: title)
        let fullPath = AppPaths.join(path, dirName)
        if !FileManager.default.fileExists(atPath: fullPath) {
            try? FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
        }
        return fullPath
    }

    // MARK: - 图片检索与状态判定

    public func getImages(id: String, type: Int, ep: Any) -> [String] {
        guard let comic = find(id: id, type: type) else { return [] }
        var targetDir = comic.baseDir
        if comic.hasChapters, let chapters = comic.chapters {
            let cid: String
            if let epInt = ep as? Int {
                if chapters.ids.indices.contains(epInt - 1) {
                    cid = chapters.ids[epInt - 1]
                } else {
                    cid = String(epInt)
                }
            } else if let epStr = ep as? String {
                cid = epStr
            } else {
                cid = String(describing: ep)
            }
            let chDir = Self.getChapterDirectoryName(cid)
            targetDir = AppPaths.join(targetDir, chDir)
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: targetDir) else {
            return []
        }
        var imageFiles: [String] = []
        for file in contents {
            if file.hasPrefix(".") || file.hasPrefix("cover.") || file == "ComicInfo.xml" || file == "metadata.json" {
                continue
            }
            let ext = (file as NSString).pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "webp", "gif", "bmp", "avif"].contains(ext) || ext.isEmpty {
                imageFiles.append(file)
            }
        }
        // 自然数排序 1.jpg, 2.jpg, 10.jpg
        imageFiles.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        return imageFiles.map { "file://\(AppPaths.join(targetDir, $0))" }
    }

    public func isDownloaded(id: String, type: Int, ep: Int? = nil, chapters: ComicChapters? = nil) -> Bool {
        guard let comic = find(id: id, type: type) else { return false }
        guard let ep else { return comic.status == .downloaded }
        guard let chs = chapters ?? comic.chapters else { return comic.status == .downloaded }
        guard chs.ids.indices.contains(ep - 1) else { return false }
        let chapterId = chs.ids[ep - 1]
        return comic.downloadedChapters.contains(chapterId)
    }

    public func isDownloading(id: String, type: Int) -> Bool {
        DownloadManager.shared.isDownloading(id: id, type: type)
    }
}
