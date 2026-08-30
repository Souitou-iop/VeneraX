import Foundation
import ZIPFoundation

/// 下载任务抽象基类（对齐原版 network/download.dart）。
public class DownloadTask: @unchecked Sendable, Identifiable {
    public let id: String
    public let comicType: Int

    public var title: String { "Loading..." }
    public var cover: String? { nil }
    public var message: String = ""
    public var progress: Double = 0.0
    public var speed: Int = 0
    public var eta: TimeInterval? = nil

    public var isError: Bool = false
    public var isPaused: Bool = true
    public var wasRunning: Bool = false
    public var userPaused: Bool = false
    public var autoRetryCount: Int = 0
    public var path: String? = nil

    public let onChange = CallbackRegistry<Void>()

    public init(id: String, comicType: Int) {
        self.id = id
        self.comicType = comicType
    }

    public func pause() {
        isPaused = true
        wasRunning = false
        message = "Paused"
        speed = 0
        eta = nil
        onChange.emit(())
    }

    public func resume() {
        isPaused = false
        isError = false
        wasRunning = true
        message = "Downloading..."
        onChange.emit(())
    }

    public func cancel() {
        pause()
    }

    public func toLocalComic() -> LocalComic {
        fatalError("Subclasses must implement toLocalComic")
    }

    public func toJson() -> JSON {
        fatalError("Subclasses must implement toJson")
    }

    public static func fromJson(_ json: JSON) -> DownloadTask? {
        let type = json["type"].stringValue
        if type == "ImagesDownloadTask" {
            return ImagesDownloadTask.parseImagesTask(from: json)
        } else if type == "ArchiveDownloadTask" {
            return ArchiveDownloadTask.parseArchiveTask(from: json)
        }
        return nil
    }
}

// MARK: - ImagesDownloadTask

/// 逐图/逐章下载任务（对齐原版 ImagesDownloadTask）。
public final class ImagesDownloadTask: DownloadTask, @unchecked Sendable {
    public let sourceKey: String
    public var comic: ComicDetails?
    public var chapters: [String]?
    public var comicTitle: String?
    public var comicCover: String?

    public var coverDownloadedPath: String?
    public var images: [String: [String]]?
    public var downloadedCount: Int = 0
    public var totalCount: Int = 0
    public var totalChapters: Int = 0
    public var currentChapterIndex: Int = 0
    public var currentImageIndex: Int = 0

    private var activeTask: Task<Void, Never>?
    private var lastSpeedCalcTime: Date = Date()
    private var bytesSinceLastTick: Int = 0
    private var smoothedBytesPerSec: Double = 0.0

    public init(
        sourceKey: String,
        comicId: String,
        comic: ComicDetails? = nil,
        chapters: [String]? = nil,
        comicTitle: String? = nil,
        comicCover: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.comic = comic
        self.chapters = chapters
        self.comicTitle = comicTitle ?? comic?.title
        self.comicCover = comicCover ?? comic?.cover
        super.init(id: comicId, comicType: ComicID.forSource(sourceKey))
    }

    public override var title: String {
        comic?.title ?? comicTitle ?? "Loading..."
    }

    public override var cover: String? {
        if let coverDownloadedPath {
            return "file://\(coverDownloadedPath)"
        }
        return comic?.cover ?? comicCover
    }

    public override func pause() {
        super.pause()
        activeTask?.cancel()
        activeTask = nil
        DownloadManager.shared.scheduleSaveDownloadingTasks()
    }

    public override func cancel() {
        super.cancel()
        activeTask?.cancel()
        activeTask = nil
        DownloadManager.shared.removeTask(self)

        let local = LocalManager.shared.find(id: id, type: comicType)
        if let targetPath = path {
            if local == nil {
                try? FileManager.default.removeItem(atPath: targetPath)
            } else if let chapters {
                for ch in chapters {
                    let chDir = AppPaths.join(targetPath, LocalManager.getChapterDirectoryName(ch))
                    try? FileManager.default.removeItem(atPath: chDir)
                }
            }
        }
    }

