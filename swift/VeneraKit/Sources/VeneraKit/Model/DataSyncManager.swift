import Foundation

/// WebDAV 数据同步任务摘要，避免同步操作只存在于设置页的临时 Task 中。
/// 任务历史仅保存轻量元数据，不保留备份 Data，避免长时间运行时内存和持久化文件增长。
public struct DataSyncTask: Identifiable, Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case upload
        case download
        case `import`
        case export
        case webdavMigration
    }

    public enum Status: String, Codable, Sendable {
        case running
        case completed
        case cancelled
        case failed
    }

    public let id: String
    public let operation: Operation
    public let backupName: String?
    public let fileName: String?
    public let forceUpload: Bool
    public let libraryID: String?
    public let libraryName: String?
    public var currentItem: String?
    public var totalItems: Int
    public var failureCount: Int
    public var failures: [String]
    public let createdAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var progress: Double
    public var phase: String
    public var error: String?

    public init(
        id: String = UUID().uuidString,
        operation: Operation,
        backupName: String? = nil,
        fileName: String? = nil,
        forceUpload: Bool = false,
        libraryID: String? = nil,
        libraryName: String? = nil,
        currentItem: String? = nil,
        totalItems: Int = 0,
        failureCount: Int = 0,
        failures: [String] = [],
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        status: Status = .running,
        progress: Double = 0,
        phase: String = "Preparing",
        error: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.backupName = backupName
        self.fileName = fileName
        self.forceUpload = forceUpload
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.currentItem = currentItem
        self.totalItems = totalItems
        self.failureCount = failureCount
        self.failures = failures
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.status = status
        self.progress = min(1, max(0, progress))
        self.phase = phase
        self.error = error
    }

    public var isRunning: Bool { status == .running }

    private enum CodingKeys: String, CodingKey {
        case id, operation, backupName, fileName, forceUpload, libraryID, libraryName, currentItem, totalItems, failureCount, failures, createdAt, finishedAt, status, progress, phase, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        operation = try container.decode(Operation.self, forKey: .operation)
        backupName = try container.decodeIfPresent(String.self, forKey: .backupName)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        forceUpload = try container.decodeIfPresent(Bool.self, forKey: .forceUpload) ?? false
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        currentItem = try container.decodeIfPresent(String.self, forKey: .currentItem)
        totalItems = try container.decodeIfPresent(Int.self, forKey: .totalItems) ?? 0
        failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        failures = try container.decodeIfPresent([String].self, forKey: .failures) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try container.decode(Status.self, forKey: .status)
        progress = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0))
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "Preparing"
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// 统一管理 WebDAV 上传/下载生命周期，供设置页和任务中心共用。
public final class DataSyncManager: @unchecked Sendable {
    public static let shared = DataSyncManager()

    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()
    private let persistenceKey = "venera.dataSyncTasks.v1"
    private let historyLimit = 50
    private var tasks: [DataSyncTask]
    private var jobs: [String: Task<Void, Never>] = [:]
    /// Export files are transient and intentionally not persisted with task history.
    private var completedExportURLs: [String: URL] = [:]

