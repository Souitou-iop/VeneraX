import XCTest
@testable import VeneraKit

final class MoreFeaturesTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "VeneraMoreTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        AppPaths.overrideDataPath = tempDir
        AppPaths.overrideCachePath = tempDir
        AppData.shared.load()
        HistoryManager.shared.ensureSchema()
        ImageFavoriteManager.shared.ensureSchema()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        AppPaths.overrideDataPath = nil
        AppPaths.overrideCachePath = nil
        super.tearDown()
    }

    func testComicCollectionStore() {
        let store = ComicCollectionStore.shared

        let m1 = CollectionMember(sourceKey: "komiic", comicId: "c1", displayName: "Part 1", cachedTitle: "Title 1")
        let m2 = CollectionMember(sourceKey: "komiic", comicId: "c2", displayName: "Part 2", cachedTitle: "Title 2")

        let col = store.create(name: "My Great Series", members: [m1, m2], displayMode: .tabs)
        XCTAssertEqual(col.name, "My Great Series")
        XCTAssertEqual(col.members.count, 2)
        XCTAssertEqual(col.displayMode, .tabs)
        XCTAssertTrue(ComicCollectionStore.isCollectionSourceKey(col.sourceKey))

        // Find
        let found = store.find(id: col.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.displayName, "My Great Series")

        let foundByKey = store.findBySourceKey(col.sourceKey)
        XCTAssertNotNil(foundByKey)
        XCTAssertEqual(foundByKey?.id, col.id)

        // Add member
        let m3 = CollectionMember(sourceKey: "komiic", comicId: "c3", displayName: "Part 3")
        let added = store.addMembers(id: col.id, incoming: [m3])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.find(id: col.id)?.members.count, 3)

        // Remove member
        store.removeMember(id: col.id, sourceKey: "komiic", comicId: "c2")
        XCTAssertEqual(store.find(id: col.id)?.members.count, 2)

        // Remove collection
        store.remove(id: col.id)
        XCTAssertNil(store.find(id: col.id))
    }

    func testImageFavoriteManager() {
        let manager = ImageFavoriteManager.shared
        let dummyData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48] + [UInt8](repeating: 0x00, count: 100))

        XCTAssertFalse(manager.isFavorited(comicId: "comic_fav", sourceKey: "komiic", epIndex: 1, pageIndex: 5))

        manager.addFavorite(
            comicId: "comic_fav",
            sourceKey: "komiic",
            title: "Fav Comic",
            subtitle: "Artist",
            epIndex: 1,
            epTitle: "Chapter 1",
            pageIndex: 5,
            imageKey: "https://example.com/p5.jpg",
            imageData: dummyData
        )

        XCTAssertTrue(manager.isFavorited(comicId: "comic_fav", sourceKey: "komiic", epIndex: 1, pageIndex: 5))
        XCTAssertEqual(manager.count, 1)

        let all = manager.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Fav Comic")
        XCTAssertEqual(all.first?.pageIndex, 5)
        let persistedPath = all.first?.localFilePath
        XCTAssertNotNil(persistedPath)

        // Refreshing metadata without image bytes must not discard the offline
        // copy (INSERT OR REPLACE used to clear local_file here).
        manager.addFavorite(
            comicId: "comic_fav",
            sourceKey: "komiic",
            title: "Updated title",
            subtitle: "Artist",
            epIndex: 1,
            epTitle: "Chapter 1",
            pageIndex: 5,
            imageKey: "https://example.com/p5-updated.jpg"
        )
        let refreshed = manager.getAll().first
        XCTAssertEqual(refreshed?.title, "Updated title")
        XCTAssertEqual(refreshed?.localFilePath, persistedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedPath ?? ""))

        manager.removeFavorite(comicId: "comic_fav", sourceKey: "komiic", epIndex: 1, pageIndex: 5)
        XCTAssertFalse(manager.isFavorited(comicId: "comic_fav", sourceKey: "komiic", epIndex: 1, pageIndex: 5))
        XCTAssertEqual(manager.count, 0)
    }

    @MainActor
    func testReaderCurrentPageFavoriteRoundTrip() async {
        let comic = Comic(
            id: "reader-fav",
            title: "Reader Favorite",
            cover: "",
            subtitle: "Author",
            sourceKey: "local"
        )
        let reader = ReaderModel(comic: comic, source: nil, epIndex: 0)
        reader.pages = [tempDir + "/page.jpg"]
        try? Data(repeating: 1, count: 128).write(to: URL(fileURLWithPath: reader.pages[0]))

        XCTAssertFalse(reader.isCurrentPageFavorited())
        let added = await reader.toggleCurrentPageFavorite()
        XCTAssertEqual(added, true)
        XCTAssertTrue(reader.isCurrentPageFavorited())
        let removed = await reader.toggleCurrentPageFavorite()
        XCTAssertEqual(removed, false)
        XCTAssertFalse(reader.isCurrentPageFavorited())
    }

    /// 跳页输入钳制（对齐上游 v2.3.0 #0bed1f2e：越界值自动纠正而非报错）。
    @MainActor
    func testReaderJumpToPageClampsInputToValidRange() async {
        let comic = Comic(id: "jump-clamp", title: "Jump", cover: "", subtitle: "", sourceKey: "local")
        let reader = ReaderModel(comic: comic, source: nil, epIndex: 0)
        reader.pages = (0..<10).map { "\($0).jpg" }

        await reader.jumpToPage(0)
        XCTAssertEqual(reader.currentIndex, 0)
        await reader.jumpToPage(999)
        XCTAssertEqual(reader.currentIndex, 9)
        await reader.jumpToPage(-5)
        XCTAssertEqual(reader.currentIndex, 0)
        await reader.jumpToPage(5)
        XCTAssertEqual(reader.currentIndex, 4)
    }

    /// 连续模式显式改索引产生滚动请求目标；消费后置空（对齐 #681334b9 联动语义）。
    @MainActor
    func testContinuousSetIndexRequestsPagerScrollToTarget() async {
        let comic = Comic(id: "jump-cont", title: "Jump Cont", cover: "", subtitle: "", sourceKey: "local")
        let reader = ReaderModel(comic: comic, source: nil, epIndex: 0)
        reader.mode = .continuousTopToBottom
        reader.pages = (0..<6).map { "\($0).jpg" }
        reader.continuousItems = ReaderModel.continuousItems(for: 0, pageList: reader.pages, chapterTitle: "Ch 1")

        XCTAssertNil(reader.continuousJumpTargetItemID)
        reader.setIndex(3)
        XCTAssertEqual(reader.continuousJumpTargetItemID, "0_3_false")
        XCTAssertEqual(reader.consumeContinuousJumpTargetItemID(), "0_3_false")
        XCTAssertNil(reader.continuousJumpTargetItemID)

        // 画廊模式不产生滚动请求。
        reader.mode = .galleryLeftToRight
        reader.setIndex(2)
        XCTAssertNil(reader.continuousJumpTargetItemID)
    }

    /// 重复标题检测：scope 内去重、跨 scope 独立、空白标题跳过、trim 后比较。
    func testFindDuplicateTitleIndicesScopesAndTrim() {
        // 平铺：0/1 同名 → 1 为重复；3 标题仅空白差异（trim 后同名）→ 重复。
        let flat = findDuplicateTitleIndices(
            count: 5,
            titleOf: { ["第1话", "第1话", "第2话", "  第2话  ", "" ][$0] }
        )
        XCTAssertEqual(flat, [1, 3])

        // 分 scope：两组各自的「第一话」互不干扰，只有组内第二次出现才上报。
        let grouped = findDuplicateTitleIndices(
            count: 5,
            titleOf: { ["第一话", "第二话", "第一话", "第一话", "第二话"][$0] },
            scopes: [[0, 1], [2, 3, 4]]
        )
        XCTAssertEqual(grouped, [3])
    }

    /// 步进跳过隐藏章节：组内跳过、组边界止步、第一步允许跨组。
    func testNextVisibleChapterSkipSearchStaysInGroup() {
        // 平铺无分组：0→1 隐藏→2。
        let flat = VeneraKit.nextVisibleChapter(
            from: 0, step: 1, chapterCount: 3,
            isHidden: { $0 == 1 }, groupOf: { _ in 0 }
        )
        XCTAssertEqual(flat, 2)

        // 分组 [0,1] | [2,3]：from=0 向后跳过 1 时不得越过组边界进入组 2。
        let bounded = VeneraKit.nextVisibleChapter(
            from: 0, step: 1, chapterCount: 4,
            isHidden: { $0 == 1 }, groupOf: { $0 < 2 ? 0 : 1 }
        )
        XCTAssertNil(bounded)

        // 第一步本身就是普通 ±1：允许跨组（1→2），只有落点隐藏才受限搜索。
        let crossGroupFirstStep = VeneraKit.nextVisibleChapter(
            from: 1, step: 1, chapterCount: 4,
            isHidden: { _ in false }, groupOf: { $0 < 2 ? 0 : 1 }
        )
        XCTAssertEqual(crossGroupFirstStep, 2)

        // 越界与 step=0。
        XCTAssertNil(VeneraKit.nextVisibleChapter(
            from: 3, step: 1, chapterCount: 4, isHidden: { _ in false }, groupOf: { _ in 0 }
        ))
        XCTAssertNil(VeneraKit.nextVisibleChapter(
            from: 1, step: 0, chapterCount: 4, isHidden: { _ in false }, groupOf: { _ in 0 }
        ))
    }

    /// 每部漫画隐藏开关往返（设备本地 implicitData）。
    func testChapterDuplicatePrefsRoundTrip() {
        let key = "hideDuplicateChapters"
        defer { AppData.shared.setImplicitValue(key, .object([:])) }

        XCTAssertFalse(ChapterDuplicatePrefs.isHidden(comicId: "dup-a", sourceKey: "komiic"))
        ChapterDuplicatePrefs.setHidden(true, comicId: "dup-a", sourceKey: "komiic")
        XCTAssertTrue(ChapterDuplicatePrefs.isHidden(comicId: "dup-a", sourceKey: "komiic"))
        XCTAssertFalse(ChapterDuplicatePrefs.isHidden(comicId: "dup-b", sourceKey: "komiic"))
        ChapterDuplicatePrefs.setHidden(false, comicId: "dup-a", sourceKey: "komiic")
        XCTAssertFalse(ChapterDuplicatePrefs.isHidden(comicId: "dup-a", sourceKey: "komiic"))
    }

    /// 阅读器解析隐藏集合并在步进/抽屉判定中跳过（对齐 #bb27c447）。
    @MainActor
    func testReaderResolvesHiddenChaptersAndSkipsInStepping() {
        let chapters = ComicChapters(groupEntries: [
            .init(name: "正文", chapters: [
                .init(id: "e1", title: "第1话"),
                .init(id: "e2", title: "第2话"),
                .init(id: "e3", title: "第2话"),
                .init(id: "e4", title: "第3话"),
            ])
        ])
        let comic = Comic(id: "hide-dup", title: "Hide Dup", cover: "", subtitle: "", sourceKey: "komiic")
        ChapterDuplicatePrefs.setHidden(true, comicId: comic.id, sourceKey: comic.sourceKey)
        defer { ChapterDuplicatePrefs.setHidden(false, comicId: comic.id, sourceKey: comic.sourceKey) }

        let reader = ReaderModel(comic: comic, source: nil, epIndex: 0)
        reader.setChapters(chapters)

        // e3 标题与 e2 重复 → 平铺索引 2 被折叠。
        XCTAssertEqual(reader.hiddenChapterIndices, [2])
        XCTAssertTrue(reader.isChapterHidden(2))
        XCTAssertFalse(reader.isChapterHidden(1))

        // 翻章步进跳过隐藏章节。
        XCTAssertEqual(reader.nextVisibleChapter(from: 1, step: 1), 3)
        XCTAssertEqual(reader.nextVisibleChapter(from: 3, step: -1), 1)
        XCTAssertNil(reader.nextVisibleChapter(from: 3, step: 1))

        // 开关关闭时不折叠。
        ChapterDuplicatePrefs.setHidden(false, comicId: comic.id, sourceKey: comic.sourceKey)
        reader.setChapters(chapters)
        XCTAssertTrue(reader.hiddenChapterIndices.isEmpty)
        XCTAssertEqual(reader.nextVisibleChapter(from: 1, step: 1), 2)
    }

    /// 分组章节的组边界：隐藏组尾后向后搜索不得跨入下一组。
    @MainActor
    func testReaderNextVisibleStopsAtGroupBoundary() {
        let chapters = ComicChapters(groupEntries: [
            .init(name: "正文", chapters: [
                .init(id: "a1", title: "第1话"),
                .init(id: "a2", title: "第1话"),
            ]),
            .init(name: "番外", chapters: [
                .init(id: "b1", title: "特别篇"),
            ])
        ])
        let comic = Comic(id: "hide-dup-g", title: "Groups", cover: "", subtitle: "", sourceKey: "komiic")
        ChapterDuplicatePrefs.setHidden(true, comicId: comic.id, sourceKey: comic.sourceKey)
        defer { ChapterDuplicatePrefs.setHidden(false, comicId: comic.id, sourceKey: comic.sourceKey) }

        let reader = ReaderModel(comic: comic, source: nil, epIndex: 0)
        reader.setChapters(chapters)

        // 平铺索引 1（组 0 的重复项）被折叠；从 0 向后受限搜索止于组边界，
        // 不得把读者直接丢到组 1 的「特别篇」。
        XCTAssertEqual(reader.hiddenChapterIndices, [1])
        XCTAssertNil(reader.nextVisibleChapter(from: 0, step: 1))
    }

    func testHomeLayoutStore() {
        let defaults = HomeLayoutStore.loadSections()
        XCTAssertEqual(defaults.count, HomeLayoutStore.defaultSections.count)

        var modified = defaults
        modified[0].visible = false
        HomeLayoutStore.saveSections(modified)

        let reloaded = HomeLayoutStore.loadSections()
        XCTAssertEqual(reloaded.first?.visible, false)
    }
}