    public override func resume() {
        guard isPaused else { return }
        super.resume()
        DownloadManager.shared.scheduleSaveDownloadingTasks()

        activeTask = Task { [weak self] in
            await self?.runDownloadLoop()
        }
    }

    private func runDownloadLoop() async {
        guard !isPaused else { return }
        let source = ComicSourceManager.shared.find(sourceKey)
        guard let source else {
            setError("Source not found: \(sourceKey)")
            return
        }

        // 1. 获取漫画详情
        if comic == nil {
            message = "Fetching comic info..."
            onChange.emit(())
            do {
                comic = try await source.loadComicInfo(id: id)
                comicTitle = comic?.title
                comicCover = comic?.cover
            } catch {
                if Task.isCancelled { return }
                setError("Failed to fetch info: \(error.localizedDescription)")
                return
            }
        }
        guard let comic = self.comic else { return }

        // 2. 确定本地存储目录
        if path == nil {
            path = LocalManager.shared.findValidDirectory(id: id, type: comicType, title: comic.title)
        }
        guard let path = self.path else { return }
        LocalManager.shared.ensureDirectory()
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        // 3. 下载封面
        if coverDownloadedPath == nil {
            message = "Downloading cover..."
            onChange.emit(())
            if let coverUrl = comic.cover.isEmpty ? comicCover : comic.cover, !coverUrl.isEmpty {
                if let coverData = await ImageDownloader.shared.load(
                    imageKey: coverUrl,
                    sourceKey: sourceKey,
                    cid: id,
                    eid: "",
                    source: source
                ) {
                    let fileType = FileTypeDetector.detect(data: coverData)
                    let coverFileName = "cover\(fileType.ext)"
                    let coverFullPath = AppPaths.join(path, coverFileName)
                    try? coverData.write(to: URL(fileURLWithPath: coverFullPath))
                    coverDownloadedPath = coverFullPath
                }
            }
        }

        // 4. 解析章节与图片列表
        if images == nil {
            if let comicChapters = comic.chapters, !comicChapters.isEmpty {
                var selectedChapterIds = comicChapters.ids
                if let filter = chapters, !filter.isEmpty {
                    selectedChapterIds = selectedChapterIds.filter { filter.contains($0) }
                }
                totalChapters = selectedChapterIds.count
                var imageMap: [String: [String]] = [:]
                for (ci, chId) in selectedChapterIds.enumerated() {
                    if Task.isCancelled { return }
                    message = "Fetching page list (\(ci + 1)/\(selectedChapterIds.count))..."
                    onChange.emit(())
                    do {
                        let pages = try await source.loadComicPages(id: id, ep: chId)
                        imageMap[chId] = pages
                        totalCount += pages.count
                    } catch {
                        if Task.isCancelled { return }
                        setError("Failed to fetch chapter pages: \(error.localizedDescription)")
                        return
                    }
                }
                images = imageMap
            } else {
                // 单章漫画
                message = "Fetching image list..."
                onChange.emit(())
                do {
                    let pages = try await source.loadComicPages(id: id, ep: nil)
                    images = ["": pages]
                    totalCount = pages.count
                    totalChapters = 1
                } catch {
                    if Task.isCancelled { return }
                    setError("Failed to fetch pages: \(error.localizedDescription)")
                    return
                }
            }
            DownloadManager.shared.scheduleSaveDownloadingTasks()
        }

        guard let images = self.images else { return }
        let chapterKeys = Array(images.keys)

        // 5. 循环下载各章节图片
        let concurrency = AppData.shared.settings["downloadThreads"].intValue ?? 4

        while currentChapterIndex < chapterKeys.count {
            if Task.isCancelled || isPaused { return }
            let chKey = chapterKeys[currentChapterIndex]
            let chImages = images[chKey] ?? []

            let chapterSaveDir: String
            if !chKey.isEmpty {
                let chDirName = LocalManager.getChapterDirectoryName(chKey)
                chapterSaveDir = AppPaths.join(path, chDirName)
            } else {
                chapterSaveDir = path
            }
            try? FileManager.default.createDirectory(atPath: chapterSaveDir, withIntermediateDirectories: true)

            // 并发下载当前章节
            let ok = await downloadChapterImages(
                chImages: chImages,
                chapterKey: chKey,
                saveDir: chapterSaveDir,
                source: source,
                concurrency: max(1, concurrency)
            )
            guard ok else { return }

            currentImageIndex = 0
            currentChapterIndex += 1
            DownloadManager.shared.scheduleSaveDownloadingTasks()
        }

        // 6. 下载完成
        progress = 1.0
        message = "Done"
        isPaused = true
        wasRunning = false
        onChange.emit(())
        DownloadManager.shared.completeTask(self)
    }

