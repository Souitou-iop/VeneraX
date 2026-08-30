import Foundation

/// 在线源目录批量更新任务（对齐 Flutter `comic_source_update_tasks.dart`）。
/// 任务只保存摘要和每源结果，不复制源脚本内容，避免任务历史占用不受控内存。
public struct SourceUpdateTaskDetail: Codable, Sendable, Identifiable {
    public var id: String { sourceKey }
    public let sourceKey: String
    public let sourceName: String
    public let oldVersion: String
    public let targetVersion: String?
    public var newVersion: String?
    public var status: String
    public var error: String?

    public init(
        sourceKey: String,
        sourceName: String,
        oldVersion: String,
        targetVersion: String? = nil,
        newVersion: String? = nil,
        status: String = "pending",
        error: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.oldVersion = oldVersion
        self.targetVersion = targetVersion
        self.newVersion = newVersion
        self.status = status
        self.error = error
    }
}

public struct SourceUpdateTask: Identifiable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case completed
        case cancelled
        case failed
    }

    public let id: String
    public let createdAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var total: Int
    public var checked: Int
    public var updated: Int
    public var failed: Int
    public var details: [SourceUpdateTaskDetail]

    public var progress: Double {
        total > 0 ? min(1, Double(checked) / Double(total)) : 0
    }

    public init(
        id: String,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        status: Status = .running,
        total: Int = 0,
        checked: Int = 0,
        updated: Int = 0,
        failed: Int = 0,
        details: [SourceUpdateTaskDetail] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.status = status
        self.total = total
        self.checked = checked
        self.updated = updated
        self.failed = failed
        self.details = details
    }
}

public final class SourceUpdateManager: @unchecked Sendable {
    public static let shared = SourceUpdateManager()

    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()
    private let historyLimit = 50
    private let persistenceKey = "venera.sourceUpdateTasks.v1"
    private var tasks: [SourceUpdateTask]
    private var jobs: [String: Task<Void, Never>] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode([SourceUpdateTask].self, from: data) {
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

    public func allTasks() -> [SourceUpdateTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    public func activeTasks() -> [SourceUpdateTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.status == .running }
    }

    public func clearHistory() {
        lock.lock()
        tasks.removeAll { $0.status != .running }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    /// 使用最近一次目录检查发现的更新启动批量更新。
    @discardableResult
    public func startAvailableUpdates() -> SourceUpdateTask? {
        lock.lock()
        if let existing = tasks.first(where: { $0.status == .running }) {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let updates = SourceCatalogManager.shared.availableUpdates
        let catalog = SourceCatalogManager.shared.catalogSources
        let installed = ComicSourceManager.shared.all()
        let details = updates.keys.sorted().compactMap { key -> SourceUpdateTaskDetail? in
            guard let item = catalog.first(where: { $0.key == key }),
                  let current = installed.first(where: { $0.key == key }) else { return nil }
            return SourceUpdateTaskDetail(
                sourceKey: key,
                sourceName: current.name,
                oldVersion: current.version,
                targetVersion: item.version
            )
        }
        guard !details.isEmpty else { return nil }

        let task = SourceUpdateTask(
            id: UUID().uuidString,
            total: details.count,
            details: details
        )
        lock.lock()
        tasks.insert(task, at: 0)
        if tasks.count > historyLimit {
            tasks.removeLast(tasks.count - historyLimit)
        }
        let job = Task { [weak self] in
            guard let self else { return }
            await self.run(taskID: task.id, details: details, catalog: catalog)
        }
        jobs[task.id] = job
        persistLocked()
        lock.unlock()
        onChange.emit(())
        return task
    }

    public func cancel(id: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else {
            lock.unlock()
            return
        }
        tasks[index].status = .cancelled
        tasks[index].finishedAt = Date()
        let job = jobs.removeValue(forKey: id)
        persistLocked()
        lock.unlock()
        job?.cancel()
        onChange.emit(())
    }

    private func update(
        taskID: String,
        checked: Int,
        updated: Int,
        failed: Int,
        detailIndex: Int,
        detail: SourceUpdateTaskDetail
    ) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.status == .running }) else {
            lock.unlock()
            return
        }
        tasks[index].checked = checked
        tasks[index].updated = updated
        tasks[index].failed = failed
        if tasks[index].details.indices.contains(detailIndex) {
            tasks[index].details[detailIndex] = detail
        }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func finish(taskID: String, cancelled: Bool) {
        lock.lock()
        jobs.removeValue(forKey: taskID)
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            lock.unlock()
            return
        }
        if tasks[index].status == .running {
            tasks[index].status = cancelled ? .cancelled : (tasks[index].failed > 0 ? .failed : .completed)
            tasks[index].finishedAt = Date()
        }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func run(
        taskID: String,
        details: [SourceUpdateTaskDetail],
        catalog: [CatalogSourceItem]
    ) async {
        var checked = 0
        var updated = 0
        var failed = 0

        for (index, original) in details.enumerated() {
            guard !Task.isCancelled else {
                finish(taskID: taskID, cancelled: true)
                return
            }
            var detail = original
            detail.status = "updating"
            update(taskID: taskID, checked: checked, updated: updated, failed: failed, detailIndex: index, detail: detail)

            guard let item = catalog.first(where: { $0.key == detail.sourceKey }) else {
                detail.status = "failed"
                detail.error = "Source unavailable"
                failed += 1
                checked += 1
                update(taskID: taskID, checked: checked, updated: updated, failed: failed, detailIndex: index, detail: detail)
                continue
            }

            do {
                try await SourceCatalogManager.shared.installSource(from: item)
                detail.status = "updated"
                detail.newVersion = item.version
                updated += 1
            } catch {
                detail.status = "failed"
                detail.error = error.localizedDescription
                failed += 1
            }
            checked += 1
            update(taskID: taskID, checked: checked, updated: updated, failed: failed, detailIndex: index, detail: detail)
        }

        finish(taskID: taskID, cancelled: false)
    }
}
