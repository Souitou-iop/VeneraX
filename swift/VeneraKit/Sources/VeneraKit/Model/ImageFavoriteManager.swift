import Foundation

public struct SingleImageFavorite: Equatable, Sendable, Identifiable {
    public var id: String { "\(sourceKey)_\(comicId)_\(epIndex)_\(pageIndex)" }
    public let comicId: String
    public let sourceKey: String
    public let title: String
    public let subtitle: String
    public let epIndex: Int
    public let epTitle: String
    public let pageIndex: Int
    public let imageKey: String
    public let localFilePath: String?
    public let createdAt: Date

    public init(
        comicId: String,
        sourceKey: String,
        title: String,
        subtitle: String = "",
        epIndex: Int,
        epTitle: String = "",
        pageIndex: Int,
        imageKey: String,
        localFilePath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.comicId = comicId
        self.sourceKey = sourceKey
        self.title = title
        self.subtitle = subtitle
        self.epIndex = epIndex
        self.epTitle = epTitle
        self.pageIndex = pageIndex
        self.imageKey = imageKey
        self.localFilePath = localFilePath
        self.createdAt = createdAt
    }
}

/// 单图收藏管理器（存储于 history.db 的 image_favorites 表中）。
public final class ImageFavoriteManager: @unchecked Sendable {
    public static let shared = ImageFavoriteManager()

    public let onChange = CallbackRegistry<Void>()

    private var dbPath: String { AppPaths.join(AppPaths.dataPath, "history.db") }
    private var db: SQLiteDatabase {
        DatabaseGateway.shared.openManagedRecovering(dbPath)
    }

    private init() {
        ensureSchema()
    }

    public func ensureSchema() {
        db.executeRaw("""
        CREATE TABLE IF NOT EXISTS single_image_favorites (
            comic_id TEXT NOT NULL,
            source_key TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            ep_index INTEGER NOT NULL,
            ep_title TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            image_key TEXT NOT NULL,
            local_file TEXT,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (comic_id, source_key, ep_index, page_index)
        );
        """)

        // Flutter stores grouped image favorites in image_favorites. Migrate the
        // legacy rows once after a backup restore so the Swift reader can show
        // them without changing the original database contract.
        guard let legacyRows = try? db.select("SELECT id, title, sub_title, source_key, image_favorites_ep, time FROM image_favorites;") else { return }
        for row in legacyRows {
            guard let comicID = row["id"]?.textValue,
                  let sourceKey = row["source_key"]?.textValue,
                  let raw = row["image_favorites_ep"]?.textValue,
                  let episodes = JSON.decode(raw)?.arrayValue else { continue }
            let title = row["title"]?.textValue ?? ""
            let subtitle = row["sub_title"]?.textValue ?? ""
            let createdAt = row["time"]?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
            for episode in episodes {
                let epIndex = max(0, (episode["ep"].intValue ?? 1) - 1)
                let epTitle = episode["epName"].stringValue ?? ""
                guard let images = episode["imageFavorites"].arrayValue else { continue }
                for image in images {
                    guard let page = image["page"].intValue, page > 0,
                          let imageKey = image["imageKey"].stringValue else { continue }
                    let pageIndex = page - 1
                    let exists = (try? db.selectFirst("SELECT 1 FROM single_image_favorites WHERE comic_id = ? AND source_key = ? AND ep_index = ? AND page_index = ? LIMIT 1;", [.text(comicID), .text(sourceKey), .int(epIndex), .int(pageIndex)]))?.isEmpty == false
                    if exists { continue }
                    try? db.execute("""
                    INSERT INTO single_image_favorites
                    (comic_id, source_key, title, subtitle, ep_index, ep_title, page_index, image_key, local_file, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?);
                    """, [.text(comicID), .text(sourceKey), .text(title), .text(subtitle), .int(epIndex), .text(epTitle), .int(pageIndex), .text(imageKey), .int(Int(createdAt))])
                }
            }
        }
    }

    public func isFavorited(comicId: String, sourceKey: String, epIndex: Int, pageIndex: Int) -> Bool {
        guard let row = try? db.selectFirst(
            "SELECT 1 FROM single_image_favorites WHERE comic_id = ? AND source_key = ? AND ep_index = ? AND page_index = ? LIMIT 1;",
            [.text(comicId), .text(sourceKey), .int(epIndex), .int(pageIndex)]
        ) else { return false }
        return row.count > 0
    }