    private func downloadChapterImages(
        chImages: [String],
        chapterKey: String,
        saveDir: String,
        source: ComicSource,
        concurrency: Int
    ) async -> Bool {
        while currentImageIndex < chImages.count {
            if Task.isCancelled || isPaused { return false }
            let batchEnd = min(currentImageIndex + concurrency, chImages.count)
            let batchIndices = Array(currentImageIndex..<batchEnd)

            await withTaskGroup(of: (Int, Data?).self) { group in
                for idx in batchIndices {
                    let imgUrl = chImages[idx]
                    group.addTask {
                        let data = await ImageDownloader.shared.load(
                            imageKey: imgUrl,
                            sourceKey: self.sourceKey,
                            cid: self.id,
                            eid: chapterKey,
                            source: source
                        )
                        return (idx, data)
                    }
                }

                for await (idx, data) in group {
                    if let data, data.count > 50 {
                        let fileType = FileTypeDetector.detect(data: data)
                        let fileName = "\(idx + 1)\(fileType.ext)"
                        let fullPath = AppPaths.join(saveDir, fileName)
                        try? data.write(to: URL(fileURLWithPath: fullPath))
                        self.onImageDownloaded(bytes: data.count)
                    }
                }
            }

            currentImageIndex = batchEnd
            updateProgressMessage(chapterKey: chapterKey, current: currentImageIndex, total: chImages.count)
            DownloadManager.shared.scheduleSaveDownloadingTasks()
        }
        return true
    }

    private func onImageDownloaded(bytes: Int) {
        downloadedCount += 1
        bytesSinceLastTick += bytes
        let now = Date()
        let interval = now.timeIntervalSince(lastSpeedCalcTime)
        if interval >= 0.5 {
            let currentRate = Double(bytesSinceLastTick) / interval
            smoothedBytesPerSec = smoothedBytesPerSec == 0 ? currentRate : (smoothedBytesPerSec * 0.6 + currentRate * 0.4)
            speed = Int(smoothedBytesPerSec)
            bytesSinceLastTick = 0
            lastSpeedCalcTime = now

            if speed > 0 && totalCount > downloadedCount {
                let remainingImages = totalCount - downloadedCount
                let avgBytesPerImage = max(100_000, Double(bytes))
                let remainingBytes = Double(remainingImages) * avgBytesPerImage
                eta = remainingBytes / Double(speed)
            }
        }
        if totalCount > 0 {
            progress = min(1.0, Double(downloadedCount) / Double(totalCount))
        }
        onChange.emit(())
    }

    private func updateProgressMessage(chapterKey: String, current: Int, total: Int) {
        if totalChapters > 1 {
            let chDisplay = currentChapterIndex + 1
            message = "Ep.\(chDisplay) (\(current)/\(total))"
        } else {
            message = "\(downloadedCount)/\(totalCount)"
        }
        onChange.emit(())
    }

    private func setError(_ err: String) {
        isError = true
        isPaused = true
        wasRunning = false
        message = "Error: \(err)"
        speed = 0
        eta = nil
        onChange.emit(())
        DownloadManager.shared.onTaskError(self)
    }

    public override func toLocalComic() -> LocalComic {
        var coverName = ""
        if let coverDownloadedPath {
            coverName = URL(fileURLWithPath: coverDownloadedPath).lastPathComponent
        } else if let path, let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for item in contents where item.hasPrefix("cover.") {
                coverName = item
                break
            }
        }

