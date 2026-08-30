import Foundation
import ZIPFoundation

public struct ParsedComicMetadata: Sendable {
    public var title: String
    public var author: String
    public var artist: String
    public var description: String
    public var status: String
    public var tags: [String]

    public init(
        title: String = "",
        author: String = "",
        artist: String = "",
        description: String = "",
        status: String = "",
        tags: [String] = []
    ) {
        self.title = title
        self.author = author
        self.artist = artist
        self.description = description
        self.status = status
        self.tags = tags
    }
}

/// 本地漫画导入与导出器（对齐 cbz.dart, import_comic.dart, local_comic_scanner.dart, venera_comics.dart）。
public enum LocalComicImporter {

    /// Interchange manifest used by the Flutter `.venera_comics` format.
    /// Keep these fields intentionally small and stable: the archive may be
    /// exchanged between app versions and platforms.
    public struct VeneraComicsManifest: Codable, Sendable, Equatable {
        public let version: Int
        public let exportedAt: Int64
        public let comics: [VeneraComicEntry]

        public init(version: Int = 1, exportedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000), comics: [VeneraComicEntry]) {
            self.version = version
            self.exportedAt = exportedAt
            self.comics = comics
        }
    }

    public struct VeneraComicEntry: Codable, Sendable, Equatable {
        public let id: String
        public let comicType: Int
        public let title: String
        public let hasImages: Bool

        public init(id: String, comicType: Int, title: String, hasImages: Bool) {
            self.id = id
            self.comicType = comicType
            self.title = title
            self.hasImages = hasImages
        }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "bmp", "avif", "jpe"
    ]

    public static func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    // MARK: - 元数据解析

    public static func resolveMetadata(at directoryURL: URL) -> ParsedComicMetadata {
        if let meta = tryDetailsJson(at: directoryURL) { return meta }
        if let meta = tryComicInfoXml(at: directoryURL) { return meta }
        if let meta = tryMetadataJson(at: directoryURL) { return meta }
        return ParsedComicMetadata(title: directoryURL.lastPathComponent)
    }

    private static func tryDetailsJson(at directoryURL: URL) -> ParsedComicMetadata? {
        let fileURL = directoryURL.appendingPathComponent("details.json")
        guard let data = try? Data(contentsOf: fileURL),
              let str = String(data: data, encoding: .utf8),
              let json = JSON.decode(str),
              let obj = json.objectValue else { return nil }

        var tags: [String] = []
        if let genreArr = obj["genre"]?.arrayValue {
            tags.append(contentsOf: genreArr.compactMap { $0.stringValue })
        } else if let genreStr = obj["genre"]?.stringValue, !genreStr.isEmpty {
            tags.append(contentsOf: genreStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        let status = obj["status"]?.stringValue ?? ""
        if !status.isEmpty && status != "0" {
            tags.append("Status:\(status)")
        }
        let title = obj["title"]?.stringValue ?? directoryURL.lastPathComponent

        return ParsedComicMetadata(
            title: title.isEmpty ? directoryURL.lastPathComponent : title,
            author: obj["author"]?.stringValue ?? "",
            artist: obj["artist"]?.stringValue ?? "",
            description: obj["description"]?.stringValue ?? "",
            status: status,
            tags: tags
        )
    }

    private static func tryMetadataJson(at directoryURL: URL) -> ParsedComicMetadata? {
        let fileURL = directoryURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: fileURL),
              let str = String(data: data, encoding: .utf8),
              let json = JSON.decode(str),
              let obj = json.objectValue else { return nil }

        var tags: [String] = []
        if let tagList = obj["tags"]?.arrayValue {
            tags = tagList.compactMap { $0.stringValue }
        }
        let title = obj["title"]?.stringValue ?? directoryURL.lastPathComponent
        return ParsedComicMetadata(
            title: title.isEmpty ? directoryURL.lastPathComponent : title,
            author: obj["author"]?.stringValue ?? "",
            artist: obj["artist"]?.stringValue ?? "",
            description: obj["description"]?.stringValue ?? "",
            status: obj["status"]?.stringValue ?? "",
            tags: tags
        )
    }

    private static func tryComicInfoXml(at directoryURL: URL) -> ParsedComicMetadata? {
        let fileURL = directoryURL.appendingPathComponent("ComicInfo.xml")
        guard let data = try? Data(contentsOf: fileURL),
              let xml = String(data: data, encoding: .utf8) else { return nil }

        func extractTag(_ tag: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>", options: [.dotMatchesLineSeparators]) else {
                return nil
            }
            let nsString = xml as NSString
            let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length))
            guard let range = match?.range(at: 1) else { return nil }
            let raw = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            return unescapeXml(raw)
        }

        func unescapeXml(_ str: String) -> String {
            str.replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }

        let title = extractTag("Series") ?? extractTag("Title") ?? directoryURL.lastPathComponent
        let author = extractTag("Writer") ?? ""
        let artist = extractTag("Penciller") ?? extractTag("Inker") ?? ""
        let description = extractTag("Summary") ?? ""
        let status = extractTag("Status") ?? ""
        var tags: [String] = []
        if let genre = extractTag("Genre"), !genre.isEmpty {
            tags.append(contentsOf: genre.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        if !status.isEmpty && status != "0" {
            tags.append("Status:\(status)")
        }

        return ParsedComicMetadata(
            title: title.isEmpty ? directoryURL.lastPathComponent : title,
            author: author,
            artist: artist,
            description: description,
            status: status,
            tags: tags
        )
    }

    // MARK: - 目录扫描与导入

    public static func scanAndImportDirectory(
        _ sourceDirURL: URL,
        intoFolder favoriteFolder: String? = nil
    ) throws -> [LocalComic] {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDirURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(atPath: sourceDirURL.path)
        var subDirs: [String] = []
        var rootImages: [String] = []

        for item in contents {
            if item.hasPrefix(".") { continue }
            let itemPath = AppPaths.join(sourceDirURL.path, item)
            var subIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: itemPath, isDirectory: &subIsDir) {
                if subIsDir.boolValue {
                    subDirs.append(item)
                } else if isImageFile(item) {
                    rootImages.append(item)
                }
            }
        }

        // 判定：若根目录包含多个有图片的子目录且无根目录图片，可能是一本包含多个章节的漫画，或多本漫画
        // 对齐 local_comic_scanner：若子目录里只有图片（无更深层目录），视为章节目录
        var isSingleComicWithChapters = false
        if !subDirs.isEmpty && rootImages.isEmpty {
            var allSubdirsAreChapters = true
            for sub in subDirs {
                let subPath = AppPaths.join(sourceDirURL.path, sub)
                let subContents = (try? fileManager.contentsOfDirectory(atPath: subPath)) ?? []
                let hasDeeperDir = subContents.contains { name in
                    var deeperIsDir: ObjCBool = false
                    return fileManager.fileExists(atPath: AppPaths.join(subPath, name), isDirectory: &deeperIsDir) && deeperIsDir.boolValue
                }
                if hasDeeperDir {
                    allSubdirsAreChapters = false
                    break
                }
            }
            if allSubdirsAreChapters {
                isSingleComicWithChapters = true
            }
        }

        if isSingleComicWithChapters || !rootImages.isEmpty {
            // 单本漫画导入
            if let comic = try importSingleComic(sourceDirURL, favoriteFolder: favoriteFolder) {
                return [comic]
            }
            return []
        } else {
            // 批量目录导入：每个子目录各为一本漫画
            var imported: [LocalComic] = []
            for sub in subDirs {
                let subURL = sourceDirURL.appendingPathComponent(sub)
                if let comic = try? importSingleComic(subURL, favoriteFolder: favoriteFolder) {
                    imported.append(comic)
                }
            }
            return imported
        }
    }

    public static func importSingleComic(
        _ comicDirURL: URL,
        favoriteFolder: String? = nil
    ) throws -> LocalComic? {
        let fileManager = FileManager.default
        let meta = resolveMetadata(at: comicDirURL)
        let resolvedTitle = meta.title.isEmpty ? comicDirURL.lastPathComponent : meta.title

        let contents = try fileManager.contentsOfDirectory(atPath: comicDirURL.path)
        var chapterDirs: [String] = []
        var rootImages: [String] = []

        for item in contents {
            if item.hasPrefix(".") { continue }
            let itemPath = AppPaths.join(comicDirURL.path, item)
            var subIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: itemPath, isDirectory: &subIsDir) {
                if subIsDir.boolValue {
                    chapterDirs.append(item)
                } else if isImageFile(item) {
                    rootImages.append(item)
                }
            }
        }

        chapterDirs.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        rootImages.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        var coverName: String? = nil
        for img in rootImages {
            if img.lowercased().hasPrefix("cover.") {
                coverName = img
                break
            }
        }
        if coverName == nil {
            coverName = rootImages.first
        }
        if coverName == nil, let firstCh = chapterDirs.first {
            let chPath = AppPaths.join(comicDirURL.path, firstCh)
            let chImgs = ((try? fileManager.contentsOfDirectory(atPath: chPath)) ?? []).filter(isImageFile)
            if let firstImg = chImgs.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).first {
                coverName = AppPaths.join(firstCh, firstImg)
            }
        }

        guard let finalCover = coverName else {
            return nil
        }

        // 复制到 LocalManager 存储目录
        let destDirName = LocalManager.shared.findValidDirectoryName(base: LocalManager.shared.path, name: resolvedTitle)
        let destFullPath = AppPaths.join(LocalManager.shared.path, destDirName)
        try fileManager.createDirectory(atPath: destFullPath, withIntermediateDirectories: true)

        // 复制所有文件
        for item in contents {
            if item.hasPrefix(".") { continue }
            let src = AppPaths.join(comicDirURL.path, item)
            let dst = AppPaths.join(destFullPath, item)
            try? fileManager.copyItem(atPath: src, toPath: dst)
        }

        let newId = LocalManager.shared.findValidId(comicType: ComicID.local)
        var chapters: ComicChapters? = nil
        if !chapterDirs.isEmpty {
            let entries = chapterDirs.map { ComicChapters.Entry(id: $0, title: $0) }
            chapters = ComicChapters(flatEntries: entries)
        }

        let localComic = LocalComic(
            id: newId,
            title: resolvedTitle,
            subtitle: meta.author.isEmpty ? meta.artist : meta.author,
            tags: meta.tags,
            directory: destDirName,
            chapters: chapters,
            cover: finalCover,
            comicType: ComicID.local,
            downloadedChapters: chapterDirs,
            createdAt: Date(),
            description: meta.description
        )

        LocalManager.shared.add(localComic)

        if let favoriteFolder {
            let favItem = FavoriteItem(
                id: newId,
                name: resolvedTitle,
                coverPath: localComic.coverURL,
                author: localComic.subtitle,
                type: ComicID.local,
                tags: localComic.tags,
                favoriteTime: localComic.createdAt
            )
            LocalFavoritesManager.shared.addFavorite(favoriteFolder, favItem)
        }

        return localComic
    }

    // MARK: - CBZ / ZIP 导入

    public static func importArchive(
        _ archiveURL: URL,
        intoFolder favoriteFolder: String? = nil
    ) throws -> [LocalComic] {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cbz_import_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        guard let archive = Archive(url: archiveURL, accessMode: .read, preferredEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }

        for entry in archive {
            let dest = try safeArchiveDestination(entry.path, in: tempDir)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extract(entry, to: dest)
            }
        }

        // 解压后按目录扫描导入
        return try scanAndImportDirectory(tempDir, intoFolder: favoriteFolder)
    }

    // MARK: - .venera_comics interchange

    /// Exports one or more local comics using the cross-platform Flutter
    /// `.venera_comics` archive layout. The returned URL is a temporary file;
    /// callers own its lifetime and should remove it after sharing/uploading.
    public static func exportVeneraComics(
        comics: [LocalComic],
        includeImages: Bool = true,
        destinationURL: URL? = nil
    ) throws -> URL {
        guard !comics.isEmpty else { throw SyncError.invalidArchive }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("venera_comics_export_\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let entries = comics.map { comic in
            VeneraComicEntry(
                id: comic.id,
                comicType: comic.comicType,
                title: comic.title,
                hasImages: includeImages && comic.status == .downloaded
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try encoder.encode(VeneraComicsManifest(comics: entries)).write(to: manifestURL, options: .atomic)

        for (index, comic) in comics.enumerated() {
            let entry = entries[index]
            let comicDirName = safeArchiveComponent("\(comic.id)_\(comic.comicType)")
            let comicDir = staging.appendingPathComponent("comics", isDirectory: true)
                .appendingPathComponent(comicDirName, isDirectory: true)
            try fileManager.createDirectory(at: comicDir, withIntermediateDirectories: true)

            var metadata: [String: Any] = [
                "id": comic.id,
                "title": comic.title,
                "subtitle": comic.subtitle,
                "tags": comic.tags,
                "directory": comic.directory,
                "cover": comic.cover,
                "comicType": comic.comicType,
                "downloadedChapters": comic.downloadedChapters,
                "createdAt": Int64(comic.createdAt.timeIntervalSince1970 * 1000)
            ]
            if let chapters = comic.chapters?.toJson().objectValue {
                metadata["chapters"] = chapters.mapValues { $0.asAny }
            }
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            try metadataData.write(to: comicDir.appendingPathComponent("meta.json"), options: .atomic)

            let coverPath = comic.coverPath
            if fileManager.fileExists(atPath: coverPath) {
                let coverName = safeArchiveComponent(comic.cover.isEmpty ? "cover.jpg" : comic.cover)
                try fileManager.copyItem(at: URL(fileURLWithPath: coverPath), to: comicDir.appendingPathComponent(coverName))
            }
            guard entry.hasImages else { continue }
            let baseDir = URL(fileURLWithPath: comic.baseDir, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let source as URL in enumerator {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true { continue }
                let sourcePath = source.resolvingSymlinksInPath().path
                let basePath = baseDir.resolvingSymlinksInPath().path
                guard sourcePath.hasPrefix(basePath + "/") else { continue }
                let relative = String(sourcePath.dropFirst(basePath.count + 1))
                if relative == "meta.json" || relative == "metadata.json" || relative == "ComicInfo.xml" || relative == comic.cover { continue }
                let components = try safeArchiveComponents(relative)
                let target = components.reduce(comicDir) { $0.appendingPathComponent($1) }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: target)
            }
        }

        let output = destinationURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("venera_comics_\(Int64(Date().timeIntervalSince1970 * 1_000_000)).venera_comics")
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        guard let archive = Archive(url: output, accessMode: .create, preferredEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }
        guard let enumerator = fileManager.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw SyncError.invalidArchive
        }
        for case let source as URL in enumerator {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let sourcePath = source.resolvingSymlinksInPath().path
            let stagingPath = staging.resolvingSymlinksInPath().path
            guard sourcePath.hasPrefix(stagingPath + "/") else { continue }
            let relative = String(sourcePath.dropFirst(stagingPath.count + 1))
            _ = try archive.addEntry(with: relative, fileURL: source)
        }
        return output
    }

    /// Imports the Flutter-compatible `.venera_comics` archive into the local
    /// library. Existing comics are merged by `(id, comicType)` just like the
    /// normal LocalManager path; files are copied into a collision-free folder.
    @discardableResult
    public static func importVeneraComics(_ archiveURL: URL) throws -> [LocalComic] {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("venera_comics_import_\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        guard let archive = Archive(url: archiveURL, accessMode: .read, preferredEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }
        for entry in archive {
            let destination = try safeArchiveDestination(entry.path, in: staging)
            if entry.type == .directory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extract(entry, to: destination)
            }
        }
        let manifestURL = staging.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(VeneraComicsManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1 else { throw SyncError.invalidArchive }

        var imported: [LocalComic] = []
        for entry in manifest.comics {
            let dirName = safeArchiveComponent("\(entry.id)_\(entry.comicType)")
            let comicDir = staging.appendingPathComponent("comics", isDirectory: true).appendingPathComponent(dirName, isDirectory: true)
            let metaURL = comicDir.appendingPathComponent("meta.json")
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["title"] as? String else { continue }
            let subtitle = object["subtitle"] as? String ?? ""
            let tags = object["tags"] as? [String] ?? []
            let cover = object["cover"] as? String ?? "cover.jpg"
            let comicType = object["comicType"] as? Int ?? entry.comicType
            let downloaded = object["downloadedChapters"] as? [String] ?? []
            let createdAt = (object["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
            let chapters: ComicChapters? = {
                guard let chaptersObject = object["chapters"] as? [String: Any],
                      let chaptersData = try? JSONSerialization.data(withJSONObject: chaptersObject),
                      let chaptersText = String(data: chaptersData, encoding: .utf8),
                      let chaptersJSON = JSON.decode(chaptersText) else { return nil }
                return ComicChapters.fromJson(chaptersJSON)
            }()
            let existing = LocalManager.shared.find(id: id, type: comicType)
            let destinationName = existing?.directory ?? LocalManager.shared.findValidDirectoryName(base: LocalManager.shared.path, name: title)
            let destinationDir = URL(fileURLWithPath: LocalManager.shared.path, isDirectory: true).appendingPathComponent(destinationName, isDirectory: true)
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            guard let enumerator = fileManager.enumerator(at: comicDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let source as URL in enumerator {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true || source.lastPathComponent == "meta.json" { continue }
                let sourcePath = source.resolvingSymlinksInPath().path
                let comicDirPath = comicDir.resolvingSymlinksInPath().path
                guard sourcePath.hasPrefix(comicDirPath + "/") else { continue }
                let relative = String(sourcePath.dropFirst(comicDirPath.count + 1))
                let target = relative.split(separator: "/").reduce(destinationDir) { $0.appendingPathComponent(String($1)) }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: target)
            }
            let comic = LocalComic(id: id, title: title, subtitle: subtitle, tags: tags, directory: destinationName, chapters: chapters, cover: cover, comicType: comicType, downloadedChapters: downloaded, createdAt: createdAt)
            LocalManager.shared.add(comic)
            imported.append(comic)
        }
        return imported
    }

    private static func safeArchiveDestination(_ path: String, in root: URL) throws -> URL {
        let components = try safeArchiveComponents(path)
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }

    private static func safeArchiveComponents(_ path: String) throws -> [String] {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !normalized.hasPrefix("/"), !components.contains("."), !components.contains(".."), components.allSatisfy({ !$0.isEmpty }) else {
            throw SyncError.invalidArchive
        }
        return components
    }

    private static func safeArchiveComponent(_ value: String) -> String {
        let result = value.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "/", with: "_")
        return result.isEmpty ? "_" : result
    }

    // MARK: - CBZ 导出

    public static func exportToCBZ(comic: LocalComic, destinationURL: URL) throws {
        let tempStaging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cbz_export_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempStaging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempStaging) }

        let fileManager = FileManager.default

        // 1. 复制/组织图片文件
        if !comic.hasChapters {
            let images = LocalManager.shared.getImages(id: comic.id, type: comic.comicType, ep: 1)
            let digits = String(images.count).count
            for (idx, imgPath) in images.enumerated() {
                let cleanPath = imgPath.hasPrefix("file://") ? String(imgPath.dropFirst("file://".count)) : imgPath
                let ext = (cleanPath as NSString).pathExtension
                let padded = String(format: "%0\(digits)d.%@", idx + 1, ext)
                let dst = tempStaging.appendingPathComponent(padded).path
                try? fileManager.copyItem(atPath: cleanPath, toPath: dst)
            }
        } else if comic.chapters != nil {
            var globalIndex = 1
            for chId in comic.downloadedChapters {
                let chImages = LocalManager.shared.getImages(id: comic.id, type: comic.comicType, ep: chId)
                let chDirName = LocalManager.getChapterDirectoryName(chId)
                let targetChDir = tempStaging.appendingPathComponent(chDirName).path
                try? fileManager.createDirectory(atPath: targetChDir, withIntermediateDirectories: true)
                for imgPath in chImages {
                    let cleanPath = imgPath.hasPrefix("file://") ? String(imgPath.dropFirst("file://".count)) : imgPath
                    let ext = (cleanPath as NSString).pathExtension
                    let fileName = "\(globalIndex).\(ext)"
                    let dst = AppPaths.join(targetChDir, fileName)
                    try? fileManager.copyItem(atPath: cleanPath, toPath: dst)
                    globalIndex += 1
                }
            }
        }

        // 2. 写入 cover
        let coverPath = comic.coverPath
        if fileManager.fileExists(atPath: coverPath) {
            let coverExt = (coverPath as NSString).pathExtension
            let dstCover = tempStaging.appendingPathComponent("cover.\(coverExt)").path
            try? fileManager.copyItem(atPath: coverPath, toPath: dstCover)
        }

        // 3. 写入 ComicInfo.xml
        let comicInfo = buildComicInfoXml(comic: comic)
        try? comicInfo.write(to: tempStaging.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)

        // 4. 压缩打包
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        guard let archive = Archive(url: destinationURL, accessMode: .create, preferredEncoding: .utf8) else {
            throw SyncError.invalidArchive
        }
        let enumerator = fileManager.enumerator(atPath: tempStaging.path)
        while let file = enumerator?.nextObject() as? String {
            let srcURL = tempStaging.appendingPathComponent(file)
            _ = try? archive.addEntry(with: file, fileURL: srcURL)
        }
    }

    private static func buildComicInfoXml(comic: LocalComic) -> String {
        func escapeXml(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<ComicInfo xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n"
        xml += "  <Title>\(escapeXml(comic.title))</Title>\n"
        xml += "  <Series>\(escapeXml(comic.title))</Series>\n"
        if !comic.subtitle.isEmpty {
            xml += "  <Writer>\(escapeXml(comic.subtitle))</Writer>\n"
        }
        if !comic.description.isEmpty {
            xml += "  <Summary>\(escapeXml(comic.description))</Summary>\n"
        }
        if !comic.tags.isEmpty {
            let joinedTags = comic.tags.prefix(5).joined(separator: ", ")
            xml += "  <Genre>\(escapeXml(joinedTags))</Genre>\n"
        }
        xml += "  <Manga>Unknown</Manga>\n"
        xml += "  <Year>\(Calendar.current.component(.year, from: comic.createdAt))</Year>\n"
        xml += "</ComicInfo>\n"
        return xml
    }
}
