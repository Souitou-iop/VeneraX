import Foundation

public struct FollowUpdateProgress: Sendable {
    public let total: Int
    public let current: Int
    public let updated: Int
    public let errors: Int
    public let isRunning: Bool

    public init(total: Int = 0, current: Int = 0, updated: Int = 0, errors: Int = 0, isRunning: Bool = false) {
        self.total = total
        self.current = current
        self.updated = updated
        self.errors = errors
        self.isRunning = isRunning
    }
}

/// 追更检查任务的可持久化摘要。
///
/// Flutter 版把追更检查作为后台任务管理器的一部分；Swift 版不能只在页面里
/// 启动一个临时 Task，否则页面离开后任务没有历史、取消和统一状态。这里保留
/// 轻量任务摘要，正文数据仍然来自收藏库，不把漫画列表复制进任务历史。
public struct FollowUpdateTask: Identifiable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case completed
        case cancelled
        case failed
    }

    public let id: String
    public let manual: Bool
    /// 本次检查覆盖的收藏夹。多收藏夹支持之前的历史记录没有该字段，
    /// 解码为 nil，由 UI 回退为通用文案。
    public var folders: [String]?
    public let createdAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var total: Int
    public var current: Int
    public var updated: Int
    public var errors: Int

    public var progress: Double {
        total > 0 ? min(1, Double(current) / Double(total)) : 0
    }

    public init(
        id: String,
        manual: Bool,
        folders: [String]? = nil,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        status: Status = .running,
        total: Int = 0,
        current: Int = 0,
        updated: Int = 0,
        errors: Int = 0
    ) {
        self.id = id
        self.manual = manual
        self.folders = folders
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.status = status
        self.total = total
        self.current = current
        self.updated = updated
        self.errors = errors
    }
}

/// 追更检查与监控器（对齐原版 follow_updates.dart / follow_update_tasks.dart）。
public final class FollowUpdatesManager: @unchecked Sendable {
    public static let shared = FollowUpdatesManager()

    public let onProgress = CallbackRegistry<FollowUpdateProgress>()
    public let onChange = CallbackRegistry<Void>()

    private let stateLock = NSLock()
    private var checking = false
    private var checkerStarted = false
    private var checkerTask: Task<Void, Never>?
    private var tasks: [FollowUpdateTask]
    private var jobs: [String: Task<Void, Never>] = [:]
    private let persistenceKey = "venera.followUpdateTasks.v1"
    private let historyLimit = 100