        let tags: [String] = comic?.tags.flatMap { k, v in v.map { "\(k):\($0)" } } ?? []
        let directoryName = path != nil ? URL(fileURLWithPath: path!).lastPathComponent : ""
        let downloadedChs = chapters ?? comic?.chapters?.ids ?? []

        return LocalComic(
            id: id,
            title: title,
            subtitle: comic?.subtitle ?? "",
            tags: tags,
            directory: directoryName,
            chapters: comic?.chapters,
            cover: coverName,
            comicType: comicType,
            downloadedChapters: downloadedChs,
            createdAt: Date(),
            description: comic?.description ?? ""
        )
    }

    public override func toJson() -> JSON {
        var map: [String: JSON] = [
            "type": .string("ImagesDownloadTask"),
            "sourceKey": .string(sourceKey),
            "comicId": .string(id),
            "comicTitle": .string(title),
            "downloadedCount": .int(downloadedCount),
            "totalCount": .int(totalCount),
            "totalChapters": .int(totalChapters),
            "currentChapterIndex": .int(currentChapterIndex),
            "currentImageIndex": .int(currentImageIndex),
            "wasRunning": .bool(wasRunning),
            "userPaused": .bool(userPaused),
            "isError": .bool(isError),
            "message": .string(message),
        ]
        if let path { map["path"] = .string(path) }
        if let coverDownloadedPath { map["coverDownloadedPath"] = .string(coverDownloadedPath) }
        if let comicCover { map["comicCover"] = .string(comicCover) }
        if let chapters { map["chapters"] = .array(chapters.map { .string($0) }) }
        if let comic { map["comic"] = comic.toJson() }
        if let images {
            var imgMap: [String: JSON] = [:]
            for (k, v) in images {
                imgMap[k] = .array(v.map { .string($0) })
            }
            map["images"] = .object(imgMap)
        }
        return .object(map)
    }

    public static func parseImagesTask(from json: JSON) -> ImagesDownloadTask? {
        guard let sourceKey = json["sourceKey"].stringValue,
              let comicId = json["comicId"].stringValue else { return nil }

        let comic: ComicDetails? = !json["comic"].isNull ? ComicDetails.fromJson(json["comic"]) : nil
        let chapters = json["chapters"].arrayValue?.compactMap { $0.stringValue }
        let comicTitle = json["comicTitle"].stringValue
        let comicCover = json["comicCover"].stringValue

        let task = ImagesDownloadTask(
            sourceKey: sourceKey,
            comicId: comicId,
            comic: comic,
            chapters: chapters,
            comicTitle: comicTitle,
            comicCover: comicCover
        )
        task.path = json["path"].stringValue
        task.coverDownloadedPath = json["coverDownloadedPath"].stringValue
        task.downloadedCount = json["downloadedCount"].intValue ?? 0
        task.totalCount = json["totalCount"].intValue ?? 0
        task.totalChapters = json["totalChapters"].intValue ?? 0
        task.currentChapterIndex = json["currentChapterIndex"].intValue ?? 0
        task.currentImageIndex = json["currentImageIndex"].intValue ?? 0
        task.wasRunning = json["wasRunning"].boolValue ?? false
        task.userPaused = json["userPaused"].boolValue ?? false
        task.isError = json["isError"].boolValue ?? false
        task.message = json["message"].stringValue ?? ""

        if let imgObj = json["images"].objectValue {
            var map: [String: [String]] = [:]
            for (k, v) in imgObj {
                if let arr = v.arrayValue {
                    map[k] = arr.compactMap { $0.stringValue }
                }
            }
            task.images = map
        }
        return task
    }
}

// MARK: - ArchiveDownloadTask

/// 压缩包整包下载任务（对齐原版 ArchiveDownloadTask）。
public final class ArchiveDownloadTask: DownloadTask, @unchecked Sendable {
    public let archiveUrl: String
    public let comic: ComicDetails

    private var activeTask: Task<Void, Never>?

    public init(archiveUrl: String, comic: ComicDetails) {
        self.archiveUrl = archiveUrl
        self.comic = comic
        super.init(id: comic.id, comicType: ComicID.forSource(comic.sourceKey))
    }

