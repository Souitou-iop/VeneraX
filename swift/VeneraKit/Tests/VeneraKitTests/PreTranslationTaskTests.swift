import XCTest
@testable import VeneraKit

/// 预翻译任务：模型语义（章节加权进度/失败页记账）与任务生命周期
/// （启动→页解析→逐页失败记账→完成→精确重试）。
final class PreTranslationTaskTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraPreTransTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        AppPaths.overrideCachePath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        runtime = JSRuntime()
        ComicSourceManager.shared.resetForTesting()
        let dispatcher = JSDispatcher()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.install(to: runtime)
        runtime.queue.sync {
            _ = try? runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
        }
    }

    override func tearDown() {
        PreTranslationTaskManager.shared.clearHistory()
        ComicSourceManager.shared.resetForTesting()
        runtime = nil
        AppPaths.overrideDataPath = nil
        AppPaths.overrideCachePath = nil
        if let dataPath = dataPath {
            try? FileManager.default.removeItem(atPath: dataPath)
        }
        super.tearDown()
    }

    // MARK: - 模型语义

    func testChapterWeightedProgressIgnoresUnresolvedTotals() {
        let task = PreTranslationTask(
            cid: "c1",
            sourceKey: "pretrans",
            title: "T",
            cover: "",
            chapters: [
                .init(epIndex: 0, eid: "e1", title: "Ch 1", total: 10, done: 5),
                .init(epIndex: 1, eid: "e2", title: "Ch 2", total: 0, done: 0),
                .init(epIndex: 2, eid: "e3", title: "Ch 3", total: 4, done: 4, failed: 0),
            ]
        )
        // 章节 1 完成（1.0），章节 2 未开始（0，total 未解析），
        // 章节 0 完成 50% → (0.5 + 0 + 1.0) / 3。
        XCTAssertEqual(task.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(task.total, 14)
        XCTAssertEqual(task.done, 9)
        XCTAssertFalse(task.hasFailures)
    }

    func testHasFailuresFollowsFailedPages() {
        // failedPages 是失败记账的真源（failed 始终等于其 count）。
        var chapter = PreTranslationTask.Chapter(
            epIndex: 0, eid: "e1", title: "Ch 1",
            total: 3, done: 1, failed: 2, failedPages: [1, 2]
        )
        let task = PreTranslationTask(cid: "c1", sourceKey: "pretrans", title: "T", cover: "", chapters: [chapter])
        XCTAssertTrue(task.hasFailures)

        // 失败页被重试成功后移除，failed 同步收缩。
        chapter.failedPages.removeAll { $0 == 1 }
        chapter.failed = chapter.failedPages.count
        XCTAssertEqual(chapter.failed, 1)

        chapter.failedPages.removeAll()
        chapter.failed = 0
        var cleared = task
        cleared.chapters[0] = chapter
        XCTAssertFalse(cleared.hasFailures)
    }

    // MARK: - 任务生命周期

    /// 页图片全部加载失败（无效 URL 本地快速失败，不触网）：
    /// 记账到 failedPages、任务完成、可精确重试。
    func testLifecycleRecordsFailedPagesAndRetriesExactlyThem() async throws {
        let script = """
        class PreTransSource extends ComicSource {
            name = "PreTrans"
            key = "pretrans"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://pretrans.example.com"
            comic = {
                loadEp: async (id, ep) => ({ images: ["not a url 1", "not a url 2", "not a url 3"] })
            }
            search = {
                load: async (keyword, page, options) => ({ comics: [], maxPage: 1 })
            }
        }
        """
        var source: ComicSource!
        try runtime.queue.sync {
            let parser = ComicSourceParser()
            source = try parser.parse(script, filePath: "\(dataPath!)/pretrans.js", runtime: runtime)
            ComicSourceManager.shared.registerForTesting(source)
        }

        let chapters = ComicChapters(flatEntries: [
            .init(id: "e1", title: "Chapter 1"),
            .init(id: "e2", title: "Chapter 2"),
        ])
        let comic = Comic(id: "pretrans-comic", title: "PreTrans Comic", cover: "", subtitle: "", sourceKey: "pretrans")

        let task = try XCTUnwrap(PreTranslationTaskManager.shared.start(
            comic: comic,
            source: source,
            chapters: chapters,
            epIndices: [0, 1]
        ))
        XCTAssertEqual(task.chapters.map(\.eid), ["e1", "e2"])

        var finished = task
        for _ in 0..<200 {
            if let current = PreTranslationTaskManager.shared.allTasks().first(where: { $0.id == task.id }) {
                finished = current
                if !current.isRunning { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(finished.status, .failed)
        XCTAssertTrue(finished.hasFailures)
        XCTAssertEqual(finished.chapters.count, 2)
        for chapter in finished.chapters {
            XCTAssertEqual(chapter.total, 3)
            XCTAssertEqual(chapter.done, 0)
            XCTAssertEqual(chapter.failed, 3)
            XCTAssertEqual(chapter.failedPages, [0, 1, 2])
        }

        // 精确重试：重新走同一批失败页（结果仍失败，但流程完整走通）。
        XCTAssertTrue(PreTranslationTaskManager.shared.retryFailed(id: task.id))
        var retried = finished
        for _ in 0..<200 {
            if let current = PreTranslationTaskManager.shared.allTasks().first(where: { $0.id == task.id }) {
                retried = current
                if !current.isRunning { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(retried.status, .failed)
        XCTAssertEqual(retried.done, 0)
        for chapter in retried.chapters {
            XCTAssertEqual(chapter.failed, 3)
        }

        // 无失败页时不可重试；无效章节索引被过滤。
        XCTAssertFalse(PreTranslationTaskManager.shared.retryFailed(id: task.id + "-nonexistent"))
        XCTAssertNil(PreTranslationTaskManager.shared.start(comic: comic, source: source, chapters: chapters, epIndices: [99]))
        XCTAssertNil(PreTranslationTaskManager.shared.start(comic: comic, source: source, chapters: chapters, epIndices: []))
    }

    /// A page-list failure is retried as the whole resolved chapter, not as a
    /// synthetic failure of page zero.
    func testPageListFailureRetryProcessesEveryResolvedPage() async throws {
        let script = """
        var pageListAttempts = 0
        class ResolveRetrySource extends ComicSource {
            name = "ResolveRetry"
            key = "resolve_retry"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://resolve-retry.example.com"
            comic = {
                loadEp: async (id, ep) => {
                    pageListAttempts++
                    return pageListAttempts === 1
                        ? { images: [] }
                        : { images: ["not a url 1", "not a url 2", "not a url 3"] }
                }
            }
            search = {
                load: async (keyword, page, options) => ({ comics: [], maxPage: 1 })
            }
        }
        """
        var source: ComicSource!
        try runtime.queue.sync {
            let parser = ComicSourceParser()
            source = try parser.parse(script, filePath: "\(dataPath!)/resolve-retry.js", runtime: runtime)
            ComicSourceManager.shared.registerForTesting(source)
        }

        let chapters = ComicChapters(flatEntries: [.init(id: "e1", title: "Chapter 1")])
        let comic = Comic(id: "resolve-retry-comic", title: "Resolve Retry", cover: "", subtitle: "", sourceKey: "resolve_retry")
        let task = try XCTUnwrap(PreTranslationTaskManager.shared.start(
            comic: comic, source: source, chapters: chapters, epIndices: [0]
        ))

        var firstRun = task
        for _ in 0..<200 {
            if let current = PreTranslationTaskManager.shared.allTasks().first(where: { $0.id == task.id }) {
                firstRun = current
                if !current.isRunning { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(firstRun.status, .failed)
        XCTAssertTrue(firstRun.chapters[0].hasPageListFailure)
        XCTAssertEqual(firstRun.chapters[0].total, 0)
        XCTAssertTrue(firstRun.chapters[0].failedPages.isEmpty)

        XCTAssertTrue(PreTranslationTaskManager.shared.retryFailed(id: task.id))
        var retried = firstRun
        for _ in 0..<200 {
            if let current = PreTranslationTaskManager.shared.allTasks().first(where: { $0.id == task.id }) {
                retried = current
                if !current.isRunning { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(retried.status, .failed)
        XCTAssertFalse(retried.chapters[0].hasPageListFailure)
        XCTAssertEqual(retried.chapters[0].total, 3)
        XCTAssertEqual(retried.chapters[0].failedPages, [0, 1, 2])
    }

    func testPersistedActiveStatusesSurviveManagerReload() throws {
        let key = "venera.preTranslationTasks.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let running = PreTranslationTask(
            cid: "running", sourceKey: "source", title: "Running", cover: "",
            chapters: [.init(epIndex: 0, eid: "e1", title: "One", total: 10, done: 4)]
        )
        var paused = PreTranslationTask(
            cid: "paused", sourceKey: "source", title: "Paused", cover: "",
            chapters: [.init(epIndex: 0, eid: "e2", title: "Two", total: 8, done: 3)]
        )
        paused.status = .paused
        let data = try JSONEncoder().encode([running, paused])
        UserDefaults.standard.set(data, forKey: key)

        let restored = PreTranslationTaskManager(persistenceKey: key).allTasks()
        XCTAssertEqual(restored.map(\.status), [.running, .paused])
        XCTAssertEqual(restored[0].chapters[0].done, 4)
        XCTAssertEqual(restored[1].chapters[0].done, 3)
    }

    func testResumePendingTaskContinuesAfterCommittedPrefix() async throws {
        let script = """
        class ResumeSource extends ComicSource {
            name = "Resume"
            key = "resume_source"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://resume.example.com"
            comic = {
                loadEp: async (id, ep) => ({ images: ["not a url 0", "not a url 1", "not a url 2"] })
            }
            search = {
                load: async (keyword, page, options) => ({ comics: [], maxPage: 1 })
            }
        }
        """
        var source: ComicSource!
        try runtime.queue.sync {
            let parser = ComicSourceParser()
            source = try parser.parse(script, filePath: "\(dataPath!)/resume.js", runtime: runtime)
            ComicSourceManager.shared.registerForTesting(source)
        }

        let key = "venera.preTranslationTasks.resume.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let persisted = PreTranslationTask(
            cid: "resume-comic", sourceKey: "resume_source", title: "Resume", cover: "",
            chapters: [.init(epIndex: 0, eid: "e1", title: "One", total: 3, done: 1)]
        )
        UserDefaults.standard.set(try JSONEncoder().encode([persisted]), forKey: key)
        let manager = PreTranslationTaskManager(persistenceKey: key)
        manager.resumePendingTasks()

        var resumed = persisted
        for _ in 0..<200 {
            if let current = manager.allTasks().first {
                resumed = current
                if !current.isRunning { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(resumed.chapters[0].done, 1)
        XCTAssertEqual(resumed.chapters[0].failed, 2)
        XCTAssertEqual(resumed.chapters[0].failedPages, [1, 2])
    }

    /// 启动校验：重复索引去重保序。
    func testStartDeduplicatesEpisodeIndices() async throws {
        let script = """
        class DedupSource extends ComicSource {
            name = "Dedup"
            key = "dedup"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://dedup.example.com"
            comic = {
                loadEp: async (id, ep) => ({ images: [] })
            }
            search = {
                load: async (keyword, page, options) => ({ comics: [], maxPage: 1 })
            }
        }
        """
        var source: ComicSource!
        try runtime.queue.sync {
            let parser = ComicSourceParser()
            source = try parser.parse(script, filePath: "\(dataPath!)/dedup.js", runtime: runtime)
            ComicSourceManager.shared.registerForTesting(source)
        }
        let chapters = ComicChapters(flatEntries: [
            .init(id: "a", title: "A"),
            .init(id: "b", title: "B"),
        ])
        let comic = Comic(id: "dedup-comic", title: "D", cover: "", subtitle: "", sourceKey: "dedup")

        let task = try XCTUnwrap(PreTranslationTaskManager.shared.start(
            comic: comic,
            source: source,
            chapters: chapters,
            epIndices: [1, 0, 1]
        ))
        XCTAssertEqual(task.chapters.map(\.epIndex), [1, 0])
        // 等待任务结束（loadEp 返回空列表 → 占位失败）。
        for _ in 0..<200 {
            if let current = PreTranslationTaskManager.shared.allTasks().first(where: { $0.id == task.id }), !current.isRunning {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
