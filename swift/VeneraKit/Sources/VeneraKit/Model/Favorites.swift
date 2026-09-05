import Foundation

/// 本地收藏条目。列与 FavoriteItem.fromRow 一致：tags 逗号连接（兼容
/// JSON 数组形式）、time 为 "yyyy-MM-dd HH:mm:ss" 文本、authors 为 JSON
/// 数组、extra_meta 为 JSON 对象。
public struct FavoriteItem: Equatable, Sendable {
    public var id: String
    public var name: String
    public var author: String
    public var type: Int
    public var tags: [String]
    public var coverPath: String
    public var time: String
    public var displayOrder: Int?
    public var authors: [String]
    public var status: String?
    public var updateTimeMeta: String?
    public var extraMeta: [String: String]
    // 追更列（follow_updates）
    public var lastUpdateTime: String?
    public var hasNewUpdate: Bool?
    public var lastCheckTime: Int?

    public init(
        id: String,
        name: String,
        coverPath: String,
        author: String,
        type: Int,
        tags: [String],
        favoriteTime: Date = Date(),
        authors: [String] = [],
        status: String? = nil,
        updateTimeMeta: String? = nil,
        extraMeta: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.type = type
        self.tags = tags
        self.coverPath = coverPath
        self.time = Self.timeString(from: favoriteTime)
        self.displayOrder = nil
        self.authors = authors
        self.status = status
        self.updateTimeMeta = updateTimeMeta
        self.extraMeta = extraMeta
    }

    /// 原版格式：ISO8601 去掉 T、截到秒。
    public static func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    init(row: [String: SQLiteValue]) {
        id = row["id"]?.textValue ?? ""
        name = row["name"]?.textValue ?? ""
        author = row["author"]?.textValue ?? ""
        type = row["type"]?.intValue ?? 0
        coverPath = row["cover_path"]?.textValue ?? ""
        time = row["time"]?.textValue ?? ""
        displayOrder = row["display_order"]?.intValue
        status = row["comic_status"]?.textValue.flatMap { $0.isEmpty ? nil : $0 }
        updateTimeMeta = row["update_time_meta"]?.textValue.flatMap { $0.isEmpty ? nil : $0 }
        lastUpdateTime = row["last_update_time"]?.textValue
        hasNewUpdate = row["has_new_update"]?.intValue.map { $0 != 0 }
        lastCheckTime = row["last_check_time"]?.intValue

        var parsedTags: [String] = []
        if let text = row["tags"]?.textValue {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let json = JSON.decode(trimmed), let list = json.arrayValue {
                    parsedTags = list.compactMap { $0.stringValue }
                }
            } else if !trimmed.isEmpty {
                parsedTags = trimmed.split(separator: ",").map(String.init)
            }
        }
        parsedTags.removeAll { $0.isEmpty }
        tags = parsedTags