    public override var title: String { comic.title }
    public override var cover: String? { comic.cover }

    public override func pause() {
        super.pause()
        activeTask?.cancel()
        activeTask = nil
        DownloadManager.shared.scheduleSaveDownloadingTasks()
    }

    public override func resume() {
        guard isPaused else { return }
        super.resume()
        DownloadManager.shared.scheduleSaveDownloadingTasks()

        activeTask = Task { [weak self] in
            await self?.runArchiveDownload()
        }
    }

    private func runArchiveDownload() async {
        guard !isPaused else { return }
        if path == nil {
            path = LocalManager.shared.findValidDirectory(id: id, type: comicType, title: comic.title)
        }
        guard let path = self.path else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        message = "Downloading archive..."
        onChange.emit(())

        let tempArchiveURL = URL(fileURLWithPath: AppPaths.join(AppPaths.cachePath, "dl_\(UUID().uuidString).zip"))
        defer { try? FileManager.default.removeItem(at: tempArchiveURL) }

        guard let url = URL(string: archiveUrl) else {
            setError("Invalid archive URL: \(archiveUrl)")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                setError("Download failed")
                return
            }
            try data.write(to: tempArchiveURL)

            message = "Extracting archive..."
            onChange.emit(())

            guard let archive = Archive(url: tempArchiveURL, accessMode: .read, preferredEncoding: .utf8) else {
                setError("Corrupt archive file")
                return
            }
            let targetURL = URL(fileURLWithPath: path)
            for entry in archive {
                let dest = targetURL.appendingPathComponent(entry.path)
                if entry.type == .directory {
                    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: dest)
                }
            }

            progress = 1.0
            message = "Done"
            isPaused = true
            wasRunning = false
            onChange.emit(())
            DownloadManager.shared.completeTask(self)
        } catch {
            if Task.isCancelled { return }
            setError(error.localizedDescription)
        }
    }

    private func setError(_ err: String) {
        isError = true
        isPaused = true
        wasRunning = false
        message = "Error: \(err)"
        onChange.emit(())
        DownloadManager.shared.onTaskError(self)
    }

    public override func toLocalComic() -> LocalComic {
        var coverName = ""
        if let path, let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for item in contents where item.hasPrefix("cover.") {
                coverName = item
                break
            }
            if coverName.isEmpty, let first = contents.first(where: { !$0.hasPrefix(".") }) {
                coverName = first
            }
        }
        let tags = comic.tags.flatMap { k, v in v.map { "\(k):\($0)" } }
        let directoryName = path != nil ? URL(fileURLWithPath: path!).lastPathComponent : ""

        return LocalComic(
            id: id,
            title: title,
            subtitle: comic.subtitle,
            tags: tags,
            directory: directoryName,
            chapters: comic.chapters,
            cover: coverName,
            comicType: comicType,
            downloadedChapters: comic.chapters?.ids ?? [],
            createdAt: Date(),
            description: comic.description
        )
    }

    public override func toJson() -> JSON {
        var map: [String: JSON] = [
            "type": .string("ArchiveDownloadTask"),
            "archiveUrl": .string(archiveUrl),
            "comic": comic.toJson(),
            "wasRunning": .bool(wasRunning),
            "userPaused": .bool(userPaused),
            "isError": .bool(isError),
            "message": .string(message),
        ]
        if let path { map["path"] = .string(path) }
        return .object(map)
    }

    public static func parseArchiveTask(from json: JSON) -> ArchiveDownloadTask? {
        guard let url = json["archiveUrl"].stringValue,
              let comic = ComicDetails.fromJson(json["comic"]) else { return nil }
        let task = ArchiveDownloadTask(archiveUrl: url, comic: comic)
        task.path = json["path"].stringValue
        task.wasRunning = json["wasRunning"].boolValue ?? false
        task.userPaused = json["userPaused"].boolValue ?? false
        task.isError = json["isError"].boolValue ?? false
        task.message = json["message"].stringValue ?? ""
        return task
    }
}