    public var isChecking: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return checking
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode([FollowUpdateTask].self, from: data) {
            // 进程重启后没有可恢复的网络 Job；不要把旧的 running 状态伪装成仍在运行。
            tasks = saved.map { task in
                guard task.status == .running else { return task }
                var recovered = task
                recovered.status = .cancelled
                recovered.finishedAt = Date()
                return recovered
            }
        } else {
            tasks = []
        }
    }

    public func allTasks() -> [FollowUpdateTask] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tasks
    }

    public func activeTasks() -> [FollowUpdateTask] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tasks.filter { $0.status == .running }
    }

    public func clearHistory() {
        stateLock.lock()
        tasks.removeAll { $0.status != .running }
        persistLocked()
        stateLock.unlock()
        onChange.emit(())
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func beginChecking() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !checking else { return false }
        checking = true
        return true
    }

    private func finishChecking() {
        stateLock.lock()
        checking = false
        stateLock.unlock()
    }

    public var totalUpdatedCount: Int {
        var count = 0
        for folder in LocalFavoritesManager.shared.getFolders() {
            let items = LocalFavoritesManager.shared.getComics(folder)
            count += items.filter { $0.hasNewUpdate == true }.count
        }
        return count
    }

    public func getAllUpdatedComics() -> [(folder: String, item: FavoriteItem)] {
        var result: [(folder: String, item: FavoriteItem)] = []
        for folder in LocalFavoritesManager.shared.getFolders() {
            let items = LocalFavoritesManager.shared.getComics(folder)
            for item in items where item.hasNewUpdate == true {
                result.append((folder, item))
            }
        }
        return result
    }

    public func markComicRead(id: String, type: Int, folder: String) {
        LocalFavoritesManager.shared.clearNewUpdateFlag(folder: folder, id: id, type: type)
    }

    /// 启动一次覆盖 `folders` 的追更检查。同时只允许一个检查在跑：追更
    /// 范围现在是唯一的用户级设置，运行中再触发会并入当前任务，而不是
    /// 启动一个会写同一批行的重叠检查。重复启动返回运行中的任务摘要。
    @discardableResult
    public func startCheck(folders: [String], manual: Bool) -> FollowUpdateTask? {
        guard !folders.isEmpty else { return nil }

        stateLock.lock()
        if let running = tasks.first(where: { $0.status == .running }) {
            stateLock.unlock()
            return running
        }
        stateLock.unlock()

        guard beginChecking() else { return activeTasks().first }

        // 手动检查忽略上次检查时间；自动检查只查到期的漫画（上游
        // ignoreCheckTime 语义）。收藏夹出现的先后即库内顺序。
        var seen = Set<String>()
        var allComics: [(folder: String, item: FavoriteItem)] = []
        for folder in folders {
            LocalFavoritesManager.shared.makeFollowFolder(folder)
            let items = LocalFavoritesManager.shared.getComics(folder)
            for item in items where item.type != 0 {
                guard seen.insert("\(item.id)@\(item.type)").inserted else { continue }
                if !manual,
                   !FollowUpdateScope.isDue(lastCheck: item.lastCheckTime) {
                    continue
                }
                allComics.append((folder, item))
            }
        }

        let task = FollowUpdateTask(
            id: UUID().uuidString,
            manual: manual,
            folders: folders,
            total: allComics.count
        )

        stateLock.lock()
        tasks.insert(task, at: 0)
        persistLocked()
        let job = Task { [weak self] in
            guard let self else { return }
            await self.run(taskID: task.id, comics: allComics)
        }
        jobs[task.id] = job
        stateLock.unlock()
        onChange.emit(())
        onProgress.emit(FollowUpdateProgress(total: task.total, isRunning: true))
        return task
    }

    /// 按当前追更范围启动检查；范围为空（未配置）时什么都不做。
    @discardableResult
    public func startScopedCheck(manual: Bool) -> FollowUpdateTask? {
        startCheck(folders: FollowUpdateScope.folders, manual: manual)
    }

    /// 用户把某个收藏夹移出追更范围（或删除它）时，取消覆盖它的运行中
    /// 检查——这被视为明确的取消，任务之后不得再继续。
    public func cancelChecks(forFolder folder: String) {
        let ids = allTasks().filter { $0.status == .running && $0.folders?.contains(folder) == true }.map(\.id)
        for id in ids {
            cancelCheck(id: id)
        }
    }

    /// 自动检查的调度器：启动检查（可选）+ 每 10 分钟一跳的周期门。
    /// 周期跳本身很廉价——到不到期由每部漫画的上次检查时间决定，没有
    /// 到期漫画的那一跳不会启动任务。
    public func startChecker() {
        stateLock.lock()
        if checkerStarted {
            stateLock.unlock()
            return
        }
        checkerStarted = true
        stateLock.unlock()

        FollowUpdateScope.migrateLegacyIfNeeded()

        checkerTask = Task { [weak self] in
            guard let self else { return }
            // 启动检查是可选项；刚启动时先让 DataSync/收藏库安顿下来。
            try? await Task.sleep(for: .seconds(5))
            if FollowUpdateScope.checkOnStart {
                await self.runAutomaticCheck()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard FollowUpdateScope.isPastFixedTime(FollowUpdateScope.fixedTime) else { continue }
                await self.runAutomaticCheck()
            }
        }
    }

    private func runAutomaticCheck() async {
        // 备份下载/应用会原位恢复收藏库；等它结束再检查，避免写交错。
        while !DataSyncManager.shared.activeTasks().isEmpty {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        guard !FollowUpdateScope.folders.isEmpty else { return }
        await checkAllFolders(force: false)
    }

    private func job(for id: String) -> Task<Void, Never>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return jobs[id]
    }

    /// 等待一次追更检查完成。保留这个 API 兼容原页面和既有调用方；
    /// 范围为空（未配置）时直接返回。
    public func checkAllFolders(force: Bool = false) async {
        guard let task = startCheck(folders: FollowUpdateScope.folders, manual: force) else { return }
        guard let job = job(for: task.id) else { return }
        await withTaskCancellationHandler(operation: {
            await job.value
        }, onCancel: {
            self.cancelCheck(id: task.id)
        })
    }

    /// 取消任务并保留取消记录；实际网络请求在当前 await 返回后结束。
    public func cancelCheck(id: String) {
        stateLock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else {
            stateLock.unlock()
            return
        }
        tasks[index].status = .cancelled
        tasks[index].finishedAt = Date()
        let job = jobs.removeValue(forKey: id)
        persistLocked()
        stateLock.unlock()
        job?.cancel()
        onChange.emit(())
        onProgress.emit(FollowUpdateProgress(isRunning: false))
    }

    private func updateTask(
        id: String,
        current: Int,
        updated: Int,
        errors: Int
    ) {
        stateLock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else {
            stateLock.unlock()
            return
        }
        tasks[index].current = current
        tasks[index].updated = updated
        tasks[index].errors = errors
        persistLocked()
        let snapshot = tasks[index]
        stateLock.unlock()
        onChange.emit(())
        onProgress.emit(FollowUpdateProgress(
            total: snapshot.total,
            current: snapshot.current,
            updated: snapshot.updated,
            errors: snapshot.errors,
            isRunning: true
        ))
    }

    private func finishTask(id: String, cancelled: Bool) {
        stateLock.lock()
        jobs.removeValue(forKey: id)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            stateLock.unlock()
            finishChecking()
            return
        }
        if tasks[index].status == .running {
            tasks[index].status = cancelled ? .cancelled : (tasks[index].errors > 0 ? .failed : .completed)
            tasks[index].finishedAt = Date()
        }
        let snapshot = tasks[index]
        // 只保留有限历史，避免任务摘要长期增长。
        if tasks.count > historyLimit {
            tasks.removeLast(tasks.count - historyLimit)
        }
        persistLocked()
        stateLock.unlock()
        finishChecking()
        onChange.emit(())
        onProgress.emit(FollowUpdateProgress(
            total: snapshot.total,
            current: snapshot.current,
            updated: snapshot.updated,
            errors: snapshot.errors,
            isRunning: false
        ))
    }

    private func run(
        taskID: String,
        comics: [(folder: String, item: FavoriteItem)]
    ) async {
        var current = 0
        var updated = 0
        var errors = 0

        for (folder, item) in comics {
            guard !Task.isCancelled else {
                finishTask(id: taskID, cancelled: true)
                return
            }

            guard let sourceKey = ComicID(id: item.id, type: item.type).sourceKey,
                  let source = ComicSourceManager.shared.find(sourceKey) else {
                errors += 1
                current += 1
                updateTask(id: taskID, current: current, updated: updated, errors: errors)
                continue
            }

            do {
                let details = try await source.loadComicInfo(id: item.id)
                let newUpdateTime = details.updateTime ?? ""
                let isNew = !newUpdateTime.isEmpty && newUpdateTime != (item.updateTimeMeta ?? item.lastUpdateTime)

                if isNew {
                    LocalFavoritesManager.shared.updateUpdateTime(
                        folder: folder,
                        id: item.id,
                        type: item.type,
                        updateTime: newUpdateTime,
                        hasNewUpdate: true
                    )
                    updated += 1
                } else {
                    LocalFavoritesManager.shared.updateCheckTime(folder: folder, id: item.id, type: item.type)
                }
            } catch {
                if Task.isCancelled {
                    finishTask(id: taskID, cancelled: true)
                    return
                }
                errors += 1
            }

            guard !Task.isCancelled else {
                finishTask(id: taskID, cancelled: true)
                return
            }
            current += 1
            updateTask(id: taskID, current: current, updated: updated, errors: errors)
        }

        finishTask(id: taskID, cancelled: false)
    }
}