extension MoreFeaturesTests {
    func testReaderGallerySpreadsKeepCoverAlone() {
        let spreads = ReaderModel.gallerySpreads(
            pageCount: 5,
            pagesPerSpread: 2,
            showSingleImageOnFirstPage: true
        )
        XCTAssertEqual(spreads.map(\.pageIndices), [[0], [1, 2], [3, 4]])
        XCTAssertEqual(
            ReaderModel.gallerySpreadIndex(
                forImageIndex: 4,
                pageCount: 5,
                pagesPerSpread: 2,
                showSingleImageOnFirstPage: true
            ),
            2
        )
    }

    func testReaderGallerySpreadsPairFromFirstPageWhenCoverModeDisabled() {
        let spreads = ReaderModel.gallerySpreads(
            pageCount: 5,
            pagesPerSpread: 2,
            showSingleImageOnFirstPage: false
        )
        XCTAssertEqual(spreads.map(\.pageIndices), [[0, 1], [2, 3], [4]])
        XCTAssertEqual(
            ReaderModel.gallerySpreadIndex(
                forImageIndex: 3,
                pageCount: 5,
                pagesPerSpread: 2,
                showSingleImageOnFirstPage: false
            ),
            1
        )
    }
}

extension MoreFeaturesTests {
    func testContinuousItemsKeepStableChapterAndPageIDs() {
        let items = ReaderModel.continuousItems(
            for: 7,
            pageList: ["p1", "p2"],
            chapterTitle: "Chapter 8"
        )
        XCTAssertEqual(items.map(\.id), ["7_0_true", "7_0_false", "7_1_false"])
        XCTAssertTrue(items[0].isChapterHeader)
        XCTAssertEqual(items[1].pageIndex, 0)
        XCTAssertEqual(items[2].pageIndex, 1)
    }

