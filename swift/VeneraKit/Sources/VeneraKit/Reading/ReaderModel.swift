import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// 阅读器模型：图片页加载、预载、翻页模式、连续跨章无缝连读、每部漫画独立设置。
/// 翻页模式对齐原版 ReaderMode（6 种：画廊 3 + 连续 3）。
/// 支持本地漫画与已下载章节的离线直读。
@Observable
@MainActor
public final class ReaderModel {
    public enum Mode: String, Sendable, CaseIterable {
        case galleryLeftToRight
        case galleryRightToLeft
        case galleryTopToBottom
        case continuousTopToBottom
        case continuousLeftToRight
        case continuousRightToLeft

        public var isContinuous: Bool {
            switch self {
            case .continuousTopToBottom, .continuousLeftToRight, .continuousRightToLeft: return true
            default: return false
            }
        }

        public var isRightToLeft: Bool {
            self == .galleryRightToLeft || self == .continuousRightToLeft
        }

        public var isVerticalGallery: Bool {
            self == .galleryTopToBottom
        }
    }

    public struct GallerySpread: Hashable, Sendable {
        public let pageIndices: [Int]

        public init(pageIndices: [Int]) {
            self.pageIndices = pageIndices
        }
    }

    /// Build logical gallery spreads without loading or decoding page images.
    /// When enabled, the cover is kept alone and subsequent spreads contain two pages.
    nonisolated public static func gallerySpreads(
        pageCount: Int,
        pagesPerSpread: Int = 2,
        showSingleImageOnFirstPage: Bool = false
    ) -> [GallerySpread] {
        guard pageCount > 0 else { return [] }
        let count = max(pagesPerSpread, 1)
        var result: [GallerySpread] = []
        var nextIndex = 0
        if showSingleImageOnFirstPage {
            result.append(GallerySpread(pageIndices: [0]))
            nextIndex = 1
        }
        while nextIndex < pageCount {
            let end = min(nextIndex + count, pageCount)
            result.append(GallerySpread(pageIndices: Array(nextIndex..<end)))
            nextIndex = end
        }
        return result
    }

    nonisolated public static func continuousItems(
        for epIndex: Int,
        pageList: [String],
        chapterTitle: String
    ) -> [ContinuousPageItem] {
        var items = [ContinuousPageItem(
            epIndex: epIndex,
            pageIndex: 0,
            imageKey: "",
            isChapterHeader: true,
            chapterTitle: chapterTitle
        )]
        items += pageList.enumerated().map { pageIndex, imageKey in
            ContinuousPageItem(
                epIndex: epIndex,
                pageIndex: pageIndex,
                imageKey: imageKey,
                chapterTitle: chapterTitle
            )
        }
        return items
    }

    nonisolated public static func shouldPrefetchPreviousContinuousChapter(
        itemOffset: Int,
        itemCount: Int,
        threshold: Int = 3
    ) -> Bool {
        guard itemCount > 0, itemOffset >= 0, itemOffset < itemCount else { return false }
        return itemOffset <= max(threshold, 0)
    }

    nonisolated public static func shouldPrefetchNextContinuousChapter(
        itemOffset: Int,
        itemCount: Int,
        threshold: Int = 3
    ) -> Bool {
        guard itemCount > 0, itemOffset >= 0, itemOffset < itemCount else { return false }
        return itemOffset >= max(itemCount - 1 - max(threshold, 0), 0)
    }

    nonisolated public static func gallerySpreadIndex(
        forImageIndex imageIndex: Int,
        pageCount: Int,
        pagesPerSpread: Int = 2,
        showSingleImageOnFirstPage: Bool = false
    ) -> Int {
        let spreads = gallerySpreads(
            pageCount: pageCount,
            pagesPerSpread: pagesPerSpread,
            showSingleImageOnFirstPage: showSingleImageOnFirstPage
        )
        guard !spreads.isEmpty else { return 0 }
        return spreads.firstIndex { $0.pageIndices.contains(imageIndex) } ?? 0
    }

    public struct ContinuousPageItem: Identifiable, Hashable, Sendable {
        public let id: String
        public let epIndex: Int
        public let pageIndex: Int
        public let imageKey: String
        public let isChapterHeader: Bool
        public let chapterTitle: String?