        if let text = row["authors"]?.textValue, let json = JSON.decode(text), let list = json.arrayValue {
            authors = list.compactMap { $0.stringValue }
        } else {
            authors = []
        }
        if let text = row["extra_meta"]?.textValue, let json = JSON.decode(text), let map = json.objectValue {
            extraMeta = map.compactMapValues { $0.stringValue }
        } else {
            extraMeta = [:]
        }
    }

    public var comicID: ComicID { ComicID(id: id, type: type) }

    /// 原版 FavoriteItem.toJson（用于网络收藏夹同步/收藏操作负载）。
    public func toJson() -> JSON {
        var map: [String: JSON] = [
            "name": .string(name),
            "author": .string(author),
            "type": .int(type),
            "tags": .array(tags.map { .string($0) }),
            "id": .string(id),
            "coverPath": .string(coverPath),
        ]
        if let key = ComicID(id: id, type: type).sourceKey {
            map["sourceKey"] = .string(key)
        }
        if !authors.isEmpty {
            map["authors"] = .array(authors.map { .string($0) })
        }
        if let status { map["status"] = .string(status) }
        if let updateTimeMeta { map["updateTimeMeta"] = .string(updateTimeMeta) }
        if !extraMeta.isEmpty {
            map["extraMeta"] = .object(extraMeta.mapValues { .string($0) })
        }
        if let lastUpdateTime { map["lastUpdateTime"] = .string(lastUpdateTime) }
        if let hasNewUpdate { map["hasNewUpdate"] = .bool(hasNewUpdate) }
        if let lastCheckTime { map["lastCheckTime"] = .int(lastCheckTime) }
        return .object(map)
    }

    public static func fromJson(_ json: JSON) -> FavoriteItem? {
        guard let id = json["id"].stringValue ?? json["target"].stringValue,
              let name = json["name"].stringValue else { return nil }
        var tags: [String] = []
        if let list = json["tags"].arrayValue {
            tags = list.compactMap { $0.stringValue }
        } else if let text = json["tags"].stringValue {
            tags = text.split(separator: ",").map(String.init)
        }
        var authors: [String] = []
        if let list = json["authors"].arrayValue {
            authors = list.compactMap { $0.stringValue }
        }
        var extra: [String: String] = [:]
        if let map = json["extraMeta"].objectValue {
            extra = map.compactMapValues { $0.stringValue }
        }
        var item = FavoriteItem(
            id: id,
            name: name,
            coverPath: json["coverPath"].stringValue ?? json["cover_path"].stringValue ?? "",
            author: json["author"].stringValue ?? "",
            type: json["type"].intValue ?? 0,
            tags: tags,
            authors: authors,
            status: json["status"].stringValue ?? json["comic_status"].stringValue,
            updateTimeMeta: json["updateTimeMeta"].stringValue ?? json["update_time_meta"].stringValue,
            extraMeta: extra
        )
        item.lastUpdateTime = json["lastUpdateTime"].stringValue ?? json["last_update_time"].stringValue
        item.hasNewUpdate = json["hasNewUpdate"].boolValue ?? json["has_new_update"].boolValue
        item.lastCheckTime = json["lastCheckTime"].intValue ?? json["last_check_time"].intValue
        return item
    }
}

/// 本地收藏夹管理器（local_favorite.db）。每个收藏夹一张同名表；
/// folder_order 记录排序；folder_sync 记录网络收藏夹映射。
public final class LocalFavoritesManager: @unchecked Sendable {
    public static let shared = LocalFavoritesManager()

    public let onChange = CallbackRegistry<Void>()

    public let customDataPath: String?

    private var dbPath: String {
        AppPaths.join(customDataPath ?? AppPaths.dataPath, "local_favorite.db")
    }

    private var db: SQLiteDatabase {
        DatabaseGateway.shared.openManagedRecovering(dbPath)
    }

    public init(dataPath: String? = nil) {
        self.customDataPath = dataPath
        ensureSchema()
    }

    public func ensureSchema() {
        db.executeRaw("""
        create table if not exists folder_order (
          folder_name text primary key,
          order_value int
        );
        """)
        db.executeRaw("""
        create table if not exists folder_sync (
          folder_name text primary key,
          source_key text,
          source_folder text
        );
        """)
    }

    private func createFolderTable(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        db.executeRaw("""
        create table if not exists "\(escaped)"(
          id text,
          name TEXT,
          author TEXT,
          type int,
          tags TEXT,
          cover_path TEXT,
          time TEXT,
          last_read int,
          display_order int,
          authors TEXT,
          comic_status TEXT,
          update_time_meta TEXT,
          extra_meta TEXT,
          PRIMARY KEY (id, type)
        );
        """)
    }

    // MARK: - 文件夹管理

    public func getFolders() -> [String] {
        let rows = (try? db.select("""
        select name from sqlite_master
        where type = 'table'
          and name not in ('folder_order', 'folder_sync', 'sqlite_sequence')
          and name not like 'sqlite_%';
        """)) ?? []
        return rows.compactMap { $0["name"]?.textValue }
    }

