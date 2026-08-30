import Foundation

public struct DailyReadingDuration: Identifiable, Sendable {
    public var id: String { dayKey }
    public let dayKey: String
    public let day: Date
    public let duration: TimeInterval

    public init(dayKey: String, day: Date, duration: TimeInterval) {
        self.dayKey = dayKey
        self.day = day
        self.duration = duration
    }
}

public struct ComicReadingStatistics: Identifiable, Sendable {
    public var id: String { "\(type):\(comicId)" }
    public let comicId: String
    public let type: Int
    public let title: String
    public let subtitle: String
    public let cover: String
    public var duration: TimeInterval
    public let lastReadAt: Date

    public init(
        comicId: String,
        type: Int,
        title: String,
        subtitle: String,
        cover: String,
        duration: TimeInterval,
        lastReadAt: Date
    ) {
        self.comicId = comicId
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.duration = duration
        self.lastReadAt = lastReadAt
    }

    public var sourceKey: String {
        ComicID(id: comicId, type: type).sourceKey ?? "local"
    }

    public func toComic() -> Comic {
        Comic(
            id: comicId,
            title: title,
            cover: cover,
            subtitle: subtitle,
            sourceKey: sourceKey
        )
    }
}

public struct ReadingStatisticsSummary: Sendable {
    public let today: TimeInterval
    public let lastSevenDays: TimeInterval
    public let total: TimeInterval
    public let daily: [DailyReadingDuration]
    public let recentComics: [ComicReadingStatistics]

    public init(
        today: TimeInterval = 0,
        lastSevenDays: TimeInterval = 0,
        total: TimeInterval = 0,
        daily: [DailyReadingDuration] = [],
        recentComics: [ComicReadingStatistics] = []
    ) {
        self.today = today
        self.lastSevenDays = lastSevenDays
        self.total = total
        self.daily = daily
        self.recentComics = recentComics
    }
}