        public init(epIndex: Int, pageIndex: Int, imageKey: String, isChapterHeader: Bool = false, chapterTitle: String? = nil) {
            self.id = "\(epIndex)_\(pageIndex)_\(isChapterHeader)"
            self.epIndex = epIndex
            self.pageIndex = pageIndex
            self.imageKey = imageKey
            self.isChapterHeader = isChapterHeader
            self.chapterTitle = chapterTitle
        }
    }

    public let comic: Comic
    public let source: ComicSource?
    public private(set) var currentEpIndex: Int

    public var pages: [String] = []
    public var currentIndex: Int = 0
    public var isLoadingPages = true
    public var errorMessage: String?

    /// 连续模式跨章条目列表
    public var continuousItems: [ContinuousPageItem] = []
    /// id → continuousItems 下标。滚动路径上每个可见条目都要定位下标
    /// （预取判定 + 缓存修剪），条目可达数千且每帧触发，线性扫描是滚动
    /// 热点；维护反向索引把查找降到 O(1)。prepend 时整体平移，直接重建
    /// （仅在加载上一章时发生）；append 增量插入。
    @ObservationIgnored
    private var continuousItemIndex: [String: Int] = [:]
    public private(set) var loadedChapterIndices: Set<Int> = []
    public var isLoadingNextChapter = false
    /// Used by the continuous pager to restore the first visible item after a
    /// previous chapter is prepended. Stable IDs prevent the viewport from
    /// jumping when the lazy stack grows at its leading edge.
    public private(set) var continuousAnchorToRestoreID: String?
    /// 显式跳页（滑杆/跳页对话框）请求连续分页器 scrollTo 的目标条目。
    /// 消费式：分页器执行滚动后立即置空，避免同一目标重复触发。
    public private(set) var continuousJumpTargetItemID: String?

    /// 已加载的图片数据（画廊页码或连续条目 ID → 字节）。
    public var loadedImages: [Int: Data] = [:]
    public var continuousLoadedImages: [String: Data] = [:]
    public private(set) var failedPages: Set<Int> = []

    public var mode: Mode
    public var isToolbarHidden = false
    public var isNightMode = false

    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var retryTasks: [Int: Task<Void, Never>] = [:]
    private var retryTokens: [Int: UUID] = [:]
    private var continuousChapterLoadTasks: Set<Int> = []
    private var attemptedContinuousChapterIndices: Set<Int> = []
    private var preloadTokens: [Int: UUID] = [:]
    private var loadGeneration = 0
    private let preloadCount: Int
    /// Decoded page bytes are intentionally bounded by both proximity and total cost.
    /// Large scans can make a small page count exceed hundreds of MB.
    private let decodedImageMemoryBudget = 96 * 1024 * 1024

    // MARK: - 解码位图缓存（连续模式）
    // 字节缓存只省网络/磁盘 IO；Lazy stack 出屏即销毁视图状态，回滚到
    // 已看过的页仍要整轮重新解码+增强。此 LRU 缓存解码后位图，用像素
    // 字节数（w*h*4）计成本，独立预算（与字节缓存分开计量）。
    #if canImport(UIKit)
    @ObservationIgnored
    private var decodedBitmaps: [String: UIImage] = [:]
    @ObservationIgnored
    private var decodedBitmapCosts: [String: Int] = [:]
    @ObservationIgnored
    private var decodedBitmapParameterFingerprints: [String: ImageEnhancer.Parameters] = [:]
    @ObservationIgnored
    private var decodedBitmapOrder: [String] = [] // 插入序，淘汰从头删
    @ObservationIgnored
    private var decodedBitmapTotalCost = 0
    private let decodedBitmapBudget = 64 * 1024 * 1024
    #endif

    private var detailsChapters: ComicChapters?

    public init(comic: Comic, source: ComicSource?, epIndex: Int = 0) {
        self.comic = comic
        self.source = source
        self.currentEpIndex = epIndex
        self.settingScope = ReaderSettingScope(comicId: comic.id, sourceKey: comic.sourceKey)
        let settings = AppData.shared.settings
        let modeString = settings.getReaderSetting(comicId: comic.id, sourceKey: comic.sourceKey, key: "readerMode")
            .stringValue ?? "galleryLeftToRight"
        self.mode = Mode(rawValue: modeString) ?? .galleryLeftToRight
        self.isNightMode = self.settingScope.effective("readerNightMode").boolValue ?? false
        self.preloadCount = self.settingScope.effective("preloadImageCount").intValue ?? 4
    }

