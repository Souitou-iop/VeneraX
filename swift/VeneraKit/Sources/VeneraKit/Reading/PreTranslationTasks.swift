import Foundation

/// A selected chapter in a background pre-translation task.
///
/// `done + failed` is always a contiguous processed prefix. This invariant is
/// the restart checkpoint: work resumes at the first page after that prefix.
public struct PreTranslationTask: Identifiable, Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case running, paused, completed, cancelled, failed
    }

    public struct Chapter: Codable, Sendable, Equatable {
        /// Chapter index in the flattened `ComicChapters` collection.
        public let epIndex: Int
        /// Source chapter id passed to `loadComicPages`.
        public let eid: String
        public let title: String
        /// Resolved page count. Zero means that the page list is unresolved.
        public var total: Int
        /// Successfully processed pages in the committed prefix.
        public var done: Int
        /// Failed pages in the committed prefix.
        public var failed: Int
        /// Page indices that failed after the page list was successfully resolved.
        public var failedPages: [Int]
        /// Distinguishes a chapter-list failure from a failure of page zero.
        /// Optional for backward-compatible decoding of v1 persisted tasks.
        public var pageListFailed: Bool?

        public var hasPageListFailure: Bool { pageListFailed == true }

        public init(
            epIndex: Int,
            eid: String,
            title: String,
            total: Int = 0,
            done: Int = 0,
            failed: Int = 0,
            failedPages: [Int] = [],
            pageListFailed: Bool? = nil
        ) {
            self.epIndex = epIndex
            self.eid = eid
            self.title = title
            self.total = total
            self.done = done
            self.failed = failed
            self.failedPages = failedPages
            self.pageListFailed = pageListFailed
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
    /// Current chapter/batch description. It is display-only and safe to discard.
    public var phase: String
    public var error: String?

    public var isRunning: Bool { status == .running }
    public var isPaused: Bool { status == .paused }
    public var isActive: Bool { isRunning || isPaused }

    public var hasFailures: Bool {
        chapters.contains { $0.hasPageListFailure || !$0.failedPages.isEmpty }
    }

    public var total: Int { chapters.reduce(0) { $0 + $1.total } }
    public var done: Int { chapters.reduce(0) { $0 + $1.done } }
    public var failed: Int {
        chapters.reduce(0) { $0 + $1.failed + ($1.hasPageListFailure ? 1 : 0) }
    }

    /// Chapter-weighted progress. An unresolved chapter contributes zero.
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

/// Durable pre-translation queue.
///
/// Active tasks persist a contiguous per-chapter checkpoint. Tasks interrupted
/// by process termination remain `running` and are resumed after comic sources
/// finish loading. Paused tasks remain paused across launches.
public final class PreTranslationTaskManager: @unchecked Sendable {
    public static let shared = PreTranslationTaskManager()
    public nonisolated(unsafe) static var overridePersistenceKey: String?
    public let onChange = CallbackRegistry<Void>()

    private enum RunMode { case forward, failedOnly }

    private struct PageOutcome: Sendable {
        let index: Int
        let succeeded: Bool
    }

    private let lock = NSLock()
    private let persistenceKey: String
    private let historyLimit = 50
    private var tasks: [PreTranslationTask]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var lastProgressPersist = Date.distantPast
    private var lastProgressNotification = Date.distantPast

    private convenience init() {
        self.init(persistenceKey: Self.overridePersistenceKey ?? "venera.preTranslationTasks.v1")
    }

    /// Internal initializer used by lifecycle tests with an isolated store.
    init(persistenceKey: String) {
        self.persistenceKey = persistenceKey
        let data = UserDefaults.standard.data(forKey: persistenceKey)
        tasks = (try? JSONDecoder().decode([PreTranslationTask].self, from: data ?? Data())) ?? []
        // Runtime phase text is not a checkpoint. A persisted running task is
        // intentionally kept running so startup can resume it after sources load.
        tasks = tasks.map { task in
            var restored = task
            if restored.isActive { restored.phase = "" }
            return restored
        }
    }

    public func allTasks() -> [PreTranslationTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    @discardableResult
    public func start(
        comic: Comic,
        source: ComicSource,
        chapters: ComicChapters,
        epIndices: [Int]
    ) -> PreTranslationTask? {
        let ids = chapters.ids
        let titles = chapters.titles
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
        guard !tasks.contains(where: \.isActive) else {
            lock.unlock()
            return nil
        }
        tasks.insert(task, at: 0)
        trimLocked()
        persistLocked()
        lock.unlock()
        onChange.emit(())

        launch(taskID: task.id, source: source, comic: comic, mode: .forward)
        return task
    }

    /// Starts persisted running jobs after comic sources have loaded.
    public func resumePendingTasks() {
        let ids: [String]
        lock.lock()
        ids = tasks.filter(\.isRunning).map(\.id)
        lock.unlock()
        for id in ids { launchPersisted(taskID: id, mode: .forward) }
    }

    public func pause(id: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else {
            lock.unlock()
            return
        }
        tasks[index].status = .paused
        tasks[index].phase = ""
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    @discardableResult
    public func resume(id: String) -> Bool {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isPaused }) else {
            lock.unlock()
            return false
        }
        tasks[index].status = .running
        tasks[index].finishedAt = nil
        tasks[index].error = nil
        persistLocked()
        let hasJob = jobs[id] != nil
        lock.unlock()
        onChange.emit(())
        if !hasJob { launchPersisted(taskID: id, mode: .forward) }
        return true
    }

    /// Retries page-list failures as complete chapters and page failures exactly.
    @discardableResult
    public func retryFailed(id: String) -> Bool {
        lock.lock()
        guard !tasks.contains(where: \.isActive),
              let index = tasks.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        var task = tasks[index]
        guard task.hasFailures else {
            lock.unlock()
            return false
        }
        task.status = .running
        task.finishedAt = nil
        task.error = nil
        task.phase = ""
        tasks[index] = task
        persistLocked()
        lock.unlock()
        onChange.emit(())
        launchPersisted(taskID: id, mode: .failedOnly)
        return true
    }

    public func cancel(id: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isActive }) else {
            lock.unlock()
            return
        }
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
        tasks.removeAll { !$0.isActive }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    /// Forces the latest in-memory prefix to disk when the app backgrounds.
    public func checkpoint() {
        lock.lock()
        persistLocked()
        lastProgressPersist = Date()
        lock.unlock()
    }

    // MARK: - Job lifecycle

    private func launchPersisted(taskID: String, mode: RunMode) {
        let snapshot: PreTranslationTask?
        lock.lock()
        snapshot = tasks.first(where: { $0.id == taskID && $0.isRunning })
        lock.unlock()
        guard let task = snapshot else { return }
        guard let source = ComicSourceManager.shared.find(task.sourceKey) else {
            finish(id: taskID, status: .failed, error: "Source not found")
            return
        }
        let comic = Comic(
            id: task.cid,
            title: task.title,
            cover: task.cover,
            subtitle: "",
            sourceKey: task.sourceKey
        )
        launch(taskID: taskID, source: source, comic: comic, mode: mode)
    }

    /// Creates and records the job while holding the same lock used by cancel.
    /// The new task cannot observe manager state until its entry exists in jobs.
    private func launch(taskID: String, source: ComicSource, comic: Comic, mode: RunMode) {
        lock.lock()
        guard jobs[taskID] == nil,
              let task = tasks.first(where: { $0.id == taskID && $0.isRunning }) else {
            lock.unlock()
            return
        }
        let job = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.process(task: task, comic: comic, source: source, mode: mode)
        }
        jobs[taskID] = job
        lock.unlock()
    }

    private func process(task: PreTranslationTask, comic: Comic, source: ComicSource, mode: RunMode) async {
        var chapterStates = task.chapters

        for position in chapterStates.indices {
            guard await waitUntilRunnable(id: task.id) else { return }
            var state = chapterStates[position]
            if mode == .failedOnly, !state.hasPageListFailure, state.failedPages.isEmpty { continue }

            setPhase(id: task.id, text: state.title)
            guard let pageList = try? await source.loadComicPages(id: comic.id, ep: state.eid),
                  !pageList.isEmpty else {
                // A chapter-list failure is not page-zero failure. Keeping total
                // at zero forces a complete re-resolution and retry next time.
                state.total = 0
                state.done = 0
                state.failed = 0
                state.failedPages = []
                state.pageListFailed = true
                chapterStates[position] = state
                update(id: task.id, chapters: chapterStates, forceCheckpoint: true)
                continue
            }

            let previousTotal = state.total
            let pageListChanged = previousTotal > 0 && previousTotal != pageList.count
            if pageListChanged {
                // The source changed its page list. Re-evaluate the chapter from
                // the beginning; already rendered cache entries still short-circuit.
                state.done = 0
                state.failed = 0
                state.failedPages = []
            }
            let wasPageListFailure = state.hasPageListFailure
            state.total = pageList.count
            state.pageListFailed = false
            chapterStates[position] = state
            update(id: task.id, chapters: chapterStates, forceCheckpoint: wasPageListFailure)

            let retryOnlyExistingPages = mode == .failedOnly && !wasPageListFailure && !pageListChanged
            let indices: [Int]
            if retryOnlyExistingPages {
                indices = state.failedPages.filter { pageList.indices.contains($0) }.sorted()
            } else {
                let start = min(max(state.done + state.failed, 0), pageList.count)
                indices = Array(pageList.indices.dropFirst(start))
            }
            guard !indices.isEmpty else { continue }

            let concurrency = translationConcurrency
            for batchStart in stride(from: 0, to: indices.count, by: concurrency) {
                guard await waitUntilRunnable(id: task.id) else { return }
                let batch = Array(indices[batchStart..<min(batchStart + concurrency, indices.count)])
                let firstDisplay = (batch.first ?? 0) + 1
                let lastDisplay = (batch.last ?? 0) + 1
                setPhase(id: task.id, text: "\(state.title) · \(firstDisplay)-\(lastDisplay)/\(pageList.count)")

                let outcomes = await processBatch(
                    indices: batch,
                    pageList: pageList,
                    comic: comic,
                    chapter: state,
                    source: source
                )
                guard isActive(id: task.id) else { return }

                state = chapterStates[position]
                for outcome in outcomes.sorted(by: { $0.index < $1.index }) {
                    if retryOnlyExistingPages {
                        guard state.failedPages.contains(outcome.index) else { continue }
                        if outcome.succeeded {
                            state.failedPages.removeAll { $0 == outcome.index }
                            state.failed = state.failedPages.count
                            state.done += 1
                        }
                    } else if outcome.succeeded {
                        state.done += 1
                    } else {
                        if !state.failedPages.contains(outcome.index) {
                            state.failedPages.append(outcome.index)
                        }
                        state.failed = state.failedPages.count
                    }
                }
                chapterStates[position] = state
                // Commit only complete batches. A terminated process redoes at
                // most one small batch, whose successful translations are cached.
                update(id: task.id, chapters: chapterStates)
            }
        }

        guard currentStatus(id: task.id) == .running else { return }
        let latest = taskSnapshot(id: task.id)
        let finalStatus: PreTranslationTask.Status = {
            guard let latest else { return .failed }
            return latest.hasFailures && latest.done == 0 ? .failed : .completed
        }()
        finish(id: task.id, status: finalStatus)
    }

    private func processBatch(
        indices: [Int],
        pageList: [String],
        comic: Comic,
        chapter: PreTranslationTask.Chapter,
        source: ComicSource
    ) async -> [PageOutcome] {
        let sourceLanguage = AppData.shared.settings["imageTranslationSource"].stringValue ?? "auto"
        let targetLanguage = AppData.shared.settings["imageTranslationTarget"].stringValue ?? "zh"

        return await withTaskGroup(of: PageOutcome.self, returning: [PageOutcome].self) { group in
            for pageIndex in indices {
                let imageKey = pageList[pageIndex]
                group.addTask {
                    if Task.isCancelled { return PageOutcome(index: pageIndex, succeeded: false) }
                    let translationKey = "\(comic.sourceKey)/\(comic.id)/\(chapter.eid)/\(imageKey)"
                    let data = await ImageDownloader.shared.load(
                        imageKey: imageKey,
                        sourceKey: comic.sourceKey,
                        cid: comic.id,
                        eid: chapter.eid,
                        source: source
                    )
                    do {
                        guard let data else { throw ImageTranslationService.ServiceError.invalidImage }
                        _ = try await ImageTranslationService.shared.translate(
                            imageData: data,
                            cacheKey: translationKey,
                            sourceLanguage: sourceLanguage,
                            targetLanguage: targetLanguage
                        )
                        return PageOutcome(index: pageIndex, succeeded: true)
                    } catch ImageTranslationService.ServiceError.noText {
                        // A valid text-free page is fully processed, not failed.
                        return PageOutcome(index: pageIndex, succeeded: true)
                    } catch {
                        return PageOutcome(index: pageIndex, succeeded: false)
                    }
                }
            }
            var results: [PageOutcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
    }

    private var translationConcurrency: Int {
        let image = AppData.shared.settings["imageTranslationImageConcurrency"].intValue ?? 3
        let llm = AppData.shared.settings["imageTranslationLlmConcurrency"].intValue ?? 2
        return min(max(min(image, llm), 1), 4)
    }

    private func waitUntilRunnable(id: String) async -> Bool {
        while !Task.isCancelled {
            switch currentStatus(id: id) {
            case .running:
                return true
            case .paused:
                try? await Task.sleep(for: .milliseconds(250))
            default:
                return false
            }
        }
        return false
    }

    // MARK: - State and persistence

    private func currentStatus(id: String) -> PreTranslationTask.Status? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.first(where: { $0.id == id })?.status
    }

    private func isActive(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks.first(where: { $0.id == id })?.isActive == true
    }

    private func taskSnapshot(id: String) -> PreTranslationTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.first(where: { $0.id == id })
    }

    private func update(id: String, chapters: [PreTranslationTask.Chapter], forceCheckpoint: Bool = false) {
        let shouldNotify: Bool
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isActive }) else {
            lock.unlock()
            return
        }
        tasks[index].chapters = chapters
        let now = Date()
        if forceCheckpoint || now.timeIntervalSince(lastProgressPersist) >= 1 {
            persistLocked()
            lastProgressPersist = now
        }
        shouldNotify = forceCheckpoint || now.timeIntervalSince(lastProgressNotification) >= 0.25
        if shouldNotify { lastProgressNotification = now }
        lock.unlock()
        if shouldNotify { onChange.emit(()) }
    }

    private func setPhase(id: String, text: String) {
        let shouldNotify: Bool
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isActive }) else {
            lock.unlock()
            return
        }
        tasks[index].phase = text
        let now = Date()
        shouldNotify = now.timeIntervalSince(lastProgressNotification) >= 0.25
        if shouldNotify { lastProgressNotification = now }
        lock.unlock()
        if shouldNotify { onChange.emit(()) }
    }

    private func finish(id: String, status: PreTranslationTask.Status, error: String? = nil) {
        lock.lock()
        jobs.removeValue(forKey: id)
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else {
            lock.unlock()
            return
        }
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
        // Never discard an active task when trimming old history.
        let active = tasks.filter(\.isActive)
        let history = tasks.filter { !$0.isActive }
        tasks = active + Array(history.prefix(max(historyLimit - active.count, 0)))
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
}
