import Foundation

// MARK: - 模型定义

/// 历史记录条目（history 表）。列与原版 History.fromMap 一致：
/// type 为 ComicType.value（int）；readEpisode 为 JSON 数组文本；
/// hide_time 为隐藏时间戳（null 为可见）。
public struct History: Hashable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type: Int
    public var title: String
    public var subtitle: String
    public var cover: String
    public var ep: Int
    public var page: Int
    public var time: Date
    public var maxPage: Int?
    public var readEpisode: Set<String>
    public var hideTime: String?

    public var uid: String { "\(type):\(id)" }

    public init(
        id: String,
        type: Int,
        title: String,
        subtitle: String = "",
        cover: String = "",
        ep: Int = 0,
        page: Int = 0,
        time: Date = Date(),
        maxPage: Int? = nil,
        readEpisode: Set<String> = [],
        hideTime: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.ep = ep
        self.page = page
        self.time = time
        self.maxPage = maxPage
        self.readEpisode = readEpisode
        self.hideTime = hideTime
    }

    init(row: [String: SQLiteValue]) {
        id = row["target"]?.textValue ?? ""
        type = row["type"]?.intValue ?? 0
        title = row["title"]?.textValue ?? ""
        subtitle = row["subtitle"]?.textValue ?? ""
        cover = row["cover"]?.textValue ?? ""
        ep = row["ep"]?.intValue ?? 0
        page = row["page"]?.intValue ?? 0
        maxPage = row["max_page"]?.intValue
        hideTime = row["hide_time"]?.textValue

        let timeText = row["time"]?.textValue ?? ""
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        time = formatter.date(from: timeText) ?? Date(timeIntervalSince1970: 0)

        var parsedEpisodes: Set<String> = []
        if let episodesText = row["read_episode"]?.textValue,
           let json = JSON.decode(episodesText),
           case .array(let list) = json
        {
            for item in list {
                if let str = item.stringValue {
                    parsedEpisodes.insert(str)
                } else if let num = item.intValue {
                    parsedEpisodes.insert(String(num))
                }
            }
        }
        readEpisode = parsedEpisodes
    }

    /// 原版 SQLite time 列格式："yyyy-MM-dd HH:mm:ss"。
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: time)
    }

    var readEpisodesJSONString: String {
        let list = readEpisode.sorted().map { JSON.string($0) }
        return (try? JSON.array(list).encodedString()) ?? "[]"
    }
}

/// 阅读时长统计条目（reading_statistics 表）。
public struct ReadingStatisticEntry: Equatable, Sendable {
    public var day: Int
    public var id: String
    public var type: Int
    public var title: String
    public var subtitle: String
    public var cover: String
    public var durationMs: Int
    public var lastReadTime: Date

    init(row: [String: SQLiteValue]) {
        day = row["day"]?.intValue ?? 0
        id = row["id"]?.textValue ?? ""
        type = row["type"]?.intValue ?? 0
        title = row["title"]?.textValue ?? ""
        subtitle = row["subtitle"]?.textValue ?? ""
        cover = row["cover"]?.textValue ?? ""
        durationMs = row["duration_ms"]?.intValue ?? 0
        let ms = row["last_read_time"]?.int64Value ?? 0
        lastReadTime = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    }
}

// MARK: - 历史管理器

/// 历史管理器（history.db：history + reading_statistics + image_favorites
/// 兼容表结构）。支持记录去重、按天阅读时长累加、清空与迁移还原。
public final class HistoryManager: @unchecked Sendable {
    public static let shared = HistoryManager()

    public let onChange = CallbackRegistry<Void>()

    public let customDataPath: String?