    /// 依 folder_order 排序（未排序的按名字升序）。
    public func getFoldersSorted() -> [String] {
        let folders = getFolders()
        let orders = getFolderOrders()
        return folders.sorted { a, b in
            let orderA = orders[a] ?? Int.max
            let orderB = orders[b] ?? Int.max
            if orderA != orderB { return orderA < orderB }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    public func getFolderOrders() -> [String: Int] {
        let rows = (try? db.select("select folder_name, order_value from folder_order;")) ?? []
        var result: [String: Int] = [:]
        for row in rows {
            if let name = row["folder_name"]?.textValue, let order = row["order_value"]?.intValue {
                result[name] = order
            }
        }
        return result
    }

    public func setFolderOrders(_ orders: [String: Int]) {
        try? db.transaction {
            try db.execute("delete from folder_order;")
            for (name, order) in orders {
                try db.execute(
                    "insert into folder_order (folder_name, order_value) values (?, ?);",
                    [.text(name), .int(order)]
                )
            }
        }
        onChange.emit(())
    }

    public func addFolder(_ name: String) {
        createFolderTable(name)
        onChange.emit(())
    }

    public func renameFolder(_ from: String, _ to: String) throws {
        guard from != to else { return }
        let fromEscaped = from.replacingOccurrences(of: "\"", with: "\"\"")
        let toEscaped = to.replacingOccurrences(of: "\"", with: "\"\"")
        try db.execute("alter table \"\(fromEscaped)\" rename to \"\(toEscaped)\";")
        try? db.execute("update folder_order set folder_name = ? where folder_name = ?;", [.text(to), .text(from)])
        try? db.execute("update folder_sync set folder_name = ? where folder_name = ?;", [.text(to), .text(from)])
        onChange.emit(())
    }

    public func deleteFolder(_ name: String) throws {
        // 删除前先取消覆盖该收藏夹的运行中追更检查，避免任务继续写已
        // 不存在的表。
        FollowUpdatesManager.shared.cancelChecks(forFolder: name)
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        try db.execute("drop table if exists \"\(escaped)\";")
        try? db.execute("delete from folder_order where folder_name = ?;", [.text(name)])
        try? db.execute("delete from folder_sync where folder_name = ?;", [.text(name)])
        onChange.emit(())
    }

    // MARK: - 条目 CRUD

    public func contains(id: String, type: Int, folder: String) -> Bool {
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        guard let row = try? db.selectFirst(
            "select 1 from \"\(escaped)\" where id = ? and type = ? limit 1;",
            [.text(id), .int(type)]
        ) else { return false }
        return row.count > 0
    }

    public func containsAnyFolder(id: String, type: Int) -> Bool {
        for folder in getFolders() {
            if contains(id: id, type: type, folder: folder) { return true }
        }
        return false
    }

    public func find(_ id: String, _ type: Int) -> [String] {
        getFoldersContaining(id: id, type: type)
    }

    public func getFoldersContaining(id: String, type: Int) -> [String] {
        getFolders().filter { contains(id: id, type: type, folder: $0) }
    }

    public func addFavorite(_ folder: String, _ item: FavoriteItem, addToStart: Bool = false) {
        createFolderTable(folder)
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        let tags = item.tags.joined(separator: ",")
        let authors = (try? JSON.array(item.authors.map { .string($0) }).encodedString()) ?? "[]"
        let extra = (try? JSON.object(item.extraMeta.mapValues { .string($0) }).encodedString()) ?? "{}"

        let order: Int
        if addToStart {
            let minOrder = (try? db.selectValue("select min(display_order) from \"\(escaped)\";"))?.intValue ?? 0
            order = minOrder - 1
        } else {
            let maxOrder = (try? db.selectValue("select max(display_order) from \"\(escaped)\";"))?.intValue ?? 0
            order = maxOrder + 1
        }

        var columns = ["id", "name", "author", "type", "tags", "cover_path", "time", "last_read",
                       "display_order", "authors", "comic_status", "update_time_meta", "extra_meta"]
        var values: [SQLiteValue] = [
            .text(item.id), .text(item.name), .text(item.author), .int(item.type),
            .text(tags), .text(item.coverPath), .text(item.time), .null,
            .int(order), .text(authors),
            item.status.map { .text($0) } ?? .null,
            item.updateTimeMeta.map { .text($0) } ?? .null,
            .text(extra),
        ]
        let existing = (try? db.tableColumns(escaped)) ?? []
        if existing.contains("last_update_time") {
            columns.append("last_update_time")
            values.append(item.lastUpdateTime.map { .text($0) } ?? .null)
        }
        if existing.contains("has_new_update") {
            columns.append("has_new_update")
            values.append(.int(item.hasNewUpdate == true ? 1 : 0))
        }
        if existing.contains("last_check_time") {
            columns.append("last_check_time")
            values.append(item.lastCheckTime.map { .int($0) } ?? .null)
        }
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        try? db.execute("insert or replace into \"\(escaped)\" (\(columns.joined(separator: ", "))) values (\(placeholders));", values)
        onChange.emit(())
    }

    @discardableResult
    public func removeFavorite(id: String, type: Int, folder: String) -> Bool {
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        do {
            try db.execute("delete from \"\(escaped)\" where id = ? and type = ?;", [.text(id), .int(type)])
        } catch {
            Log.error("Favorites", "Failed to remove favorite: \(error)")
        }
        onChange.emit(())
        return true
    }

    public func getComics(_ folder: String) -> [FavoriteItem] {
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        let rows = (try? db.select("""
        select * from "\(escaped)" order by display_order;
        """)) ?? []
        return rows.map(FavoriteItem.init)
    }

    public func count(_ folder: String) -> Int {
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        return (try? db.selectValue("select count(*) from \"\(escaped)\";"))?.intValue ?? 0
    }

    public func removeInvalid() -> Int {
        var count = 0
        for folder in getFolders() {
            for item in getComics(folder) {
                let sourceInstalled: Bool
                if item.type == 0 {
                    sourceInstalled = LocalManager.shared.find(id: item.id, type: item.type) != nil
                } else {
                    let sourceKey = SourcePlatformResolver.shared.resolve(item.type)
                    sourceInstalled = sourceKey != nil && ComicSourceManager.shared.find(sourceKey!) != nil
                }
                if !sourceInstalled {
                    _ = removeFavorite(id: item.id, type: item.type, folder: folder)
                    count += 1
                }
            }
        }
        return count
    }

    public func makeFollowFolder(_ name: String) {
        createFolderTable(name)
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        let existing = (try? db.tableColumns(escaped)) ?? []
        if !existing.contains("last_update_time") {
            db.executeRaw("alter table \"\(escaped)\" add column last_update_time text;")
        }
        if !existing.contains("has_new_update") {
            db.executeRaw("alter table \"\(escaped)\" add column has_new_update int;")
        }
        if !existing.contains("last_check_time") {
            db.executeRaw("alter table \"\(escaped)\" add column last_check_time int;")
        }
    }

    // MARK: - 追更更新

    public func updateUpdateTime(folder: String, id: String, type: Int, updateTime: String, hasNewUpdate: Bool) {
        makeFollowFolder(folder)
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try? db.execute("""
        update "\(escaped)" set last_update_time = ?, has_new_update = ?, last_check_time = ? where id = ? and type = ?;
        """, [.text(updateTime), .int(hasNewUpdate ? 1 : 0), .int(now), .text(id), .int(type)])
        onChange.emit(())
    }

    public func updateCheckTime(folder: String, id: String, type: Int) {
        makeFollowFolder(folder)
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try? db.execute("""
        update "\(escaped)" set last_check_time = ? where id = ? and type = ?;
        """, [.int(now), .text(id), .int(type)])
        onChange.emit(())
    }

    public func clearNewUpdateFlag(folder: String, id: String, type: Int) {
        makeFollowFolder(folder)
        let escaped = folder.replacingOccurrences(of: "\"", with: "\"\"")
        try? db.execute("""
        update "\(escaped)" set has_new_update = 0 where id = ? and type = ?;
        """, [.text(id), .int(type)])
        onChange.emit(())
    }

    // MARK: - folder_sync

    public func setFolderSync(folder: String, sourceKey: String, sourceFolder: String) {
        try? db.execute("""
        insert or replace into folder_sync (folder_name, source_key, source_folder) values (?, ?, ?);
        """, [.text(folder), .text(sourceKey), .text(sourceFolder)])
        onChange.emit(())
    }

    public func getFolderSync(folder: String) -> (sourceKey: String, sourceFolder: String)? {
        guard let row = try? db.selectFirst(
            "select source_key, source_folder from folder_sync where folder_name = ?;",
            [.text(folder)]
        ), let sourceKey = row["source_key"]?.textValue else { return nil }
        return (sourceKey, row["source_folder"]?.textValue ?? "")
    }
}
