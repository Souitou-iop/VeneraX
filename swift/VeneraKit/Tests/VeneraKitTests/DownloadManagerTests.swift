import XCTest
@testable import VeneraKit

final class DownloadManagerTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "VeneraDLTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        AppPaths.overrideDataPath = tempDir
        AppPaths.overrideCachePath = tempDir
        LocalManager.shared.ensureSchema()
        LocalManager.shared.ensureDirectory()
    }

    override func tearDown() {
        DownloadManager.shared.cancelAll()
        LocalManager.shared.batchDeleteComics(LocalManager.shared.getComics(), removeFiles: false, removeFavoriteAndHistory: false)
        try? FileManager.default.removeItem(atPath: tempDir)
        AppPaths.overrideDataPath = nil
        AppPaths.overrideCachePath = nil
        super.tearDown()
    }

    func testDownloadTaskSerializationRoundTrip() {
        let details = ComicDetails(
            id: "komiic_123",
            title: "Task Comic",
            subtitle: "Author",
            cover: "https://example.com/cover.jpg",
            description: "Desc",
            tags: ["Genre": ["Shonen"]],
            chapters: ComicChapters(flatEntries: [ComicChapters.Entry(id: "ep1", title: "Ep 1")]),
            sourceKey: "komiic"
        )
        let task = ImagesDownloadTask(
            sourceKey: "komiic",
            comicId: "komiic_123",
            comic: details,
            chapters: ["ep1"],
            comicTitle: "Task Comic",
            comicCover: "https://example.com/cover.jpg"
        )
        task.path = "/tmp/comics/task_comic"
        task.downloadedCount = 5
        task.totalCount = 10
        task.wasRunning = true
        task.userPaused = false

        let json = task.toJson()
        guard let restored = DownloadTask.fromJson(json) as? ImagesDownloadTask else {
            XCTFail("Failed to restore ImagesDownloadTask")
            return
        }

        XCTAssertEqual(restored.sourceKey, "komiic")
        XCTAssertEqual(restored.id, "komiic_123")
        XCTAssertEqual(restored.title, "Task Comic")
        XCTAssertEqual(restored.downloadedCount, 5)
        XCTAssertEqual(restored.totalCount, 10)
        XCTAssertEqual(restored.chapters, ["ep1"])
        XCTAssertTrue(restored.wasRunning)
        XCTAssertFalse(restored.userPaused)
    }

    func testDownloadManagerQueueControls() {
        let manager = DownloadManager.shared
        manager.cancelAll()
        XCTAssertEqual(manager.downloadingTasks.count, 0)

        let task1 = ImagesDownloadTask(sourceKey: "komiic", comicId: "c1", comicTitle: "Comic 1")
        let task2 = ImagesDownloadTask(sourceKey: "komiic", comicId: "c2", comicTitle: "Comic 2")
        let task3 = ImagesDownloadTask(sourceKey: "komiic", comicId: "c3", comicTitle: "Comic 3")

        manager.addTask(task1)
        manager.addTask(task2)
        manager.addTask(task3)

        XCTAssertEqual(manager.downloadingTasks.count, 3)
        XCTAssertTrue(manager.isDownloading(id: "c1", type: ComicID.forSource("komiic")))
        XCTAssertTrue(manager.isDownloading(id: "c2", type: ComicID.forSource("komiic")))

        // Move to first
        manager.moveToFirst(task3)
        XCTAssertEqual(manager.downloadingTasks.first?.id, "c3")

        // Reorder
        manager.reorderTask(from: 0, to: 2)
        XCTAssertEqual(manager.downloadingTasks[2].id, "c3")

        // Pause / Resume single
        manager.pauseTask(task1)
        XCTAssertTrue(task1.userPaused)

        manager.resumeTask(task1)
        XCTAssertFalse(task1.userPaused)

        // Pause all / Resume all
        manager.pauseAll()
        XCTAssertTrue(manager.downloadingTasks.allSatisfy { $0.userPaused })

        manager.resumeAll()
        XCTAssertTrue(manager.downloadingTasks.allSatisfy { !$0.userPaused })

        // Task completion
        task1.path = AppPaths.join(LocalManager.shared.path, "c1")
        try? FileManager.default.createDirectory(atPath: task1.path!, withIntermediateDirectories: true)
        manager.completeTask(task1)

        XCTAssertFalse(manager.isDownloading(id: "c1", type: ComicID.forSource("komiic")))
        XCTAssertNotNil(LocalManager.shared.find(id: "c1", type: ComicID.forSource("komiic")))
        XCTAssertEqual(manager.downloadingTasks.count, 2)
    }
    func testQueueOutcomeDoesNotDependOnProgress() {
        let manager = DownloadManager()
        let task = ActivityTestDownload(id: "fast-success", comicType: 0)
        manager.addTask(task)
        task.progress = 0.05 // Simulates the last snapshot before a fast completion.
        manager.completeTask(task)
        XCTAssertEqual(manager.activitySnapshot().result, .completed)
        XCTAssertTrue(manager.activitySnapshot().tasks.isEmpty)
        manager.completeTask(task) // duplicate completion is harmless
        XCTAssertEqual(manager.activitySnapshot().result, .completed)
    }

    func testCancellationAtOneHundredPercentRemainsCancelled() {
        let manager = DownloadManager()
        let task = ActivityTestDownload(id: "cancel-at-100", comicType: 0)
        manager.addTask(task)
        task.progress = 1
        manager.cancelAll()
        XCTAssertEqual(manager.activitySnapshot().result, .cancelled)
        manager.completeTask(task) // late network completion must not resurrect it
        XCTAssertEqual(manager.activitySnapshot().result, .cancelled)
        XCTAssertNil(LocalManager.shared.find(id: task.id, type: 0))
    }

    func testMixedQueueOutcomeAndNewQueueReset() {
        let manager = DownloadManager()
        let first = ActivityTestDownload(id: "mixed-complete", comicType: 0)
        let second = ActivityTestDownload(id: "mixed-cancel", comicType: 0)
        manager.addTask(first)
        manager.addTask(second)
        let oldID = manager.activitySnapshot().id
        manager.removeTask(second)
        XCTAssertNil(manager.activitySnapshot().result)
        manager.completeTask(first)
        XCTAssertEqual(manager.activitySnapshot().result, .partiallyCancelled)
        manager.cancelAll() // cancelling an already empty queue does not change history
        XCTAssertEqual(manager.activitySnapshot().result, .partiallyCancelled)
        let next = ActivityTestDownload(id: "new-queue", comicType: 0)
        manager.addTask(next)
        XCTAssertNotEqual(manager.activitySnapshot().id, oldID)
        XCTAssertNil(manager.activitySnapshot().result)
        manager.completeTask(next)
        XCTAssertEqual(manager.activitySnapshot().result, .completed)
    }

}

private final class ActivityTestDownload: DownloadTask, @unchecked Sendable {
    override func toLocalComic() -> LocalComic {
        LocalComic(id: id, title: id, subtitle: "", tags: [], directory: id,
                   chapters: nil, cover: "", comicType: comicType, downloadedChapters: [])
    }
    override func toJson() -> JSON { .object([:]) }
}
