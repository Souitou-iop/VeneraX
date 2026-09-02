import Foundation

public struct LocalComicExportTask: Identifiable, Codable, Sendable {
    public let id: String
    public let format: LocalComicExportFormat
    public let comicTitles: [String]
    public let mergeVeneraComics: Bool
    public let createdAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var currentIndex: Int
    public var phase: String
    public var error: String?
    public var outputRelativePaths: [String]

    public enum Status: String, Codable, Sendable { case running, completed, cancelled, failed }
    public var progress: Double { comicTitles.isEmpty ? 0 : Double(currentIndex) / Double(comicTitles.count) }
    public var isRunning: Bool { status == .running }
    public var outputCount: Int { outputRelativePaths.count }

    public init(id: String = UUID().uuidString, format: LocalComicExportFormat, comicTitles: [String], mergeVeneraComics: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.format = format; self.comicTitles = comicTitles; self.mergeVeneraComics = mergeVeneraComics; self.createdAt = createdAt
        self.finishedAt = nil; self.status = .running; self.currentIndex = 0; self.phase = "Preparing"; self.error = nil; self.outputRelativePaths = []
    }

    private enum CodingKeys: String, CodingKey { case id, format, comicTitles, mergeVeneraComics, createdAt, finishedAt, status, currentIndex, phase, error, outputRelativePaths }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); format = try c.decode(LocalComicExportFormat.self, forKey: .format)
        comicTitles = try c.decode([String].self, forKey: .comicTitles)
        mergeVeneraComics = try c.decodeIfPresent(Bool.self, forKey: .mergeVeneraComics) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt); finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try c.decode(Status.self, forKey: .status); currentIndex = try c.decode(Int.self, forKey: .currentIndex)
        phase = try c.decode(String.self, forKey: .phase); error = try c.decodeIfPresent(String.self, forKey: .error)
        outputRelativePaths = try c.decodeIfPresent([String].self, forKey: .outputRelativePaths) ?? []
    }
}

/// Serializes exports to Documents/Exports so successful files remain visible in Files.
public final class LocalComicExportManager: @unchecked Sendable {
    public static let shared = LocalComicExportManager()
    public nonisolated(unsafe) static var overrideExportDirectoryURL: URL?
    public let onChange = CallbackRegistry<Void>()
    private let lock = NSLock()
    private let persistenceKey = "venera.localComicExportTasks.v2"
    private let historyLimit = 50
    private var tasks: [LocalComicExportTask]
    private var jobs: [String: Task<Void, Never>] = [:]

    public static var exportDirectoryURL: URL {
        if let overrideExportDirectoryURL { return overrideExportDirectoryURL }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
    }

    private init() {
        let data = UserDefaults.standard.data(forKey: persistenceKey)
        tasks = (try? JSONDecoder().decode([LocalComicExportTask].self, from: data ?? Data())) ?? []
        tasks = tasks.map { task in
            guard task.status == .running else { return task }
            var recovered = task; recovered.status = .cancelled; recovered.finishedAt = Date(); recovered.phase = "Interrupted"; return recovered
        }
        persistLocked()
    }

