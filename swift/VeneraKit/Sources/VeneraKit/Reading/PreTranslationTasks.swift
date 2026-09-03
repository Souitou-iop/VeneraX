import Foundation

/// 后台预翻译任务（对齐原版 pre_translation_tasks.dart 的任务中心语义，
/// 适配 Swift 的按页翻译管线）。
///
/// 预翻译复用 `ImageTranslationService.translate` 并以阅读器完全相同的
/// cacheKey 调用——预译完成的页面在阅读器中即时呈现，无等待。图片获取
/// 走 `ImageDownloader`（与阅读器同一缓存与去重路径）。
public struct PreTranslationTask: Identifiable, Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case running, completed, cancelled, failed }

    public struct Chapter: Codable, Sendable, Equatable {
        /// 章节在 ComicChapters 中的平铺 0 基索引。
        public let epIndex: Int
        /// 源章节 ID（loadComicPages 的 eid 参数）。
        public let eid: String
        public let title: String
        /// 页数，章节开始时才解析（解析前为 0）。
        public var total: Int
        public var done: Int
        public var failed: Int
        /// 本轮失败的页索引（可重试精确重跑；成功后移除）。
        public var failedPages: [Int]

        public init(epIndex: Int, eid: String, title: String, total: Int = 0, done: Int = 0, failed: Int = 0, failedPages: [Int] = []) {
            self.epIndex = epIndex
            self.eid = eid
            self.title = title
            self.total = total
            self.done = done
            self.failed = failed
            self.failedPages = failedPages
        }
    }

    public let id: String
    public let cid: String
    public let sourceKey: String
    public let title: String
    public let cover: String
    public var chapters: [Chapter]
    public let createdAt: Date
    public var finishedAt: Date?
    public var status: Status
    /// 当前正在处理的章节标题（运行态展示；非持久语义，重载后为空）。
    public var phase: String
    public var error: String?

    public var isRunning: Bool { status == .running }

    /// 是否有可重试的失败页。
    public var hasFailures: Bool { chapters.contains { !$0.failedPages.isEmpty } }

    public var total: Int { chapters.reduce(0) { $0 + $1.total } }
    public var done: Int { chapters.reduce(0) { $0 + $1.done } }
    public var failed: Int { chapters.reduce(0) { $0 + $1.failed } }

    /// 章节加权进度（对齐原版选择）：每章等权 1/N，未开始的章（total==0）
    /// 计 0%。保持百分比代表全部所选章节且单调，而不是只统计已开始章节
    /// 的页数比例（那会随新章解析 total 而跳动）。
    public var progress: Double {
        guard !chapters.isEmpty else { return 0 }
        var sum = 0.0
        for chapter in chapters where chapter.total > 0 {
            sum += min(Double(chapter.done + chapter.failed) / Double(chapter.total), 1)
        }
        return sum / Double(chapters.count)
    }

    public init(
        id: String = UUID().uuidString,
        cid: String,
        sourceKey: String,
        title: String,
        cover: String,
        chapters: [Chapter],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.cid = cid
        self.sourceKey = sourceKey
        self.title = title
        self.cover = cover
        self.chapters = chapters
        self.createdAt = createdAt
        self.finishedAt = nil
        self.status = .running
        self.phase = ""
        self.error = nil
    }
}

/// 管理后台预翻译任务。结构对齐其他任务管理器（运行/历史/持久化），
/// 任务中心以同样方式渲染。一次只允许一个运行中任务（与导出管理器一致）。
public final class PreTranslationTaskManager: @unchecked Sendable {
    public static let shared = PreTranslationTaskManager()
    public nonisolated(unsafe) static var overridePersistenceKey: String?
    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()
    /// init 时快照一次（测试可在首次访问 shared 前注入 override）。
    private let persistenceKey: String
    private let historyLimit = 50
    private var tasks: [PreTranslationTask]
    private var jobs: [String: Task<Void, Never>] = [:]

    private init() {
        persistenceKey = Self.overridePersistenceKey ?? "venera.preTranslationTasks.v1"
        let data = UserDefaults.standard.data(forKey: persistenceKey)
        tasks = (try? JSONDecoder().decode([PreTranslationTask].self, from: data ?? Data())) ?? []
        // 重载恢复：上次运行中的任务标记为取消（无法安全续跑 detached job）。
        tasks = tasks.map { task in
            guard task.isRunning else { return task }
            var recovered = task
            recovered.status = .cancelled
            recovered.finishedAt = Date()
            recovered.phase = ""
            return recovered
        }
        persistLocked()
    }

    public func allTasks() -> [PreTranslationTask] { lock.lock(); defer { lock.unlock() }; return tasks }

    /// 启动预翻译。章节页列表在任务内解析；失败页记录索引可精确重试。
    @discardableResult
    public func start(
        comic: Comic,
        source: ComicSource,
        chapters: ComicChapters,
        epIndices: [Int]
    ) -> PreTranslationTask? {
        let ids = chapters.ids
        let titles = chapters.titles
        // 过滤有效索引并去重保序。
        var seen = Set<Int>()
        let valid = epIndices.filter { ids.indices.contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return nil }
        let chapterModels = valid.map { ep in
            PreTranslationTask.Chapter(
                epIndex: ep,
                eid: ids[ep],
                title: titles.indices.contains(ep) ? titles[ep] : "Chapter \(ep + 1)"
            )
        }
        let task = PreTranslationTask(
            cid: comic.id,
            sourceKey: comic.sourceKey,
            title: comic.title,
            cover: comic.cover,
            chapters: chapterModels
        )
        lock.lock()
        guard !tasks.contains(where: \.isRunning) else { lock.unlock(); return nil }
        tasks.insert(task, at: 0)
        trimLocked()
        persistLocked()
        lock.unlock()
        onChange.emit(())
        jobs[task.id] = Task.detached(priority: .utility) { [weak self] in
            await self?.run(task: task, comic: comic, source: source, chapters: chapters)
        }
        return task
    }

