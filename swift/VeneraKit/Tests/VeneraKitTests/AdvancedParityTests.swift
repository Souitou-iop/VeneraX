import XCTest
@testable import VeneraKit

/// 高阶功能对标测试：标签翻译、屏蔽过滤规则、跨源漫画迁移与首页区块编排。
final class AdvancedParityTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraAdvancedTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        HistoryManager.shared.ensureSchema()
        ReadLaterManager.shared.ensureSchema()
        LocalFavoritesManager.shared.ensureSchema()

        let sampleDict = """
        {
            "rows": {
                "female": "女性",
                "parody": "原作"
            },
            "female": {
                "sister": "姐妹",
                "mother": "母亲"
            },
            "other": {
                "full color": "全彩",
                "translated": "翻译"
            }
        }
        """
        TagTranslator.shared.loadRaw(cnJson: sampleDict)

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
        ComicSourceManager.shared.resetForTesting()
        runtime = nil
        AppPaths.overrideDataPath = nil
        if let dataPath = dataPath {
            try? FileManager.default.removeItem(atPath: dataPath)
        }
        super.tearDown()
    }

    /// 1. 标签翻译字典测试。
    func testTagTranslator() {
        // 标签翻译
        XCTAssertEqual("sister".translatedTag(namespace: "female"), "姐妹")
        XCTAssertEqual("full color".translatedTag(), "全彩")
        XCTAssertEqual("unknown_tag_xyz".translatedTag(), "unknown_tag_xyz")

        // 命名空间翻译
        XCTAssertEqual("female".translatedNamespace, "女性")
        XCTAssertEqual("parody".translatedNamespace, "原作")
    }

    /// 2. 屏蔽规则过滤器测试（关键字、标签、评论）。
    func testBlockListFilter() {
        // 设置屏蔽词与标签
        AppData.shared.settings["blockedWords"] = .array([.string("spoiler"), .string("forbidden")])
        AppData.shared.settings["blockedTags"] = .array([.string("gore"), .string("姐妹")])
        AppData.shared.settings["blockedCommentWords"] = .array([.string("badword"), .string("ad_link")])

        let normalComic = Comic(
            id: "c1",
            title: "Safe Adventure",
            cover: "https://img.com/1.jpg",
            subtitle: "A wholesome journey",
            tags: ["Action", "Fantasy"],
            sourceKey: "src1"
        )
        let blockedByWord = Comic(
            id: "c2",
            title: "Super Spoiler Ending",
            cover: "https://img.com/2.jpg",
            subtitle: "Author",
            tags: ["Action"],
            sourceKey: "src1"
        )
        let blockedByTag = Comic(
            id: "c3",
            title: "Sister Romance",
            cover: "https://img.com/3.jpg",
            subtitle: "Author",
            tags: ["sister"], // 翻译后为 "姐妹"，命中 blockedTags
            sourceKey: "src1"
        )

        XCTAssertFalse(BlockListFilter.isComicBlocked(normalComic))
        XCTAssertTrue(BlockListFilter.isComicBlocked(blockedByWord))
        XCTAssertTrue(BlockListFilter.isComicBlocked(blockedByTag))

        let filtered = BlockListFilter.filterComics([normalComic, blockedByWord, blockedByTag])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "c1")

        // 评论屏蔽测试
        let safeComment = Comment(userName: "User1", avatar: nil, content: "Great manga!", time: "2026-08-29", replyCount: nil, id: "m1", isLiked: false, score: nil, voteStatus: nil)
        let spamComment = Comment(userName: "Bot", avatar: nil, content: "Check this ad_link now", time: "2026-08-29", replyCount: nil, id: "m2", isLiked: false, score: nil, voteStatus: nil)

        XCTAssertFalse(BlockListFilter.isCommentBlocked(safeComment.content))
        XCTAssertTrue(BlockListFilter.isCommentBlocked(spamComment.content))

        let filteredComments = BlockListFilter.filterComments([safeComment, spamComment])
        XCTAssertEqual(filteredComments.count, 1)
        XCTAssertEqual(filteredComments.first?.id, "m1")
    }

    /// 3. 跨源漫画一键迁移测试。
    func testSourceMigrationEngine() async throws {
        let parser = ComicSourceParser()

        // 注册源 A 和源 B
        let scriptA = """
        class SourceAScript extends ComicSource {
            name = "Source A"
            key = "src_a"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://a.com"
        }
        """
        let scriptB = """
        class SourceBScript extends ComicSource {
            name = "Source B"
            key = "src_b"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://b.com"
            search = {
                load: async (keyword, page, options) => {
                    return {
                        comics: [
                            { id: "b_" + keyword, title: keyword, cover: "https://b.com/cover.jpg" }
                        ],
                        maxPage: 1
                    };
                }
            }
        }
        """

        try runtime.queue.sync {
            let srcA = try parser.parse(scriptA, filePath: "\(dataPath!)/a.js", runtime: runtime)
            let srcB = try parser.parse(scriptB, filePath: "\(dataPath!)/b.js", runtime: runtime)
            ComicSourceManager.shared.registerForTesting(srcA)
            ComicSourceManager.shared.registerForTesting(srcB)
        }

        let folder = "TestMigrationFolder"
        let itemA = FavoriteItem(
            id: "manga_001",
            name: "Frieren",
            coverPath: "https://a.com/cover.jpg",
            author: "Kanehito",
            type: ComicID.forSource("src_a"),
            tags: ["Fantasy"]
        )
        LocalFavoritesManager.shared.addFavorite(folder, itemA)

        // 添加阅读历史
        let historyA = History(
            id: "manga_001",
            type: ComicID.forSource("src_a"),
            title: "Frieren",
            subtitle: "Kanehito",
            cover: "https://a.com/cover.jpg",
            ep: 3,
            page: 15,
            time: Date(),
            maxPage: 20,
            readEpisode: ["1", "2", "3"],
            hideTime: nil
        )
        HistoryManager.shared.addHistory(historyA)

        // 执行跨源迁移
        SourceMigrationManager.shared.startMigration(
            folder: folder,
            sourceKey: "src_a",
            targetKey: "src_b",
            migrateHistory: true
        )

        // 等待异步任务完成
        try await Task.sleep(nanoseconds: 200_000_000)

        let targetType = ComicID.forSource("src_b")
        let updatedFavs = LocalFavoritesManager.shared.getComics(folder)
        XCTAssertEqual(updatedFavs.count, 1)
        XCTAssertEqual(updatedFavs.first?.id, "b_Frieren")
        XCTAssertEqual(updatedFavs.first?.type, targetType)

        // 验证历史迁移
        let migratedHistory = HistoryManager.shared.findHistory(id: "b_Frieren", type: targetType)
        XCTAssertNotNil(migratedHistory)
        XCTAssertEqual(migratedHistory?.ep, 3)
        XCTAssertEqual(migratedHistory?.page, 15)
    }

    /// 4. 追更任务摘要可持久化、进度有界且状态可区分。
    func testFollowUpdateTaskSnapshotRoundTrip() throws {
        let task = FollowUpdateTask(
            id: "follow-test",
            manual: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_120),
            status: .failed,
            total: 10,
            current: 10,
            updated: 3,
            errors: 2
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(FollowUpdateTask.self, from: data)
        XCTAssertEqual(decoded.id, task.id)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.total, 10)
        XCTAssertEqual(decoded.current, 10)
        XCTAssertEqual(decoded.updated, 3)
        XCTAssertEqual(decoded.errors, 2)
        XCTAssertEqual(decoded.progress, 1.0, accuracy: 0.0001)
    }

    /// 5. 源更新任务摘要保留逐源结果和失败信息。
    func testSourceUpdateTaskSnapshotRoundTrip() throws {
        let task = SourceUpdateTask(
            id: "source-update-test",
            status: .failed,
            total: 1,
            checked: 1,
            updated: 0,
            failed: 1,
            details: [SourceUpdateTaskDetail(
                sourceKey: "src",
                sourceName: "Source",
                oldVersion: "1.0.0",
                targetVersion: "1.1.0",
                status: "failed",
                error: "invalid script"
            )]
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(SourceUpdateTask.self, from: data)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.progress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.details.first?.targetVersion, "1.1.0")
        XCTAssertEqual(decoded.details.first?.error, "invalid script")
    }

    /// 6. 首页区块编排包含 Task Center。
    func testHomeLayoutSectionsContainTasks() {
        let sections = HomeLayoutStore.loadSections()
        XCTAssertTrue(sections.contains { $0.id == "tasks" })
    }
}