    private var dbPath: String {
        AppPaths.join(customDataPath ?? AppPaths.dataPath, "history.db")
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
        create table if not exists history (
            target text not null,
            type int not null,
            title text not null,
            subtitle text not null,
            cover text not null,
            ep int not null,
            page int not null,
            time text not null,
            read_episode text not null,
            max_page int,
            hide_time text,
            primary key (target, type)
        );
        """)
        let columns = (try? db.tableColumns("history")) ?? []
        if !columns.contains("hide_time") {
            db.executeRaw("alter table history add column hide_time text;")
        }
        db.executeRaw("CREATE INDEX IF NOT EXISTS history_time_idx ON history (time desc);")

        db.executeRaw("""
        create table if not exists reading_statistics (
            day int not null,
            id text not null,
            type int not null,
            title text not null,
            subtitle text not null,
            cover text not null,
            duration_ms int not null default 0,
            last_read_time int not null,
            primary key (day, id, type)
        );
        """)
        db.executeRaw("CREATE INDEX IF NOT EXISTS reading_statistics_last_read_idx ON reading_statistics (last_read_time desc);")
    }

    // MARK: - 历史记录 CRUD

    public func addHistory(_ history: History) {
        try? db.execute("""
        insert or replace into history (target, type, title, subtitle, cover, ep, page, time, read_episode, max_page, hide_time)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null);
        """, [
            .text(history.id),
            .int(history.type),
            .text(history.title),
            .text(history.subtitle),
            .text(history.cover),
            .int(history.ep),
            .int(history.page),
            .text(history.timeString),
            .text(history.readEpisodesJSONString),
            history.maxPage.map { .int($0) } ?? .null,
        ])
        onChange.emit(())
        AppData.shared.saveData(sync: true)
    }

    public func findHistory(id: String, type: Int) -> History? {
        guard let row = try? db.selectFirst(
            "select * from history where target = ? and type = ?;",
            [.text(id), .int(type)]
        ) else { return nil }
        return History(row: row)
    }

    public func containsHistory(id: String, type: Int) -> Bool {
        guard let row = try? db.selectFirst(
            "select 1 from history where target = ? and type = ? and hide_time is null limit 1;",
            [.text(id), .int(type)]
        ) else { return false }
        return row.count > 0
    }

    public func removeFromHistory(id: String, type: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let now = formatter.string(from: Date())
        try? db.execute("update history set hide_time = ? where target = ? and type = ?;", [.text(now), .text(id), .int(type)])
        onChange.emit(())
        AppData.shared.saveData(sync: true)
    }

    public func clearHistory() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let now = formatter.string(from: Date())
        try? db.execute("update history set hide_time = ?;", [.text(now)])
        onChange.emit(())
        AppData.shared.saveData(sync: true)
    }

    public func getAll() -> [History] { getRecent(Int.max) }
    public func getRecent(_ limit: Int = 100) -> [History] {
        let rows = (try? db.select("select * from history where hide_time is null order by time desc limit ?;", [.int(limit)])) ?? []
        return rows.map(History.init)
    }

    @discardableResult
    public func cleanHistoryOlderThan(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let cutoffString = formatter.string(from: cutoff)
        let beforeCount = count()
        try? db.execute("delete from history where time < ?;", [.text(cutoffString)])
        let removed = beforeCount - count()
        if removed > 0 {
            onChange.emit(())
        }
        return removed
    }

    public func count() -> Int {
        (try? db.selectValue("select count(*) from history where hide_time is null;"))?.intValue ?? 0
    }

    // MARK: - 阅读时长统计

    public func addReadingTime(
        id: String,
        type: Int,
        title: String,
        subtitle: String,
        cover: String,
        durationMs: Int
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let day = Int(formatter.string(from: Date())) ?? 0
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? db.execute("""
        insert into reading_statistics (day, id, type, title, subtitle, cover, duration_ms, last_read_time)
        values (?, ?, ?, ?, ?, ?, ?, ?)
        on conflict(day, id, type) do update set
          duration_ms = duration_ms + excluded.duration_ms,
          last_read_time = excluded.last_read_time,
          title = excluded.title,
          subtitle = excluded.subtitle,
          cover = excluded.cover;
        """, [
            .int(day), .text(id), .int(type), .text(title), .text(subtitle), .text(cover),
            .int(durationMs), .int(Int(now)),
        ])
        onChange.emit(())
    }

    public func getReadingStatistics() -> [ReadingStatisticEntry] {
        let rows = (try? db.select("select * from reading_statistics order by last_read_time desc;")) ?? []
        return rows.map(ReadingStatisticEntry.init)
    }

    public func getReadingStatisticsSummary(now: Date = Date()) -> ReadingStatisticsSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let todayKey = Int(formatter.string(from: today)) ?? 0
        let sevenDaysKey = Int(formatter.string(from: sevenDaysAgo)) ?? 0
        let thirtyDaysKey = Int(formatter.string(from: thirtyDaysAgo)) ?? 0

        // 1. 每日 7 天趋势
        var dailyDict: [Int: TimeInterval] = [:]
        let dailyRows = (try? db.select(
            "select day, sum(duration_ms) as total_ms from reading_statistics where day >= ? group by day;",
            [.int(sevenDaysKey)]
        )) ?? []
        for r in dailyRows {
            if let d = r["day"]?.intValue, let ms = r["total_ms"]?.int64Value {
                dailyDict[d] = Double(ms) / 1000.0
            }
        }

        var dailyList: [DailyReadingDuration] = []
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MM-dd"
        for i in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: i, to: sevenDaysAgo) {
                let dKey = Int(formatter.string(from: date)) ?? 0
                let label = dayFormatter.string(from: date)
                let dur = dailyDict[dKey] ?? 0
                dailyList.append(DailyReadingDuration(dayKey: label, day: date, duration: dur))
            }
        }

        // 2. 近 30 天漫画列表汇总
        var recentDict: [String: ComicReadingStatistics] = [:]
        let recentRows = (try? db.select("""
        select id, type, title, subtitle, cover, duration_ms, last_read_time
        from reading_statistics
        where day >= ?
        order by last_read_time desc;
        """, [.int(thirtyDaysKey)])) ?? []

        for r in recentRows {
            let id = r["id"]?.textValue ?? ""
            let type = r["type"]?.intValue ?? 0
            let title = r["title"]?.textValue ?? ""
            let subtitle = r["subtitle"]?.textValue ?? ""
            let cover = r["cover"]?.textValue ?? ""
            let dur = Double(r["duration_ms"]?.int64Value ?? 0) / 1000.0
            let lastMs = r["last_read_time"]?.int64Value ?? 0
            let lastReadAt = Date(timeIntervalSince1970: TimeInterval(lastMs) / 1000.0)

            let key = "\(type):\(id)"
            if var existing = recentDict[key] {
                existing.duration += dur
                recentDict[key] = existing
            } else {
                recentDict[key] = ComicReadingStatistics(
                    comicId: id,
                    type: type,
                    title: title,
                    subtitle: subtitle,
                    cover: cover,
                    duration: dur,
                    lastReadAt: lastReadAt
                )
            }
        }

        // 3. 统计汇总
        let todayVal = (try? db.selectValue("select sum(duration_ms) from reading_statistics where day = ?;", [.int(todayKey)]))?.int64Value ?? 0
        let sevenDayVal = (try? db.selectValue("select sum(duration_ms) from reading_statistics where day >= ?;", [.int(sevenDaysKey)]))?.int64Value ?? 0
        let totalVal = (try? db.selectValue("select sum(duration_ms) from reading_statistics;"))?.int64Value ?? 0

        return ReadingStatisticsSummary(
            today: Double(todayVal) / 1000.0,
            lastSevenDays: Double(sevenDayVal) / 1000.0,
            total: Double(totalVal) / 1000.0,
            daily: dailyList,
            recentComics: Array(recentDict.values).sorted(by: { $0.lastReadAt > $1.lastReadAt })
        )
    }

    public func clearReadingStatistics() {
        try? db.execute("delete from reading_statistics;")
        onChange.emit(())
    }

    // MARK: - 恢复

    public func restoreFrom(_ sourcePath: String) throws {
        let path = AppPaths.join(AppPaths.dataPath, "history.db")
        try DatabaseGateway.shared.restoreDatabaseFiles([path: sourcePath])
    }
}