    func testContinuousPrefetchOnlyNearLoadedWindowBoundaries() {
        XCTAssertTrue(ReaderModel.shouldPrefetchPreviousContinuousChapter(itemOffset: 0, itemCount: 20))
        XCTAssertTrue(ReaderModel.shouldPrefetchPreviousContinuousChapter(itemOffset: 3, itemCount: 20))
        XCTAssertFalse(ReaderModel.shouldPrefetchPreviousContinuousChapter(itemOffset: 4, itemCount: 20))
        XCTAssertFalse(ReaderModel.shouldPrefetchNextContinuousChapter(itemOffset: 10, itemCount: 20))
        XCTAssertTrue(ReaderModel.shouldPrefetchNextContinuousChapter(itemOffset: 16, itemCount: 20))
        XCTAssertTrue(ReaderModel.shouldPrefetchNextContinuousChapter(itemOffset: 19, itemCount: 20))
    }

    func testContinuousPrefetchRejectsInvalidOffsets() {
        XCTAssertFalse(ReaderModel.shouldPrefetchPreviousContinuousChapter(itemOffset: -1, itemCount: 10))
        XCTAssertFalse(ReaderModel.shouldPrefetchNextContinuousChapter(itemOffset: 10, itemCount: 10))
        XCTAssertFalse(ReaderModel.shouldPrefetchNextContinuousChapter(itemOffset: 0, itemCount: 0))
    }
}