    public func allTasks() -> [LocalComicExportTask] { lock.lock(); defer { lock.unlock() }; return tasks }
    public func activeTasks() -> [LocalComicExportTask] { allTasks().filter(\.isRunning) }
    public func outputURLs(for task: LocalComicExportTask) -> [URL] {
        task.outputRelativePaths.map { Self.exportDirectoryURL.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    public func revealableOutputURLs(for id: String) -> [URL] {
        allTasks().first(where: { $0.id == id }).map(outputURLs(for:)) ?? []
    }
    /// Returns persistent files for optional sharing without taking ownership or deleting them.
    public func takeCompletedURLs(for id: String) -> [URL] { revealableOutputURLs(for: id) }

    @discardableResult
    public func start(comics: [LocalComic], format: LocalComicExportFormat, mergeVeneraComics: Bool = false) -> LocalComicExportTask? {
        guard !comics.isEmpty else { return nil }
        lock.lock(); guard !tasks.contains(where: \.isRunning) else { lock.unlock(); return nil }
        let task = LocalComicExportTask(format: format, comicTitles: comics.map(\.title), mergeVeneraComics: mergeVeneraComics)
        tasks.insert(task, at: 0); trimLocked(); persistLocked(); lock.unlock(); onChange.emit(())
        jobs[task.id] = Task.detached(priority: .utility) { [weak self] in await self?.run(task: task, comics: comics) }
        return task
    }

    public func cancel(id: String) {
        lock.lock(); guard let index = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }
        tasks[index].status = .cancelled; tasks[index].finishedAt = Date(); tasks[index].phase = "Cancelled"
        let job = jobs.removeValue(forKey: id); removeOutputsLocked(for: tasks[index]); persistLocked(); lock.unlock(); job?.cancel(); onChange.emit(())
    }

    public func clearHistory() {
        lock.lock(); let old = tasks.filter { !$0.isRunning }; tasks.removeAll { !$0.isRunning }; old.forEach(removeOutputsLocked(for:)); persistLocked(); lock.unlock(); onChange.emit(())
    }

    private func run(task: LocalComicExportTask, comics: [LocalComic]) async {
        let root = Self.exportDirectoryURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var outputURLs: [URL] = []
            let shouldMerge = task.format == .veneraComics && task.mergeVeneraComics && comics.count > 1
            if shouldMerge {
                let name = uniqueName(LocalManager.sanitizeFileName("VeneraX Export"), ext: task.format.fileExtension, in: root)
                let url = root.appendingPathComponent(name)
                update(id: task.id, index: 0, phase: "Exporting \(comics.count) comics")
                _ = try LocalComicImporter.exportVeneraComics(comics: comics, destinationURL: url)
                outputURLs = [url]
                appendOutput(url, for: task.id)
                update(id: task.id, index: comics.count, phase: "Completed")
            } else {
                for (index, comic) in comics.enumerated() {
                    try Task.checkCancellation(); update(id: task.id, index: index, phase: "Exporting \(comic.title)")
                    let url = root.appendingPathComponent(uniqueName(LocalManager.sanitizeFileName(comic.title), ext: task.format.fileExtension, in: root))
                    switch task.format {
                    case .cbz: try LocalComicImporter.exportToCBZ(comic: comic, destinationURL: url)
                    case .pdf: try LocalComicImporter.exportPDF(comic: comic, destinationURL: url)
                    case .epub: try LocalComicImporter.exportEPUB(comic: comic, destinationURL: url)
                    case .veneraComics: _ = try LocalComicImporter.exportVeneraComics(comics: [comic], destinationURL: url)
                    }
                    outputURLs.append(url); appendOutput(url, for: task.id); update(id: task.id, index: index + 1, phase: "Exported \(comic.title)")
                }
            }
            try Task.checkCancellation(); storeOutputs(outputURLs, for: task.id); finish(id: task.id, status: .completed)
        } catch is CancellationError { removeOutputs(for: task.id); finish(id: task.id, status: .cancelled) }
        catch { removeOutputs(for: task.id); finish(id: task.id, status: .failed, error: error.localizedDescription) }
    }

    private func uniqueName(_ base: String, ext: String, in directory: URL) -> String {
        var name = "\(base).\(ext)", index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { name = "\(base)-\(index).\(ext)"; index += 1 }
        return name
    }
    private func storeOutputs(_ urls: [URL], for id: String) { lock.lock(); guard let i = tasks.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }; tasks[i].outputRelativePaths = urls.map(\.lastPathComponent); persistLocked(); lock.unlock(); onChange.emit(()) }
    private func appendOutput(_ url: URL, for id: String) { lock.lock(); guard let i = tasks.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }; if !tasks[i].outputRelativePaths.contains(url.lastPathComponent) { tasks[i].outputRelativePaths.append(url.lastPathComponent) }; persistLocked(); lock.unlock(); onChange.emit(()) }
    private func removeOutputs(for id: String) { lock.lock(); guard let task = tasks.first(where: { $0.id == id }) else { lock.unlock(); return }; removeOutputsLocked(for: task); lock.unlock() }
    private func removeOutputsLocked(for task: LocalComicExportTask) { for path in task.outputRelativePaths { try? FileManager.default.removeItem(at: Self.exportDirectoryURL.appendingPathComponent(path)) } }
    private func update(id: String, index: Int, phase: String) { lock.lock(); guard let i = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }; tasks[i].currentIndex = index; tasks[i].phase = phase; persistLocked(); lock.unlock(); onChange.emit(()) }
    private func finish(id: String, status: LocalComicExportTask.Status, error: String? = nil) { lock.lock(); jobs.removeValue(forKey: id); guard let i = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { lock.unlock(); return }; tasks[i].status = status; tasks[i].finishedAt = Date(); tasks[i].currentIndex = status == .completed ? tasks[i].comicTitles.count : tasks[i].currentIndex; tasks[i].phase = status == .completed ? "Completed" : (status == .failed ? "Failed" : "Cancelled"); tasks[i].error = error; persistLocked(); lock.unlock(); onChange.emit(()) }
    private func trimLocked() { guard tasks.count > historyLimit else { return }; for old in tasks.suffix(from: historyLimit) { removeOutputsLocked(for: old) }; tasks.removeLast(tasks.count - historyLimit) }
    private func persistLocked() { if let data = try? JSONEncoder().encode(tasks) { UserDefaults.standard.set(data, forKey: persistenceKey) } }
}