    /// 重试失败页：只重跑各章记录的失败索引，成功页不动。
    /// 没有失败页或已有任务在运行时返回 false。
    @discardableResult
    public func retryFailed(id: String) -> Bool {
        lock.lock()
        guard !tasks.contains(where: \.isRunning),
              let index = tasks.firstIndex(where: { $0.id == id }) else { lock.unlock(); return false }
        var task = tasks[index]
        guard task.hasFailures else { lock.unlock(); return false }
        task.status = .running
        task.finishedAt = nil
        task.error = nil
        task.phase = ""
        tasks[index] = task
        persistLocked()
        lock.unlock()
        onChange.emit(())
        guard let comicSource = ComicSourceManager.shared.find(task.sourceKey) else {
            finish(id: id, status: .failed, error: "Source not found")
            return true
        }
        let comic = Comic(id: task.cid, title: task.title, cover: task.cover, subtitle: "", sourceKey: task.sourceKey)
        jobs[task.id] = Task.detached(priority: .utility) { [weak self] in
            await self?.retry(task: task, source: comicSource, comic: comic)
        }
        return true
    }

    public func cancel(id: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }
        tasks[index].status = .cancelled
        tasks[index].finishedAt = Date()
        tasks[index].phase = ""
        let job = jobs.removeValue(forKey: id)
        persistLocked()
        lock.unlock()
        job?.cancel()
        onChange.emit(())
    }

    public func clearHistory() {
        lock.lock()
        tasks.removeAll { !$0.isRunning }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    // MARK: - 执行

    private func run(task: PreTranslationTask, comic: Comic, source: ComicSource, chapters: ComicChapters) async {
        await process(task: task, comic: comic, source: source, mode: .full)
    }

    private func retry(task: PreTranslationTask, source: ComicSource, comic: Comic) async {
        await process(task: task, comic: comic, source: source, mode: .failedOnly)
    }

    private enum RunMode { case full, failedOnly }

    private func process(task: PreTranslationTask, comic: Comic, source: ComicSource, mode: RunMode) async {
        let sourceLanguage = AppData.shared.settings["imageTranslationSource"].stringValue ?? "auto"
        let targetLanguage = AppData.shared.settings["imageTranslationTarget"].stringValue ?? "zh"
        var chapterStates = task.chapters

        for (position, chapter) in chapterStates.enumerated() {
            if Task.isCancelled { break }
            // 重试模式：没有失败页的章直接跳过（也不解析页列表，避免把
            // 无关章节误标为失败）。
            if mode == .failedOnly, chapter.failedPages.isEmpty { continue }
            setPhase(id: task.id, chapterTitle: chapter.title)

            // 解析页列表（与阅读器 loadComicPages 完全同源）。
            guard let pageList = try? await source.loadComicPages(id: comic.id, ep: chapter.eid),
                  !pageList.isEmpty else {
                // 页列表解析失败记为可重试失败（占位 1 页）。
                var state = chapterStates[position]
                state.total = max(state.total, 1)
                state.failedPages = mode == .full ? [0] : (state.failedPages.isEmpty ? [0] : state.failedPages)
                state.failed = state.failedPages.count
                chapterStates[position] = state
                update(id: task.id, chapters: chapterStates)
                continue
            }
            var state = chapterStates[position]
            state.total = pageList.count
            chapterStates[position] = state
            update(id: task.id, chapters: chapterStates)

            let indices = mode == .full
                ? Array(pageList.indices)
                : chapter.failedPages.filter { pageList.indices.contains($0) }
            for pageIndex in indices {
                if Task.isCancelled { break }
                let imageKey = pageList[pageIndex]
                // 与阅读器 translationCacheKey(for:) 完全一致，预译结果即时命中。
                let translationKey = "\(comic.sourceKey)/\(comic.id)/\(chapter.eid)/\(imageKey)"
                let data = await ImageDownloader.shared.load(
                    imageKey: imageKey,
                    sourceKey: comic.sourceKey,
                    cid: comic.id,
                    eid: chapter.eid,
                    source: source
                )
                state = chapterStates[position]
                do {
                    guard let data else { throw ImageTranslationService.ServiceError.invalidImage }
                    // noText 视为完成：该页已处理，只是没有可翻译内容。
                    _ = try await ImageTranslationService.shared.translate(
                        imageData: data,
                        cacheKey: translationKey,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                    state.done += 1
                    state.failedPages.removeAll { $0 == pageIndex }
                } catch {
                    if !state.failedPages.contains(pageIndex) { state.failedPages.append(pageIndex) }
                }
                state.failed = state.failedPages.count
                chapterStates[position] = state
                update(id: task.id, chapters: chapterStates)
            }
        }

        if Task.isCancelled {
            finish(id: task.id, status: .cancelled)
        } else {
            finish(id: task.id, status: .completed)
        }
    }

    // MARK: - 状态更新（锁内合并读改写）

    private func update(id: String, chapters: [PreTranslationTask.Chapter]) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }
        tasks[index].chapters = chapters
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func setPhase(id: String, chapterTitle: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }
        tasks[index].phase = chapterTitle
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func finish(id: String, status: PreTranslationTask.Status, error: String? = nil) {
        lock.lock()
        jobs.removeValue(forKey: id)
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }
        tasks[index].status = status
        tasks[index].finishedAt = Date()
        tasks[index].phase = ""
        tasks[index].error = error
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func trimLocked() {
        guard tasks.count > historyLimit else { return }
        tasks.removeLast(tasks.count - historyLimit)
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
}