    /// 阅读设置作用域（漫画级 → 设备级 → 全局），供阅读器各视图读取生效值。
    /// Sendable 且不可变，标记 nonisolated 供非隔离上下文（如静态翻页编排）安全读取。
    nonisolated public let settingScope: ReaderSettingScope

    /// 当前漫画的阅读设置生效值（对齐上游 reader.dart 的 getReaderSetting 读取）。
    nonisolated public func setting(_ key: String) -> JSON {
        settingScope.effective(key)
    }

    public func setChapters(_ chapters: ComicChapters?) {
        detailsChapters = chapters
        // 开关在详情页，阅读器打开期间不会变化——与原版一致只解析一次。
        if let chapters, !chapters.isEmpty,
           ChapterDuplicatePrefs.isHidden(comicId: comic.id, sourceKey: comic.sourceKey) {
            hiddenChapterIndices = chapters.duplicateTitleIndices()
        } else {
            hiddenChapterIndices = []
        }
    }

    public var chapterIds: [String] {
        detailsChapters?.ids ?? []
    }

    public var chapterTitles: [String] {
        detailsChapters?.titles ?? []
    }

    /// 被本漫画「隐藏重复章节」开关折叠的章节（平铺 0 基索引）。
    public private(set) var hiddenChapterIndices: Set<Int> = []

    public func isChapterHidden(_ ep: Int) -> Bool {
        hiddenChapterIndices.contains(ep)
    }

    /// 从 from 按步长 step 步进的第一个未隐藏章节；不可达返回 nil。
    /// 阅读器翻章、抽屉跳转与连续模式预取都经由此入口，
    /// 保证隐藏章节不会再被步进/列表/预取走回去（对齐原版 #bb27c447）。
    public func nextVisibleChapter(from: Int, step: Int) -> Int? {
        guard let detailsChapters else {
            let target = from + step
            return chapterIds.indices.contains(target) ? target : nil
        }
        return VeneraKit.nextVisibleChapter(
            from: from,
            step: step,
            chapterCount: chapterIds.count,
            isHidden: { self.isChapterHidden($0) },
            groupOf: { detailsChapters.groupOfChapter($0) }
        )
    }

    public func chapterTitle(at index: Int) -> String? {
        guard detailsChapters?.titles.indices.contains(index) == true else { return nil }
        return detailsChapters?.titles[index]
    }

    public var currentPageNumber: Int { currentIndex + 1 }
    public var totalPages: Int { pages.count }

    /// Stable identity used by the image-translation result cache.
    public func translationCacheKey(for pageIndex: Int) -> String? {
        guard pages.indices.contains(pageIndex) else { return nil }
        let eid = chapterIds.indices.contains(currentEpIndex) ? chapterIds[currentEpIndex] : ""
        return "\(comic.sourceKey)/\(comic.id)/\(eid)/\(pages[pageIndex])"
    }

    public func translationCacheKey(for item: ContinuousPageItem) -> String {
        let eid = chapterIds.indices.contains(item.epIndex) ? chapterIds[item.epIndex] : ""
        return "\(comic.sourceKey)/\(comic.id)/\(eid)/\(item.imageKey)"
    }

    public func loadPages() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        preloadTokens.removeAll()
        continuousChapterLoadTasks.removeAll()
        attemptedContinuousChapterIndices.removeAll()
        continuousAnchorToRestoreID = nil
        continuousJumpTargetItemID = nil
        errorMessage = nil
        isLoadingPages = true
        defer {
            if generation == loadGeneration {
                isLoadingPages = false
            }
        }
        continuousItems = []
        continuousItemIndex = [:]
        loadedChapterIndices = []
        continuousLoadedImages = [:]
        #if canImport(UIKit)
        clearDecodedBitmaps()
        #endif
        lastContinuousTrimIndex = -1

        // 1. 本地导入漫画直读
        if comic.sourceKey == "local" {
            let localComic = LocalManager.shared.find(id: comic.id, type: ComicID.local)
            if detailsChapters == nil, let chs = localComic?.chapters {
                setChapters(chs)
            }
            let localPages = LocalManager.shared.getImages(id: comic.id, type: ComicID.local, ep: currentEpIndex + 1)
            pages = localPages
            setupContinuousItems(for: currentEpIndex, pageList: localPages)
            currentIndex = min(currentIndex, max(pages.count - 1, 0))
            preloadAround(index: currentIndex)
            return
        }