    private init() {
        var shouldPersistRecovery = false
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode([DataSyncTask].self, from: data) {
            tasks = saved.map { task in
                guard task.status == .running else { return task }
                shouldPersistRecovery = true
                var recovered = task
                recovered.status = .cancelled
                recovered.finishedAt = Date()
                recovered.phase = "Interrupted"
                return recovered
            }
        } else {
            tasks = []
        }
        // Persist the recovery marker so a relaunched app does not repeatedly
        // present the same interrupted task as if it just stopped again.
        if shouldPersistRecovery {
            persistLocked()
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    public func allTasks() -> [DataSyncTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    public func activeTasks() -> [DataSyncTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter(\.isRunning)
    }

    public func clearHistory() {
        lock.lock()
        let removed = tasks.filter { $0.status != .running }
        tasks.removeAll { $0.status != .running }
        for task in removed {
            if let url = completedExportURLs.removeValue(forKey: task.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    /// 启动一次普通 WebDAV 下载。已有同步任务运行时返回 nil，避免互相覆盖数据库。
    @discardableResult
    public func startDownload() -> DataSyncTask? {
        start(operation: .download, backupName: nil, fileURL: nil, forceUpload: false)
    }

    /// 启动一次指定备份下载。
    @discardableResult
    public func startDownload(backupName: String) -> DataSyncTask? {
        start(operation: .download, backupName: backupName, fileURL: nil, forceUpload: false)
    }

    /// 启动一次本地 `.venera` 导入。文件安全作用域在后台任务内打开，
    /// 避免设置页提前停止作用域后才开始读取导致 Files provider 失败。
    @discardableResult
    public func startImport(fileURL: URL) -> DataSyncTask? {
        start(operation: .import, backupName: nil, fileURL: fileURL, forceUpload: false)
    }

    /// 启动一次本地整库导出。任务历史只保存摘要，完成后的临时文件通过
    /// `takeCompletedExportURL(for:)` 一次性移交给分享面板。
    @discardableResult
    public func startExport() -> DataSyncTask? {
        start(operation: .export, backupName: nil, fileURL: nil, forceUpload: false)
    }

    /// 取出已完成导出的临时文件；取出后由调用方负责在分享结束后清理。
    public func takeCompletedExportURL(for taskID: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return completedExportURLs.removeValue(forKey: taskID)
    }

    private func storeCompletedExportURL(_ url: URL, for taskID: String) {
        lock.lock()
        completedExportURLs[taskID] = url
        lock.unlock()
    }

    /// 启动一次上传；force=true 表示手动以本机数据为准。
    @discardableResult
    public func startUpload(force: Bool = false) -> DataSyncTask? {
        start(operation: .upload, backupName: nil, fileURL: nil, forceUpload: force)
    }

    /// 将本地已下载漫画迁移到指定 WebDAV 漫画库，使用源可读取的标题/章节/页码目录。
    @discardableResult
    public func startWebDAVMigration(libraryID: String, skipExisting: Bool = true, numericPrefix: Bool = true) -> DataSyncTask? {
        guard let library = WebDAVLibraryStore.shared.find(id: libraryID) else { return nil }
        let comics = LocalManager.shared.getComics(.defaultSort).filter { $0.status == .downloaded }
        guard !comics.isEmpty else { return nil }
        return start(operation: .webdavMigration, backupName: nil, fileURL: nil, forceUpload: false, libraryID: libraryID, libraryName: library.displayName, migrationOptions: (skipExisting, numericPrefix))
    }

    public func cancel(id: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else {
            lock.unlock()
            return
        }
        tasks[index].status = .cancelled
        tasks[index].finishedAt = Date()
        tasks[index].phase = "Cancelled"
        let job = jobs.removeValue(forKey: id)
        persistLocked()
        lock.unlock()
        job?.cancel()
        onChange.emit(())
    }

    private func start(operation: DataSyncTask.Operation, backupName: String?, fileURL: URL?, forceUpload: Bool, libraryID: String? = nil, libraryName: String? = nil, migrationOptions: (skipExisting: Bool, numericPrefix: Bool)? = nil) -> DataSyncTask? {
        lock.lock()
        guard !tasks.contains(where: \.isRunning) else {
            lock.unlock()
            return nil
        }
        let task = DataSyncTask(
            operation: operation,
            backupName: backupName,
            fileName: fileURL?.lastPathComponent,
            forceUpload: forceUpload,
            libraryID: libraryID,
            libraryName: libraryName,
            totalItems: operation == .webdavMigration ? LocalManager.shared.getComics(.defaultSort).filter { $0.status == .downloaded }.count : 0
        )
        tasks.insert(task, at: 0)
        if tasks.count > historyLimit {
            let removed = tasks.suffix(from: historyLimit)
            for oldTask in removed {
                if let url = completedExportURLs.removeValue(forKey: oldTask.id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            tasks.removeLast(tasks.count - historyLimit)
        }
        persistLocked()
        lock.unlock()

        // Do not start an async job while holding the state lock: the job can
        // reach its first synchronous state update before its first await.
        let job = Task { [weak self] in
            guard let self else { return }
            await self.run(taskID: task.id, operation: operation, backupName: backupName, fileURL: fileURL, forceUpload: forceUpload, migrationOptions: migrationOptions)
        }
        lock.lock()
        if tasks.contains(where: { $0.id == task.id && $0.status == .running }) {
            jobs[task.id] = job
        }
        lock.unlock()
        onChange.emit(())
        return task
    }

    private func update(id: String, progress: Double, phase: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else {
            lock.unlock()
            return
        }
        tasks[index].progress = min(1, max(0, progress))
        tasks[index].phase = phase
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func finish(id: String, status: DataSyncTask.Status, error: String? = nil) {
        lock.lock()
        jobs.removeValue(forKey: id)
        if status != .completed, let url = completedExportURLs.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url)
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        guard tasks[index].status == .running else {
            lock.unlock()
            return
        }
        tasks[index].status = status
        tasks[index].finishedAt = Date()
        tasks[index].progress = status == .completed ? 1 : tasks[index].progress
        tasks[index].phase = status == .completed ? "Completed" : (status == .failed ? "Failed" : "Cancelled")
        tasks[index].error = error
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func run(taskID: String, operation: DataSyncTask.Operation, backupName: String?, fileURL: URL?, forceUpload: Bool, migrationOptions: (skipExisting: Bool, numericPrefix: Bool)? = nil) async {
        do {
            try Task.checkCancellation()
            update(id: taskID, progress: 0.1, phase: "Preparing")
            switch operation {
            case .upload:
                update(id: taskID, progress: 0.25, phase: "Uploading")
                try await DataSync.shared.upload(force: forceUpload)
            case .download:
                update(id: taskID, progress: 0.25, phase: "Downloading")
                if let backupName {
                    try await DataSync.shared.downloadSpecificBackup(backupName)
                } else {
                    try await DataSync.shared.download()
                }
                // The archive may replace source scripts. Reload them before
                // reporting completion so a successful task is immediately
                // reflected by the running app, not only after relaunch.
                try Task.checkCancellation()
                await ComicSourceManager.shared.reloadSources()
            case .import:
                guard let fileURL else { throw SyncError.invalidArchive }
                update(id: taskID, progress: 0.15, phase: "Reading backup")
                let secured = fileURL.startAccessingSecurityScopedResource()
                defer { if secured { fileURL.stopAccessingSecurityScopedResource() } }
                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: fileURL, options: .mappedIfSafe)
                }.value
                try Task.checkCancellation()
                update(id: taskID, progress: 0.65, phase: "Applying backup")
                try DataSync.shared.importAppData(data)
                try Task.checkCancellation()
                await ComicSourceManager.shared.reloadSources()
            case .export:
                update(id: taskID, progress: 0.2, phase: "Reading app data")
                let data = try await Task.detached(priority: .utility) {
                    try DataSync.shared.exportAppData(sync: false)
                }.value
                try Task.checkCancellation()
                update(id: taskID, progress: 0.75, phase: "Writing backup")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("data-\(Int(Date().timeIntervalSince1970))-\(taskID.prefix(8)).venera")
                try data.write(to: url, options: .atomic)
                storeCompletedExportURL(url, for: taskID)
            case .webdavMigration:
                try await runWebDAVMigration(taskID: taskID, options: migrationOptions ?? (true, true))
            }
            try Task.checkCancellation()
            finish(id: taskID, status: .completed)
        } catch is CancellationError {
            finish(id: taskID, status: .cancelled)
        } catch {
            finish(id: taskID, status: .failed, error: error.localizedDescription)
        }
    }

    private func recordMigrationFailure(id: String, _ message: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else { lock.unlock(); return }
        tasks[index].failureCount += 1
        if tasks[index].failures.count < 100 { tasks[index].failures.append(message) }
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func updateProgress(id: String, progress: Double) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else { lock.unlock(); return }
        tasks[index].progress = min(1, max(0, progress))
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func updateMigrationItem(id: String, current: Int, total: Int, title: String, phase: String) {
        lock.lock()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else { lock.unlock(); return }
        tasks[index].currentItem = title
        tasks[index].totalItems = total
        tasks[index].progress = total == 0 ? 0 : min(1, Double(current) / Double(total))
        tasks[index].phase = phase
        persistLocked()
        lock.unlock()
        onChange.emit(())
    }

    private func runWebDAVMigration(taskID: String, options: (skipExisting: Bool, numericPrefix: Bool)) async throws {
        guard let task = allTasks().first(where: { $0.id == taskID }), let libraryID = task.libraryID,
              let library = WebDAVLibraryStore.shared.find(id: libraryID) else { throw SyncError.notConfigured }
        let client = try WebDAVClient(url: library.url, username: library.user, password: library.pass)
        let root = library.root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.makeDirectory(root.isEmpty ? "/" : root)
        let comics = LocalManager.shared.getComics(.defaultSort).filter { $0.status == .downloaded }
        let names = migrationFolderNames(comics.map(\.title))
        var existing: Set<String> = []
        if options.skipExisting { existing = Set(try await client.listResources(root).filter(\.isCollection).map { $0.name.lowercased() }) }
        var failures = 0
        for (index, comic) in comics.enumerated() {
            try Task.checkCancellation()
            let folder = names[index]
            updateMigrationItem(id: taskID, current: index, total: comics.count, title: comic.title, phase: "Migrating")
            if options.skipExisting && existing.contains(folder.lowercased()) { continue }
            do {
                try await migrateComic(comic, folder: folder, root: root, client: client, numericPrefix: options.numericPrefix, taskID: taskID, comicIndex: index, comicTotal: comics.count)
            } catch is CancellationError { throw CancellationError()
            } catch {
                failures += 1
                recordMigrationFailure(id: taskID, "\(comic.title): \(error.localizedDescription)")
            }
        }
        updateMigrationItem(id: taskID, current: comics.count, total: comics.count, title: "", phase: failures == 0 ? "Completed" : "Completed with failures")
        if failures > 0 {
            // Keep the task in history as failed so the failure records are visible.
            throw NSError(domain: "WebDAVMigration", code: failures, userInfo: [NSLocalizedDescriptionKey: "\(failures) comic(s) failed to migrate"])
        }
    }

    private func migrateComic(_ comic: LocalComic, folder: String, root: String, client: WebDAVClient, numericPrefix: Bool, taskID: String, comicIndex: Int, comicTotal: Int) async throws {
        let comicDir = remoteJoin(root, folder)
        try await client.makeDirectory(comicDir)
        if !comic.coverPath.isEmpty && FileManager.default.fileExists(atPath: comic.coverPath) {
            try await client.put(remoteJoin(comicDir, "cover.\(fileExtension(comic.coverPath))"), try Data(contentsOf: URL(fileURLWithPath: comic.coverPath)))
        }
        let chapterEntries: [(id: String, title: String, index: Int)]
        if let chapters = comic.chapters {
            chapterEntries = chapters.ids.enumerated().compactMap { index, id -> (id: String, title: String, index: Int)? in
                guard comic.downloadedChapters.contains(id) else { return nil }
                return (id, chapters.titles.indices.contains(index) ? chapters.titles[index] : id, index)
            }
        } else { chapterEntries = [("1", "", 0)] }
        for chapter in chapterEntries {
            try Task.checkCancellation()
            let title = chapter.title.isEmpty ? "Chapter \(chapter.index + 1)" : chapter.title
            let chapterName = migrationChapterName(title, index: chapter.index, total: max(chapterEntries.count, 1), numericPrefix: numericPrefix)
            let chapterDir = comic.hasChapters ? remoteJoin(comicDir, chapterName) : comicDir
            try await client.makeDirectory(chapterDir)
            let images = LocalManager.shared.getImages(id: comic.id, type: comic.comicType, ep: chapter.id)
            guard !images.isEmpty else { throw NSError(domain: "WebDAVMigration", code: 2, userInfo: [NSLocalizedDescriptionKey: "No images in \(title)"]) }
            for (page, image) in images.enumerated() {
                try Task.checkCancellation()
                let path = image.hasPrefix("file://") ? String(image.dropFirst(7)) : image
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                try await client.put(remoteJoin(chapterDir, migrationPageName(page, total: images.count, ext: fileExtension(path))), data)
                updateMigrationItem(id: taskID, current: comicIndex, total: comicTotal, title: comic.title, phase: "Uploading \(comic.title) · \(page + 1)/\(images.count)")
                updateProgress(id: taskID, progress: (Double(comicIndex) + Double(page + 1) / Double(images.count)) / Double(max(comicTotal, 1)))
            }
        }
    }

    private func migrationFolderNames(_ titles: [String]) -> [String] {
        var used: Set<String> = []
        return titles.map { uniqueMigrationName($0, used: &used) }
    }

    private func uniqueMigrationName(_ title: String, used: inout Set<String>) -> String {
        let base = sanitizeMigrationName(title).isEmpty ? "untitled" : sanitizeMigrationName(title)
        var name = base; var n = 2
        while used.contains(name) { name = "\(base) (\(n))"; n += 1 }
        used.insert(name); return name
    }

    private func migrationChapterName(_ title: String, index: Int, total: Int, numericPrefix: Bool) -> String {
        let base = sanitizeMigrationName(title).isEmpty ? "chapter_\(index + 1)" : sanitizeMigrationName(title)
        guard numericPrefix else { return base }
        return "\(String(index + 1).leftPad(to: max(2, String(total).count), with: "0"))_\(base)"
    }

    private func sanitizeMigrationName(_ value: String) -> String {
        value.unicodeScalars.map { CharacterSet(charactersIn: "/\\:*?\"<>|").contains($0) ? "_" : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remoteJoin(_ parts: String...) -> String { WebDAVPath.join(parts) }
    private func fileExtension(_ path: String) -> String { let ext = URL(fileURLWithPath: path).pathExtension.lowercased(); return ext.isEmpty ? "jpg" : ext }
    private func migrationPageName(_ index: Int, total: Int, ext: String) -> String { "\(String(index + 1).leftPad(to: max(3, String(total).count), with: "0")).\(ext.isEmpty ? "jpg" : ext)" }

}

private extension String {
    func leftPad(to length: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
