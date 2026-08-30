import Foundation

/// 跨源漫画迁移管理器（对齐原版 source_migration_tasks.dart 与 source_migration.dart）。
/// 当某个漫画源失效或需要更换源时，将本地收藏/历史记录中的漫画通过同名搜索一键迁移至目标源。
public final class SourceMigrationManager: @unchecked Sendable {
    public static let shared = SourceMigrationManager()

    public struct MigrationTask: Identifiable, Sendable {
        public let id: String
        public let folder: String
        public let sourceKey: String
        public let targetKey: String
        public let createdAt: Date
        public var total: Int
        public var current: Int
        public var migrated: Int
        public var failed: Int
        public var status: Status

        public enum Status: String, Sendable {
            case running = "running"
            case completed = "completed"
            case failed = "failed"
            case cancelled = "cancelled"
        }
    }

    private let lock = NSLock()
    private var tasks: [MigrationTask] = []
    private var jobs: [String: Task<Void, Never>] = [:]
    private let historyLimit = 100
    public let onChange = CallbackRegistry<Void>()

    private init() {}

    public func allTasks() -> [MigrationTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    public func activeTasks() -> [MigrationTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.status == .running }
    }

    public func clearHistory() {
        lock.lock()
        tasks.removeAll { $0.status != .running }
        lock.unlock()
        onChange.emit(())
    }

    private func addTask(_ task: MigrationTask) {
        lock.lock()
        tasks.insert(task, at: 0)
        if tasks.count > historyLimit {
            tasks.removeLast(tasks.count - historyLimit)
        }
        lock.unlock()
        onChange.emit(())
    }

    private func updateTaskProgress(taskId: String, current: Int, success: Bool) {
        lock.lock()
        if let tIdx = tasks.firstIndex(where: { $0.id == taskId && $0.status == .running }) {
            tasks[tIdx].current = current
            if success {
                tasks[tIdx].migrated += 1
            } else {
                tasks[tIdx].failed += 1
            }
            if tasks[tIdx].current >= tasks[tIdx].total {
                tasks[tIdx].status = tasks[tIdx].failed > 0 ? .failed : .completed
            }
        }
        lock.unlock()
        onChange.emit(())
    }

    /// 启动一个跨源迁移任务。
    public func startMigration(
        folder: String,
        sourceKey: String,
        targetKey: String,
        migrateHistory: Bool = true
    ) {
        guard let targetSource = ComicSourceManager.shared.find(targetKey), targetSource.searchAvailable else {
            return
        }

        let allInFolder = LocalFavoritesManager.shared.getComics(folder)
        let sourceComics = allInFolder.filter { item in
            ComicID(id: item.id, type: item.type).sourceKey == sourceKey
        }
        guard !sourceComics.isEmpty else { return }

        lock.lock()
        let alreadyRunning = tasks.contains {
            $0.status == .running &&
            $0.folder == folder &&
            $0.sourceKey == sourceKey &&
            $0.targetKey == targetKey
        }
        lock.unlock()
        guard !alreadyRunning else { return }

        let taskId = UUID().uuidString
        let task = MigrationTask(
            id: taskId,
            folder: folder,
            sourceKey: sourceKey,
            targetKey: targetKey,
            createdAt: Date(),
            total: sourceComics.count,
            current: 0,
            migrated: 0,
            failed: 0,
            status: .running
        )

        addTask(task)

        let job = Task.detached { [weak self] in
            for (index, favItem) in sourceComics.enumerated() {
                guard !Task.isCancelled else { break }
                var success = false
                if let searchResult = try? await targetSource.search(keyword: favItem.name, page: 1, options: [:]),
                   let firstMatch = searchResult.comics.first {
                    guard !Task.isCancelled else { break }

                    let targetType = ComicID.forSource(targetKey)
                    // 1. 替换本地收藏
                    LocalFavoritesManager.shared.removeFavorite(id: favItem.id, type: favItem.type, folder: folder)
                    let newFavItem = FavoriteItem(
                        id: firstMatch.id,
                        name: firstMatch.title,
                        coverPath: firstMatch.cover,
                        author: firstMatch.subtitle,
                        type: targetType,
                        tags: firstMatch.tags
                    )
                    LocalFavoritesManager.shared.addFavorite(folder, newFavItem)

                    // 2. 迁移历史记录
                    if migrateHistory, let oldHistory = HistoryManager.shared.findHistory(id: favItem.id, type: favItem.type) {
                        let newHistory = History(
                            id: firstMatch.id,
                            type: targetType,
                            title: firstMatch.title,
                            subtitle: firstMatch.subtitle,
                            cover: firstMatch.cover,
                            ep: oldHistory.ep,
                            page: oldHistory.page,
                            time: Date(),
                            maxPage: oldHistory.maxPage,
                            readEpisode: oldHistory.readEpisode,
                            hideTime: nil
                        )
                        HistoryManager.shared.addHistory(newHistory)
                    }
                    success = true
                }

                self?.updateTaskProgress(taskId: taskId, current: index + 1, success: success)
            }
            self?.finishJob(taskId: taskId, cancelled: Task.isCancelled)
        }
        lock.lock()
        jobs[taskId] = job
        lock.unlock()
    }

    /// 取消正在运行的迁移任务，并保留可审计的取消状态。
    public func cancelMigration(id: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else {
            lock.unlock()
            return
        }
        tasks[index].status = .cancelled
        let job = jobs[id]
        jobs[id] = nil
        lock.unlock()
        job?.cancel()
        onChange.emit(())
    }

    private func finishJob(taskId: String, cancelled: Bool) {
        lock.lock()
        jobs[taskId] = nil
        if let index = tasks.firstIndex(where: { $0.id == taskId }), tasks[index].status == .running, cancelled {
            tasks[index].status = .cancelled
        }
        lock.unlock()
        onChange.emit(())
    }
}