        // 2. 在线漫画：优先检查当前章节是否已下载落盘
        let comicType = ComicID.forSource(comic.sourceKey)
        if LocalManager.shared.isDownloaded(id: comic.id, type: comicType, ep: currentEpIndex + 1, chapters: detailsChapters) {
            let localPages = LocalManager.shared.getImages(id: comic.id, type: comicType, ep: currentEpIndex + 1)
            if !localPages.isEmpty {
                pages = localPages
                setupContinuousItems(for: currentEpIndex, pageList: localPages)
                currentIndex = min(currentIndex, max(pages.count - 1, 0))
                preloadAround(index: currentIndex)
                return
            }
        }

        // 3. 在线网络加载
        guard let source else {
            errorMessage = "Source not found: \(comic.sourceKey)"
            return
        }
        var fallbackError: String?
        do {
            if detailsChapters == nil {
                do {
                    let details = try await source.loadComicInfo(id: comic.id)
                    guard generation == loadGeneration else { return }
                    if let chapters = details.chapters {
                        setChapters(chapters)
                    }
                } catch {
                    Log.error("Reader", "Chapter fallback failed: \(error)")
                    fallbackError = "Chapter list failed: \(error)"
                }
            }
            let epId = chapterIds.indices.contains(currentEpIndex) ? chapterIds[currentEpIndex] : nil
            pages = try await source.loadComicPages(id: comic.id, ep: epId)
            guard generation == loadGeneration else { return }
            setupContinuousItems(for: currentEpIndex, pageList: pages)
            currentIndex = min(currentIndex, max(pages.count - 1, 0))
            preloadAround(index: currentIndex)
        } catch {
            guard generation == loadGeneration else { return }
            if let fallbackError {
                errorMessage = "\(fallbackError) / \(error.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setupContinuousItems(for ep: Int, pageList: [String]) {
        let title = chapterTitle(at: ep) ?? "Chapter \(ep + 1)"
        continuousItems = Self.continuousItems(for: ep, pageList: pageList, chapterTitle: title)
        rebuildContinuousItemIndex()
        loadedChapterIndices.insert(ep)
        attemptedContinuousChapterIndices.insert(ep)
    }

    /// 连续模式：按需加载一个相邻章节。只保留当前已加载章节附近的
    /// entry，不会因为章节列表很长而加载全部图片地址或图片数据。
    private func loadContinuousChapter(_ ep: Int, prepend: Bool) async {
        guard mode.isContinuous, chapterIds.indices.contains(ep),
              !loadedChapterIndices.contains(ep),
              !attemptedContinuousChapterIndices.contains(ep),
              !continuousChapterLoadTasks.contains(ep) else { return }

        continuousChapterLoadTasks.insert(ep)
        attemptedContinuousChapterIndices.insert(ep)
        if prepend { isLoadingNextChapter = true }
        defer {
            continuousChapterLoadTasks.remove(ep)
            isLoadingNextChapter = !continuousChapterLoadTasks.isEmpty
        }

        guard let chapterPages = await fetchChapterPages(ep) else { return }
        guard !chapterPages.isEmpty, !Task.isCancelled else { return }

        let title = chapterTitle(at: ep) ?? "Chapter \(ep + 1)"
        let newItems = Self.continuousItems(for: ep, pageList: chapterPages, chapterTitle: title)
        if prepend {
            continuousAnchorToRestoreID = continuousItems.first?.id
            continuousItems.insert(contentsOf: newItems, at: 0)
            // 前插使全部旧下标平移，重建（仅在加载上一章时发生，低频）。
            rebuildContinuousItemIndex()
        } else {
            let base = continuousItems.count
            continuousItems.append(contentsOf: newItems)
            for (offset, item) in newItems.enumerated() {
                continuousItemIndex[item.id] = base + offset
            }
        }
        loadedChapterIndices.insert(ep)
    }

    private func rebuildContinuousItemIndex() {
        continuousItemIndex.reserveCapacity(continuousItems.count)
        for (offset, item) in continuousItems.enumerated() {
            continuousItemIndex[item.id] = offset
        }
    }

    /// O(1) 定位连续条目下标（滚动热路径）。
    private func indexOfContinuousItem(id: String) -> Int? {
        continuousItemIndex[id]
    }

    private func fetchChapterPages(_ ep: Int) async -> [String]? {
        guard !Task.isCancelled else { return nil }
        let comicType = ComicID.forSource(comic.sourceKey)
        if comic.sourceKey == "local" || LocalManager.shared.isDownloaded(
            id: comic.id, type: comicType, ep: ep + 1, chapters: detailsChapters
        ) {
            let pages = LocalManager.shared.getImages(id: comic.id, type: comicType, ep: ep + 1)
            return pages.isEmpty ? nil : pages
        }
        guard let source, chapterIds.indices.contains(ep) else { return nil }
        return try? await source.loadComicPages(id: comic.id, ep: chapterIds[ep])
    }

    /// 保留旧调用点语义：显式请求下一章时仍然可以直接调用。
    public func loadNextChapterInContinuousMode() async {
        let lastLoaded = loadedChapterIndices.max() ?? currentEpIndex
        // 跳过被隐藏的重复章节，而不是把列表重新走回去（对齐 #bb27c447）。
        guard let target = nextVisibleChapter(from: lastLoaded, step: 1) else { return }
        await loadContinuousChapter(target, prepend: false)
    }

    public func loadPreviousChapterInContinuousMode() async {
        let firstLoaded = loadedChapterIndices.min() ?? currentEpIndex
        guard let target = nextVisibleChapter(from: firstLoaded, step: -1) else { return }
        await loadContinuousChapter(target, prepend: true)
    }

    public func consumeContinuousAnchorToRestoreID() -> String? {
        defer { continuousAnchorToRestoreID = nil }
        return continuousAnchorToRestoreID
    }

    public func consumeContinuousJumpTargetItemID() -> String? {
        defer { continuousJumpTargetItemID = nil }
        return continuousJumpTargetItemID
    }

    /// 切换章节（页码归零；历史记录由调用方在合适时机写入）。
    public func switchChapter(to index: Int) async {
        guard chapterIds.indices.contains(index) || (detailsChapters == nil && index == 0) else { return }
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        preloadTokens.removeAll()
        continuousChapterLoadTasks.removeAll()
        attemptedContinuousChapterIndices.removeAll()
        continuousAnchorToRestoreID = nil
        continuousJumpTargetItemID = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retryTokens.removeAll()
        currentEpIndex = index
        pages = []
        loadedImages.removeAll(keepingCapacity: true)
        continuousLoadedImages.removeAll(keepingCapacity: true)
        #if canImport(UIKit)
        clearDecodedBitmaps()
        #endif
        lastContinuousTrimIndex = -1
        currentIndex = 0
        await loadPages()
    }

    // MARK: - 索引与状态

    public func setIndex(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentIndex = index
        if mode.isContinuous {
            // 连续模式下显式改索引即跳页请求：分页器监听目标条目并 scrollTo。
            // 每页 frame 固定为视口尺寸，scrollTo 精确落在页面上（对齐上游
            // v2.3.0 #681334b9 的语义；Flutter 需 repivot 因其条目高度随图片
            // 加载漂移，Swift 固定 frame 无此问题）。
            continuousJumpTargetItemID = "\(currentEpIndex)_\(index)_false"
        } else {
            trimLoadedImages(around: index)
        }
    }

    /// 跳页对话框入口：钳制到 1...totalPages 后跳转（对齐上游 v2.3.0
    /// #0bed1f2e 的自动钳制语义），并同步预载与历史。
    public func jumpToPage(_ pageNumber: Int) async {
        let index = min(max(pageNumber, 1), max(totalPages, 1)) - 1
        guard pages.indices.contains(index) else { return }
        setIndex(index)
        await afterIndexChange(index)
    }

    public func afterIndexChange(_ index: Int) async {
        guard pages.indices.contains(index) else { return }
        preloadAround(index: index)
        recordHistory()
    }

    public func onContinuousItemVisible(_ item: ContinuousPageItem) {
        guard let offset = indexOfContinuousItem(id: item.id) else { return }
        if currentEpIndex != item.epIndex {
            currentEpIndex = item.epIndex
            if let chPages = getChapterPages(for: item.epIndex) { pages = chPages }
        }
        if !item.isChapterHeader {
            currentIndex = item.pageIndex
            trimContinuousImages(around: item.id)
            recordHistory()
        }

        let count = continuousItems.count
        if Self.shouldPrefetchPreviousContinuousChapter(itemOffset: offset, itemCount: count) {
            let loaded = loadedChapterIndices.min() ?? currentEpIndex
            if let previous = nextVisibleChapter(from: loaded, step: -1) {
                Task { [weak self] in await self?.loadContinuousChapter(previous, prepend: true) }
            }
        }
        if Self.shouldPrefetchNextContinuousChapter(itemOffset: offset, itemCount: count) {
            let loaded = loadedChapterIndices.max() ?? currentEpIndex
            if let next = nextVisibleChapter(from: loaded, step: 1) {
                Task { [weak self] in await self?.loadContinuousChapter(next, prepend: false) }
            }
        }
    }

    private func getChapterPages(for ep: Int) -> [String]? {
        let matching = continuousItems.filter { $0.epIndex == ep && !$0.isChapterHeader }
        return matching.isEmpty ? nil : matching.map(\.imageKey)
    }

    public func isChapterReadMark(_ index: Int) -> Bool {
        let type = ComicID.forSource(comic.sourceKey)
        guard let history = HistoryManager.shared.findHistory(id: comic.id, type: type) else { return false }
        return history.readEpisode.contains(String(index + 1))
    }

    // MARK: - 历史记录

    public func recordHistory() {
        let type = ComicID.forSource(comic.sourceKey)
        var history = HistoryManager.shared.findHistory(id: comic.id, type: type)
            ?? History(id: comic.id, type: type, title: comic.title, subtitle: comic.subtitle, cover: comic.cover)
        history.time = Date()
        history.ep = currentEpIndex + 1
        history.page = currentPageNumber
        history.maxPage = totalPages
        history.readEpisode.insert(String(currentEpIndex + 1))
        HistoryManager.shared.addHistory(history)
    }

    // MARK: - 单页收藏

    public func isCurrentPageFavorited() -> Bool {
        guard pages.indices.contains(currentIndex) else { return false }
        return ImageFavoriteManager.shared.isFavorited(
            comicId: comic.id,
            sourceKey: comic.sourceKey,
            epIndex: currentEpIndex,
            pageIndex: currentIndex
        )
    }

    /// 切换当前页收藏。返回 nil 表示当前页图片尚未成功加载，避免创建
    /// 一个无法离线查看的“空收藏”记录。
    @discardableResult
    public func toggleCurrentPageFavorite() async -> Bool? {
        guard pages.indices.contains(currentIndex) else { return nil }
        let pageIndex = currentIndex
        let pageKey = pages[pageIndex]
        let data: Data?
        if mode.isContinuous,
           let item = continuousItems.first(where: {
               !$0.isChapterHeader && $0.epIndex == currentEpIndex && $0.pageIndex == pageIndex
           }) {
            data = await continuousImageData(for: item)
        } else {
            data = await imageData(at: pageIndex)
        }
        guard let data else { return nil }

        let manager = ImageFavoriteManager.shared
        let wasFavorited = manager.isFavorited(
            comicId: comic.id,
            sourceKey: comic.sourceKey,
            epIndex: currentEpIndex,
            pageIndex: pageIndex
        )
        if wasFavorited {
            manager.removeFavorite(
                comicId: comic.id,
                sourceKey: comic.sourceKey,
                epIndex: currentEpIndex,
                pageIndex: pageIndex
            )
        } else {
            manager.addFavorite(
                comicId: comic.id,
                sourceKey: comic.sourceKey,
                title: comic.title,
                subtitle: comic.subtitle,
                epIndex: currentEpIndex,
                epTitle: chapterTitle(at: currentEpIndex) ?? "Chapter \(currentEpIndex + 1)",
                pageIndex: pageIndex,
                imageKey: pageKey,
                imageData: data
            )
        }
        return !wasFavorited
    }

    // MARK: - 图片加载与预载

    /// 本地漫画页可能是几十 MB 的大图；ReaderModel 在主 actor 上，必须把文件读取移出主线程。
    private nonisolated static func readLocalData(at path: String) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        }.value
    }

    public func imageData(at index: Int) async -> Data? {
        if let cached = loadedImages[index] {
            return cached
        }
        guard pages.indices.contains(index) else { return nil }
        let pageItem = pages[index]

        if pageItem.hasPrefix("file://") {
            let path = String(pageItem.dropFirst("file://".count))
            if let data = await Self.readLocalData(at: path) {
                loadedImages[index] = data
                trimLoadedImages(around: index)
                failedPages.remove(index)
                return data
            }
        } else if pageItem.hasPrefix("/") {
            if let data = await Self.readLocalData(at: pageItem) {
                loadedImages[index] = data
                trimLoadedImages(around: index)
                failedPages.remove(index)
                return data
            }
        }

        guard let source else { return nil }
        if let data = await ImageDownloader.shared.load(
            imageKey: pageItem,
            sourceKey: comic.sourceKey,
            cid: comic.id,
            eid: chapterIds.indices.contains(currentEpIndex) ? chapterIds[currentEpIndex] : "",
            source: source
        ) {
            loadedImages[index] = data
            trimLoadedImages(around: index)
            failedPages.remove(index)
            return data
        }
        failedPages.insert(index)
        return nil
    }

    public func continuousImageData(for item: ContinuousPageItem) async -> Data? {
        if let cached = continuousLoadedImages[item.id] {
            return cached
        }
        guard !item.imageKey.isEmpty else { return nil }

        if item.imageKey.hasPrefix("file://") {
            let path = String(item.imageKey.dropFirst("file://".count))
            if let data = await Self.readLocalData(at: path) {
                continuousLoadedImages[item.id] = data
                trimContinuousImages(around: item.id)
                return data
            }
        } else if item.imageKey.hasPrefix("/") {
            if let data = await Self.readLocalData(at: item.imageKey) {
                continuousLoadedImages[item.id] = data
                trimContinuousImages(around: item.id)
                return data
            }
        }

        guard let source else { return nil }
        let eid = chapterIds.indices.contains(item.epIndex) ? chapterIds[item.epIndex] : ""
        if let data = await ImageDownloader.shared.load(
            imageKey: item.imageKey,
            sourceKey: comic.sourceKey,
            cid: comic.id,
            eid: eid,
            source: source
        ) {
            continuousLoadedImages[item.id] = data
            trimContinuousImages(around: item.id)
            return data
        }
        return nil
    }

    public func preloadAround(index: Int) {
        trimLoadedImages(around: index)
        for offset in 1...max(preloadCount, 1) {
            schedulePreload(index + offset)
            schedulePreload(index - offset)
        }
    }

    /// Keep the reader's decoded byte cache bounded. The disk cache remains the
    /// durable cache; this in-memory cache is only a short viewing window.
    private func trimLoadedImages(around index: Int) {
        let radius = max(preloadCount * 2, 8)
        let lower = max(0, index - radius)
        let upper = min(max(pages.count - 1, 0), index + radius)
        let candidates = loadedImages
            .filter { (lower...upper).contains($0.key) }
            .sorted {
                let leftDistance = abs($0.key - index)
                let rightDistance = abs($1.key - index)
                return leftDistance == rightDistance ? $0.key < $1.key : leftDistance < rightDistance
            }

        var retained: [Int: Data] = [:]
        var totalCost = 0
        for (pageIndex, data) in candidates {
            let cost = data.count
            // Always retain the visible page when it exists, even if a single
            // unusually large scan exceeds the nominal budget.
            if pageIndex != index && totalCost + cost > decodedImageMemoryBudget { continue }
            retained[pageIndex] = data
            totalCost += cost
        }
        loadedImages = retained
    }

    /// 上次修剪时所在的下标。修剪半径远大于一帧滚过的条目数（12 vs 1），
    /// 每个条目出现都全窗口重算既无必要又抬高频滚动成本；距上次位置
    /// 不足 4 条时跳过，字节数学上仍在预算内（窗口最多晚 4 条收紧）。
    @ObservationIgnored
    private var lastContinuousTrimIndex: Int = -1

    private func trimContinuousImages(around itemID: String) {
        guard let index = indexOfContinuousItem(id: itemID) else { return }
        if lastContinuousTrimIndex >= 0, abs(index - lastContinuousTrimIndex) < 4 {
            return
        }
        lastContinuousTrimIndex = index
        let radius = max(preloadCount * 3, 12)
        let lower = max(0, index - radius)
        let upper = min(max(continuousItems.count - 1, 0), index + radius)
        let candidates = continuousItems[lower...upper]
            .enumerated()
            .compactMap { offset, item -> (String, Data, Int)? in
                guard let data = continuousLoadedImages[item.id] else { return nil }
                return (item.id, data, lower + offset)
            }
            .sorted { left, right in
                let leftDistance = abs(left.2 - index)
                let rightDistance = abs(right.2 - index)
                return leftDistance == rightDistance ? left.0 < right.0 : leftDistance < rightDistance
            }

        var retained: [String: Data] = [:]
        var totalCost = 0
        for (id, data, _) in candidates {
            let cost = data.count
            if id != itemID && totalCost + cost > decodedImageMemoryBudget { continue }
            retained[id] = data
            totalCost += cost
        }
        continuousLoadedImages = retained
    }

    // MARK: - 解码位图缓存 API（连续模式）

    #if canImport(UIKit)
    /// 命中已解码（含增强）位图直接返回，避免回滚时重复解码。parameters
    /// 为本次渲染的滤镜快照，与缓存时不符（用户改了增强设置）则视为未
    /// 命中，走完整解码路径。MainActor：模型主线程隔离，无跨线程竞争。
    public func decodedImage(for item: ContinuousPageItem, parameters: ImageEnhancer.Parameters) -> UIImage? {
        guard let image = decodedBitmaps[item.id],
              decodedBitmapParameterFingerprints[item.id] == parameters else { return nil }
        // 命中提升到淘汰序末尾（近似 LRU）。
        if let position = decodedBitmapOrder.firstIndex(of: item.id) {
            decodedBitmapOrder.remove(at: position)
            decodedBitmapOrder.append(item.id)
        }
        return image
    }

    /// 存入解码位图并执行预算淘汰。成本按像素字节（w*h*4）估算——
    /// 解码后位图的真实内存占用，而非压缩字节。
    public func storeDecodedImage(_ image: UIImage, for item: ContinuousPageItem, parameters: ImageEnhancer.Parameters) {
        let pixelCost = Int(image.size.width) * Int(image.size.height) * 4
        if decodedBitmaps[item.id] == nil {
            decodedBitmaps[item.id] = image
            decodedBitmapCosts[item.id] = pixelCost
            decodedBitmapParameterFingerprints[item.id] = parameters
            decodedBitmapTotalCost += pixelCost
            decodedBitmapOrder.append(item.id)
            evictDecodedBitmapsIfNeeded()
        }
    }

    private func evictDecodedBitmapsIfNeeded() {
        while decodedBitmapTotalCost > decodedBitmapBudget, !decodedBitmapOrder.isEmpty {
            let oldest = decodedBitmapOrder.removeFirst()
            if let cost = decodedBitmapCosts.removeValue(forKey: oldest) {
                decodedBitmapTotalCost -= cost
            }
            decodedBitmaps.removeValue(forKey: oldest)
            decodedBitmapParameterFingerprints.removeValue(forKey: oldest)
        }
    }

    private func clearDecodedBitmaps() {
        decodedBitmaps = [:]
        decodedBitmapCosts = [:]
        decodedBitmapParameterFingerprints = [:]
        decodedBitmapOrder = []
        decodedBitmapTotalCost = 0
    }
    #endif

    private func schedulePreload(_ index: Int) {
        guard pages.indices.contains(index), loadedImages[index] == nil, preloadTasks[index] == nil else { return }
        let model = self
        let token = UUID()
        preloadTokens[index] = token
        preloadTasks[index] = Task { [weak model] in
            defer {
                Task { @MainActor [weak model] in
                    guard let model, model.preloadTokens[index] == token else { return }
                    model.preloadTokens[index] = nil
                    model.preloadTasks[index] = nil
                }
            }
            guard !Task.isCancelled else { return }
            _ = await model?.imageData(at: index)
            guard !Task.isCancelled else { return }
        }
    }

    public func retryPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        retryTasks[index]?.cancel()
        let token = UUID()
        retryTokens[index] = token
        failedPages.remove(index)
        retryTasks[index] = Task { [weak self] in
            guard let self else { return }
            _ = await self.imageData(at: index)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.retryTokens[index] == token else { return }
                self.retryTokens[index] = nil
                self.retryTasks[index] = nil
            }
        }
    }
}
