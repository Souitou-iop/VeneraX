import XCTest
@testable import VeneraKit

final class FeatureEnhancementTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "VeneraFeatureTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        AppPaths.overrideDataPath = tempDir
        AppPaths.overrideCachePath = tempDir
        LocalManager.shared.ensureSchema()
        LocalFavoritesManager.shared.ensureSchema()
        HistoryManager.shared.ensureSchema()
    }

    override func tearDown() {
        HistoryManager.shared.clearHistory()
        HistoryManager.shared.clearReadingStatistics()
        try? FileManager.default.removeItem(atPath: tempDir)
        AppPaths.overrideDataPath = nil
        AppPaths.overrideCachePath = nil
        super.tearDown()
    }

    func testReadingStatisticsSummary() {
        let manager = HistoryManager.shared
        manager.clearReadingStatistics()

        // 写入 3 段阅读时长（总计 120 秒 = 2 分钟）
        manager.addReadingTime(
            id: "manga_1",
            type: 10,
            title: "Manga 1",
            subtitle: "Author 1",
            cover: "cover1.jpg",
            durationMs: 60_000
        )
        manager.addReadingTime(
            id: "manga_1",
            type: 10,
            title: "Manga 1",
            subtitle: "Author 1",
            cover: "cover1.jpg",
            durationMs: 30_000
        )
        manager.addReadingTime(
            id: "manga_2",
            type: 10,
            title: "Manga 2",
            subtitle: "Author 2",
            cover: "cover2.jpg",
            durationMs: 30_000
        )

        let summary = manager.getReadingStatisticsSummary()
        XCTAssertEqual(summary.today, 120)
        XCTAssertEqual(summary.lastSevenDays, 120)
        XCTAssertEqual(summary.total, 120)
        XCTAssertEqual(summary.daily.count, 7)
        XCTAssertEqual(summary.recentComics.count, 2)

        let comic1 = summary.recentComics.first(where: { $0.comicId == "manga_1" })
        XCTAssertNotNil(comic1)
        XCTAssertEqual(comic1?.duration, 90)

        let comic2 = summary.recentComics.first(where: { $0.comicId == "manga_2" })
        XCTAssertNotNil(comic2)
        XCTAssertEqual(comic2?.duration, 30)

        // 清除统计
        manager.clearReadingStatistics()
        let cleared = manager.getReadingStatisticsSummary()
        XCTAssertEqual(cleared.total, 0)
        XCTAssertEqual(cleared.recentComics.count, 0)
    }

    func testFollowUpdatesFlagging() {
        let favorites = LocalFavoritesManager.shared
        let folder = "FollowTestFolder"
        favorites.addFolder(folder)
        favorites.makeFollowFolder(folder)

        let item = FavoriteItem(
            id: "comic_up_1",
            name: "Update Manga",
            coverPath: "c.jpg",
            author: "A",
            type: 10,
            tags: ["Shonen"]
        )
        favorites.addFavorite(folder, item)

        XCTAssertEqual(FollowUpdatesManager.shared.totalUpdatedCount, 0)

        // 标记更新
        favorites.updateUpdateTime(
            folder: folder,
            id: "comic_up_1",
            type: 10,
            updateTime: "2026-08-29 20:00:00",
            hasNewUpdate: true
        )

        XCTAssertEqual(FollowUpdatesManager.shared.totalUpdatedCount, 1)
        let allUpdated = FollowUpdatesManager.shared.getAllUpdatedComics()
        XCTAssertEqual(allUpdated.count, 1)
        XCTAssertEqual(allUpdated.first?.item.name, "Update Manga")
        XCTAssertEqual(allUpdated.first?.item.hasNewUpdate, true)

        // 标记已读
        FollowUpdatesManager.shared.markComicRead(id: "comic_up_1", type: 10, folder: folder)
        XCTAssertEqual(FollowUpdatesManager.shared.totalUpdatedCount, 0)
    }

    func testCloudflareChallengeDetection() {
        // 403 with challenge header
        XCTAssertTrue(CloudflareSolver.isChallengeResponse(
            status: 403,
            headers: ["cf-mitigated": "challenge"],
            body: Data("<html></html>".utf8)
        ))

        // 503 with Just a moment text in body
        XCTAssertTrue(CloudflareSolver.isChallengeResponse(
            status: 503,
            headers: [:],
            body: Data("<html><title>Just a moment...</title></html>".utf8)
        ))

        // 200 normal response
        XCTAssertFalse(CloudflareSolver.isChallengeResponse(
            status: 200,
            headers: [:],
            body: Data("<html><body>Normal Page</body></html>".utf8)
        ))

        // 404 normal error
        XCTAssertFalse(CloudflareSolver.isChallengeResponse(
            status: 404,
            headers: [:],
            body: Data("<html><body>Not Found</body></html>".utf8)
        ))
    }
}