    public func addFavorite(
        comicId: String,
        sourceKey: String,
        title: String,
        subtitle: String,
        epIndex: Int,
        epTitle: String,
        pageIndex: Int,
        imageKey: String,
        imageData: Data? = nil
    ) {
        // INSERT OR REPLACE deletes the old row first. Preserve its local file when
        // the caller only refreshes metadata (imageData == nil), otherwise a
        // perfectly valid offline favorite silently becomes remote-only.
        let existingLocalFile = (try? db.selectFirst(
            "SELECT local_file FROM single_image_favorites WHERE comic_id = ? AND source_key = ? AND ep_index = ? AND page_index = ?;",
            [.text(comicId), .text(sourceKey), .int(epIndex), .int(pageIndex)]
        ))?["local_file"]?.textValue

        var localFile: String? = existingLocalFile?.isEmpty == false ? existingLocalFile : nil
        var replacementFile: String?
        if let imageData, imageData.count > 50 {
            let favDir = AppPaths.join(AppPaths.dataPath, "image_favorites")
            try? FileManager.default.createDirectory(atPath: favDir, withIntermediateDirectories: true)
            let fileType = FileTypeDetector.detect(data: imageData)
            let safeName = "\(sourceKey)_\(comicId)_\(epIndex)_\(pageIndex)\(fileType.ext)"
            let destPath = AppPaths.join(favDir, safeName)
            do {
                try imageData.write(to: URL(fileURLWithPath: destPath), options: .atomic)
                localFile = destPath
                replacementFile = destPath == existingLocalFile ? nil : existingLocalFile
            } catch {
                Log.warning("Image Favorites", "Failed to persist image favorite: \(error)")
            }
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try db.execute("""
            INSERT OR REPLACE INTO single_image_favorites
            (comic_id, source_key, title, subtitle, ep_index, ep_title, page_index, image_key, local_file, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(comicId),
                .text(sourceKey),
                .text(title),
                .text(subtitle),
                .int(epIndex),
                .text(epTitle),
                .int(pageIndex),
                .text(imageKey),
                localFile.map { .text($0) } ?? .null,
                .int(Int(now)),
            ])
        } catch {
            Log.warning("Image Favorites", "Failed to update metadata: \(error)")
            return
        }
        // Remove an obsolete extension/file only after the new row has been
        // written successfully; never delete the current replacement.
        if let replacementFile, replacementFile != localFile {
            try? FileManager.default.removeItem(atPath: replacementFile)
        }
        onChange.emit(())
        AppData.shared.saveData(sync: true)
    }

    public func removeFavorites(_ favorites: [SingleImageFavorite]) {
        for favorite in favorites {
            removeFavorite(
                comicId: favorite.comicId,
                sourceKey: favorite.sourceKey,
                epIndex: favorite.epIndex,
                pageIndex: favorite.pageIndex
            )
        }
    }

    public func removeFavorite(comicId: String, sourceKey: String, epIndex: Int, pageIndex: Int) {
        if let row = try? db.selectFirst(
            "SELECT local_file FROM single_image_favorites WHERE comic_id = ? AND source_key = ? AND ep_index = ? AND page_index = ?;",
            [.text(comicId), .text(sourceKey), .int(epIndex), .int(pageIndex)]
        ), let path = row["local_file"]?.textValue, !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }

        try? db.execute(
            "DELETE FROM single_image_favorites WHERE comic_id = ? AND source_key = ? AND ep_index = ? AND page_index = ?;",
            [.text(comicId), .text(sourceKey), .int(epIndex), .int(pageIndex)]
        )
        onChange.emit(())
        AppData.shared.saveData(sync: true)
    }

    public func getAll() -> [SingleImageFavorite] {
        let rows = (try? db.select("SELECT * FROM single_image_favorites ORDER BY created_at DESC;")) ?? []
        return rows.compactMap { row in
            guard let comicId = row["comic_id"]?.textValue,
                  let sourceKey = row["source_key"]?.textValue else { return nil }
            let title = row["title"]?.textValue ?? ""
            let subtitle = row["subtitle"]?.textValue ?? ""
            let epIndex = row["ep_index"]?.intValue ?? 0
            let epTitle = row["ep_title"]?.textValue ?? ""
            let pageIndex = row["page_index"]?.intValue ?? 0
            let imageKey = row["image_key"]?.textValue ?? ""
            let localFile = row["local_file"]?.textValue
            let ms = row["created_at"]?.int64Value ?? 0
            let createdAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)

            return SingleImageFavorite(
                comicId: comicId,
                sourceKey: sourceKey,
                title: title,
                subtitle: subtitle,
                epIndex: epIndex,
                epTitle: epTitle,
                pageIndex: pageIndex,
                imageKey: imageKey,
                localFilePath: localFile,
                createdAt: createdAt
            )
        }
    }

    public var count: Int {
        (try? db.selectValue("SELECT COUNT(*) FROM single_image_favorites;"))?.intValue ?? 0
    }
}
