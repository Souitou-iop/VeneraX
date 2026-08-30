import Foundation
import Observation

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
    public private(set) var loadedChapterIndices: Set<Int> = []
    public var isLoadingNextChapter = false

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
    /// 连续阅读触底回调可能因 Lazy* 重建重复触发；保留唯一的追加任务，避免同一章节并发请求。
    private var nextChapterLoadTask: Task<Void, Never>?
    private var preloadTokens: [Int: UUID] = [:]
    private var loadGeneration = 0
    private let preloadCount: Int
    /// Decoded page bytes are intentionally bounded by both proximity and total cost.
    /// Large scans can make a small page count exceed hundreds of MB.
    private let decodedImageMemoryBudget = 96 * 1024 * 1024

    private var detailsChapters: ComicChapters?

    public init(comic: Comic, source: ComicSource?, epIndex: Int = 0) {
        self.comic = comic
        self.source = source
        self.currentEpIndex = epIndex
        let settings = AppData.shared.settings
        let modeValue = settings.getReaderSetting(comicId: comic.id, sourceKey: comic.sourceKey, key: "readerMode")
        let modeString = modeValue.stringValue ?? "galleryLeftToRight"
        self.mode = Mode(rawValue: modeString) ?? .galleryLeftToRight
        self.isNightMode = settings["readerNightMode"].boolValue ?? false
        self.preloadCount = settings["preloadImageCount"].intValue ?? 4
    }

    public func setChapters(_ chapters: ComicChapters?) {
        detailsChapters = chapters
    }

    public var chapterIds: [String] {
        detailsChapters?.ids ?? []
    }

    public var chapterTitles: [String] {
        detailsChapters?.titles ?? []
    }

    public func chapterTitle(at index: Int) -> String? {
        guard detailsChapters?.titles.indices.contains(index) == true else { return nil }
        return detailsChapters?.titles[index]
    }

    public var currentPageNumber: Int { currentIndex + 1 }
    public var totalPages: Int { pages.count }

    public func loadPages() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        preloadTokens.removeAll()
        nextChapterLoadTask?.cancel()
        nextChapterLoadTask = nil
        errorMessage = nil
        isLoadingPages = true
        defer {
            if generation == loadGeneration {
                isLoadingPages = false
            }
        }
        continuousItems = []
        loadedChapterIndices = []
        continuousLoadedImages = [:]

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
        var items: [ContinuousPageItem] = []
        let title = chapterTitle(at: ep) ?? "Chapter \(ep + 1)"
        items.append(ContinuousPageItem(epIndex: ep, pageIndex: 0, imageKey: "", isChapterHeader: true, chapterTitle: title))
        for (pIdx, key) in pageList.enumerated() {
            items.append(ContinuousPageItem(epIndex: ep, pageIndex: pIdx, imageKey: key, isChapterHeader: false, chapterTitle: title))
        }
        continuousItems = items
        loadedChapterIndices.insert(ep)
    }

    /// 连续阅读的 Lazy* 视图可能多次触发 onAppear；把触底请求合并为一个可取消任务。
    private func scheduleNextChapterLoad() {
        guard nextChapterLoadTask == nil else { return }
        nextChapterLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.nextChapterLoadTask = nil }
            await self.loadNextChapterInContinuousMode()
        }
    }

    /// 连续模式：预拉取并追加下一章节
    public func loadNextChapterInContinuousMode() async {
        guard mode.isContinuous, !isLoadingNextChapter else { return }
        let lastEp = continuousItems.last?.epIndex ?? currentEpIndex
        let nextEp = lastEp + 1
        guard chapterIds.indices.contains(nextEp), !loadedChapterIndices.contains(nextEp) else { return }

        isLoadingNextChapter = true
        defer { isLoadingNextChapter = false }

        var nextPages: [String] = []
        let comicType = ComicID.forSource(comic.sourceKey)

        if comic.sourceKey == "local" || LocalManager.shared.isDownloaded(id: comic.id, type: comicType, ep: nextEp + 1, chapters: detailsChapters) {
            nextPages = LocalManager.shared.getImages(id: comic.id, type: comicType, ep: nextEp + 1)
        } else if let source {
            let epId = chapterIds[nextEp]
            if let pages = try? await source.loadComicPages(id: comic.id, ep: epId) {
                nextPages = pages
            }
        }

        guard !nextPages.isEmpty else { return }

        let nextTitle = chapterTitle(at: nextEp) ?? "Chapter \(nextEp + 1)"
        var appendItems: [ContinuousPageItem] = []
        appendItems.append(ContinuousPageItem(epIndex: nextEp, pageIndex: 0, imageKey: "", isChapterHeader: true, chapterTitle: nextTitle))
        for (pIdx, key) in nextPages.enumerated() {
            appendItems.append(ContinuousPageItem(epIndex: nextEp, pageIndex: pIdx, imageKey: key, isChapterHeader: false, chapterTitle: nextTitle))
        }
        continuousItems.append(contentsOf: appendItems)
        loadedChapterIndices.insert(nextEp)
    }

    /// 切换章节（页码归零；历史记录由调用方在合适时机写入）。
    public func switchChapter(to index: Int) async {
        guard chapterIds.indices.contains(index) || (detailsChapters == nil && index == 0) else { return }
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        preloadTokens.removeAll()
        nextChapterLoadTask?.cancel()
        nextChapterLoadTask = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retryTokens.removeAll()
        currentEpIndex = index
        pages = []
        loadedImages.removeAll(keepingCapacity: true)
        continuousLoadedImages.removeAll(keepingCapacity: true)
        currentIndex = 0
        await loadPages()
    }

    // MARK: - 索引与状态

    public func setIndex(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentIndex = index
        trimLoadedImages(around: index)
    }

    public func afterIndexChange(_ index: Int) async {
        guard pages.indices.contains(index) else { return }
        preloadAround(index: index)
        recordHistory()
    }

    public func onContinuousItemVisible(_ item: ContinuousPageItem) {
        if !item.isChapterHeader {
            if currentEpIndex != item.epIndex {
                currentEpIndex = item.epIndex
                if let chPages = getChapterPages(for: item.epIndex) {
                    pages = chPages
                }
            }
            currentIndex = item.pageIndex
            trimContinuousImages(around: item.id)
            recordHistory()
        }
        if let last = continuousItems.last, item.epIndex >= last.epIndex, item.pageIndex >= max(0, pages.count - 3) {
            scheduleNextChapterLoad()
        }
    }

    private func getChapterPages(for ep: Int) -> [String]? {
        let matching = continuousItems.filter { $0.epIndex == ep && !$0.isChapterHeader }
        return matching.isEmpty ? nil : matching.map(\.imageKey)
    }

    public func hasChapter(offset: Int) -> Bool {
        chapterIds.indices.contains(currentEpIndex + offset)
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

    private func trimContinuousImages(around itemID: String) {
        guard let index = continuousItems.firstIndex(where: { $0.id == itemID }) else { return }
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
