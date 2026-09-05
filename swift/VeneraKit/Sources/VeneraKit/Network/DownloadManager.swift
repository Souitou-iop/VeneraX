import Foundation

/// 下载管理器（对齐原版 local.dart 中的下载队列管理与持久化）。
public final class DownloadManager: @unchecked Sendable {
    public static let shared = DownloadManager()

    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()
    public private(set) var downloadingTasks: [DownloadTask] = []

    private var tasksFilePath: String {
        AppPaths.join(AppPaths.dataPath, "downloading_tasks.json")
    }

    public enum QueueResult: Sendable, Equatable { case completed, cancelled, partiallyCancelled }
    private var queueID = UUID().uuidString
    private var completedCount = 0
    private var cancelledCount = 0

    /// Capture membership and terminal outcome under the same lock. Never infer
    /// completion from a throttled progress observer.
    public func activitySnapshot() -> (id: String, tasks: [DownloadTask], result: QueueResult?) {
        lock.lock()
        defer { lock.unlock() }
        let result: QueueResult? = if !downloadingTasks.isEmpty || completedCount + cancelledCount == 0 {
            nil
        } else if cancelledCount == 0 { .completed }
        else if completedCount == 0 { .cancelled }
        else { .partiallyCancelled }
        return (queueID, downloadingTasks, result)
    }

    private var saveTask: Task<Void, Never>?

    public init() {
        restoreDownloadingTasks()
    }

    public var maxParallelDownloads: Int {
        AppData.shared.settings["maxParallelDownloads"].intValue ?? 2
    }

    public func isDownloading(id: String, type: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return downloadingTasks.contains { $0.id == id && $0.comicType == type }
    }

    public func addTask(_ task: DownloadTask) {
        lock.lock()
        guard !downloadingTasks.contains(where: { $0.id == task.id && $0.comicType == task.comicType }) else {
            lock.unlock()
            return
        }
        if downloadingTasks.isEmpty {
            queueID = UUID().uuidString
            completedCount = 0
            cancelledCount = 0
        }
        downloadingTasks.append(task)
        lock.unlock()
        task.resume()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func removeTask(_ task: DownloadTask) {
        lock.lock()
        let previousCount = downloadingTasks.count
        downloadingTasks.removeAll { $0 === task }
        cancelledCount += previousCount - downloadingTasks.count
        lock.unlock()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func pauseTask(_ task: DownloadTask) {
        task.userPaused = true
        task.pause()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func resumeTask(_ task: DownloadTask) {
        task.userPaused = false
        task.autoRetryCount = 0
        task.resume()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func pauseAll() {
        lock.lock()
        for task in downloadingTasks {
            task.userPaused = true
            if !task.isPaused {
                task.pause()
            }
        }
        lock.unlock()
        onChange.emit(())
        saveCurrentDownloadingTasks()
    }

    public func resumeAll() {
        lock.lock()
        for task in downloadingTasks {
            task.userPaused = false
            task.autoRetryCount = 0
        }
        lock.unlock()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func cancelAll() {
        lock.lock()
        let tasks = downloadingTasks
        cancelledCount += tasks.count
        downloadingTasks.removeAll()
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
        onChange.emit(())
        saveCurrentDownloadingTasks()
    }

    public func moveToFirst(_ task: DownloadTask) {
        lock.lock()
        if let idx = downloadingTasks.firstIndex(where: { $0.id == task.id && $0.comicType == task.comicType }), idx > 0 {
            let item = downloadingTasks.remove(at: idx)
            downloadingTasks.insert(item, at: 0)
        }
        lock.unlock()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func reorderTask(from: Int, to: Int) {
        lock.lock()
        guard downloadingTasks.indices.contains(from) else {
            lock.unlock()
            return
        }
        let item = downloadingTasks.remove(at: from)
        let insertIndex = min(to, downloadingTasks.count)
        downloadingTasks.insert(item, at: insertIndex)
        lock.unlock()
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func completeTask(_ task: DownloadTask) {
        lock.lock()
        // A late completion after cancellation must not resurrect a local comic.
        guard downloadingTasks.contains(where: { $0 === task }) else {
            lock.unlock()
            return
        }
        downloadingTasks.removeAll { $0 === task }
        completedCount += 1
        lock.unlock()

        LocalManager.shared.add(task.toLocalComic())
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func onTaskError(_ task: DownloadTask) {
        onChange.emit(())
        saveCurrentDownloadingTasks()
        advanceQueue()
    }

    public func advanceQueue() {
        let limit = maxParallelDownloads
        var runningCount = 0
        lock.lock()
        let tasks = downloadingTasks
        lock.unlock()

        for t in tasks {
            if !t.isPaused && !t.isError {
                runningCount += 1
            }
        }

        for t in tasks {
            if runningCount >= limit { break }
            if t.isPaused && !t.userPaused && !t.isError {
                t.resume()
                runningCount += 1
            }
        }
    }

    // MARK: - 持久化与恢复

    public func scheduleSaveDownloadingTasks() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveCurrentDownloadingTasks()
        }
    }

    public func saveCurrentDownloadingTasks() {
        lock.lock()
        let tasks = downloadingTasks
        lock.unlock()

        let array = tasks.map { $0.toJson() }
        let jsonStr = (try? JSON.array(array).encodedString()) ?? "[]"
        try? FileIO.writeStringAtomic(tasksFilePath, jsonStr)
    }

    public func restoreDownloadingTasks() {
        guard let text = try? String(contentsOfFile: tasksFilePath, encoding: .utf8),
              let json = JSON.decode(text),
              let list = json.arrayValue else {
            return
        }

        var restored: [DownloadTask] = []
        for item in list {
            if let task = DownloadTask.fromJson(item) {
                restored.append(task)
            }
        }

        lock.lock()
        downloadingTasks = restored
        lock.unlock()

        // 延迟自动恢复先前正在运行的任务
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.advanceQueue()
        }
    }
}
