import XCTest
import ZIPFoundation
@testable import VeneraKit

final class LocalComicImporterTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "VeneraImportTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        AppPaths.overrideDataPath = tempDir
        AppPaths.overrideCachePath = tempDir
        LocalManager.shared.ensureSchema()
        LocalManager.shared.ensureDirectory()
    }

    override func tearDown() {
        LocalManager.shared.batchDeleteComics(LocalManager.shared.getComics(), removeFiles: false, removeFavoriteAndHistory: false)
        try? FileManager.default.removeItem(atPath: tempDir)
        AppPaths.overrideDataPath = nil
        AppPaths.overrideCachePath = nil
        super.tearDown()
    }

    func testComicInfoXmlParsing() throws {
        let comicDir = URL(fileURLWithPath: AppPaths.join(tempDir, "xml_test"))
        try FileManager.default.createDirectory(at: comicDir, withIntermediateDirectories: true)

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema">
          <Title>One Piece</Title>
          <Writer>Eiichiro Oda</Writer>
          <Summary>Pirate adventure story</Summary>
          <Genre>Action, Shonen, Adventure</Genre>
          <Status>Ongoing</Status>
        </ComicInfo>
        """
        try xml.write(to: comicDir.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)

        let meta = LocalComicImporter.resolveMetadata(at: comicDir)
        XCTAssertEqual(meta.title, "One Piece")
        XCTAssertEqual(meta.author, "Eiichiro Oda")
        XCTAssertEqual(meta.description, "Pirate adventure story")
        XCTAssertTrue(meta.tags.contains("Action"))
        XCTAssertTrue(meta.tags.contains("Status:Ongoing"))
    }

    func testDirectoryImportAndCBZExportRoundTrip() throws {
        let sourceComicDir = URL(fileURLWithPath: AppPaths.join(tempDir, "source_comic"))
        try FileManager.default.createDirectory(at: sourceComicDir, withIntermediateDirectories: true)

        // 写入虚拟图片文件
        let dummyImageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48])
        try dummyImageBytes.write(to: sourceComicDir.appendingPathComponent("cover.jpg"))
        try dummyImageBytes.write(to: sourceComicDir.appendingPathComponent("1.jpg"))
        try dummyImageBytes.write(to: sourceComicDir.appendingPathComponent("2.jpg"))

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo>
          <Title>Export Roundtrip Comic</Title>
          <Writer>Test Author</Writer>
        </ComicInfo>
        """
        try xml.write(to: sourceComicDir.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)

        // 1. 目录导入
        let importedComics = try LocalComicImporter.scanAndImportDirectory(sourceComicDir)
        XCTAssertEqual(importedComics.count, 1)
        guard let imported = importedComics.first else { return }

        XCTAssertEqual(imported.title, "Export Roundtrip Comic")
        XCTAssertEqual(imported.subtitle, "Test Author")
        XCTAssertEqual(LocalManager.shared.count, 1)

        // 2. 导出为 CBZ
        let exportCBZURL = URL(fileURLWithPath: AppPaths.join(tempDir, "exported.cbz"))
        try LocalComicImporter.exportToCBZ(comic: imported, destinationURL: exportCBZURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportCBZURL.path))

        // 3. 验证 CBZ 内容
        guard let archive = Archive(url: exportCBZURL, accessMode: .read, preferredEncoding: .utf8) else {
            XCTFail("Failed to open exported CBZ archive")
            return
        }
        let entryNames = archive.map(\.path)
        XCTAssertTrue(entryNames.contains("cover.jpg"))
        XCTAssertTrue(entryNames.contains("1.jpg"))
        XCTAssertTrue(entryNames.contains("2.jpg"))
        XCTAssertTrue(entryNames.contains("ComicInfo.xml"))

        // 4. 从 CBZ 再次导入
        LocalManager.shared.batchDeleteComics(LocalManager.shared.getComics(), removeFiles: true, removeFavoriteAndHistory: true)
        XCTAssertEqual(LocalManager.shared.count, 0)

        let reimported = try LocalComicImporter.importArchive(exportCBZURL)
        XCTAssertEqual(reimported.count, 1)
        XCTAssertEqual(reimported.first?.title, "Export Roundtrip Comic")
        XCTAssertEqual(reimported.first?.subtitle, "Test Author")
        XCTAssertEqual(LocalManager.shared.count, 1)
    }
    func testVeneraComicsExportImportRoundTrip() throws {
        let sourceComicDir = URL(fileURLWithPath: AppPaths.join(tempDir, "venera_source"))
        try FileManager.default.createDirectory(at: sourceComicDir, withIntermediateDirectories: true)
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try image.write(to: sourceComicDir.appendingPathComponent("cover.jpg"))
        try image.write(to: sourceComicDir.appendingPathComponent("1.jpg"))
        let xml = "<ComicInfo><Title>Venera Bundle</Title><Writer>Author</Writer></ComicInfo>"
        try xml.write(to: sourceComicDir.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)

        let imported = try LocalComicImporter.scanAndImportDirectory(sourceComicDir)
        XCTAssertEqual(imported.count, 1)
        guard let comic = imported.first else { return }
        let bundleURL = URL(fileURLWithPath: AppPaths.join(tempDir, "bundle.venera_comics"))
        _ = try LocalComicImporter.exportVeneraComics(comics: [comic], destinationURL: bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))

        let archive = try XCTUnwrap(Archive(url: bundleURL, accessMode: .read, preferredEncoding: .utf8))
        let paths = archive.map(\.path)
        XCTAssertTrue(paths.contains("manifest.json"))
        XCTAssertTrue(paths.contains(where: { $0.hasSuffix("/meta.json") }))
        XCTAssertTrue(paths.contains(where: { $0.hasSuffix("/cover.jpg") }))

        LocalManager.shared.batchDeleteComics(LocalManager.shared.getComics(), removeFiles: true, removeFavoriteAndHistory: true)
        let restored = try LocalComicImporter.importVeneraComics(bundleURL)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.title, "Venera Bundle")
        XCTAssertEqual(restored.first?.subtitle, "Author")
        XCTAssertEqual(LocalManager.shared.count, 1)
    }

    func testArchiveImportRejectsPathTraversal() throws {
        let archiveURL = URL(fileURLWithPath: AppPaths.join(tempDir, "traversal.cbz"))
        let payloadURL = URL(fileURLWithPath: AppPaths.join(tempDir, "payload.txt"))
        try Data("do not extract".utf8).write(to: payloadURL)
        let archive = try XCTUnwrap(Archive(url: archiveURL, accessMode: .create, preferredEncoding: .utf8))
        try archive.addEntry(with: "../escaped.txt", fileURL: payloadURL)
        XCTAssertThrowsError(try LocalComicImporter.importArchive(archiveURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.join(tempDir, "escaped.txt")))
    }

}

extension LocalComicImporterTests {
    func testPDFAndEPUBExportProduceReadableFiles() throws {
        let source = URL(fileURLWithPath: AppPaths.join(tempDir, "format_comic"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: source.appendingPathComponent("cover.png"))
        try png.write(to: source.appendingPathComponent("1.png"))
        try png.write(to: source.appendingPathComponent("2.png"))
        let comic = try XCTUnwrap(LocalComicImporter.scanAndImportDirectory(source).first)

        let pdf = URL(fileURLWithPath: AppPaths.join(tempDir, "comic.pdf"))
        try LocalComicImporter.exportPDF(comic: comic, destinationURL: pdf)
        let pdfData = try Data(contentsOf: pdf)
        XCTAssertGreaterThan(pdfData.count, 100)
        XCTAssertTrue(String(data: pdfData.prefix(8), encoding: .ascii)?.hasPrefix("%PDF-1.") == true)

        let epub = URL(fileURLWithPath: AppPaths.join(tempDir, "comic.epub"))
        try LocalComicImporter.exportEPUB(comic: comic, destinationURL: epub)
        guard let archive = Archive(url: epub, accessMode: .read, preferredEncoding: .utf8) else {
            return XCTFail("EPUB is not a readable ZIP archive")
        }
        let names = archive.map(\.path)
        XCTAssertEqual(names.first, "mimetype")
        XCTAssertTrue(names.contains("META-INF/container.xml"))
        XCTAssertTrue(names.contains("OEBPS/content.opf"))
        XCTAssertTrue(names.contains("OEBPS/images/image-1.png"))
    }

    func testExportFormatRejectsComicWithoutImages() throws {
        let comic = LocalComic(id: "empty", title: "Empty", subtitle: "", tags: [], directory: "missing", chapters: nil, cover: "", comicType: ComicID.local, downloadedChapters: [])
        XCTAssertThrowsError(try LocalComicImporter.exportPDF(comic: comic, destinationURL: URL(fileURLWithPath: AppPaths.join(tempDir, "empty.pdf")))) { error in
            XCTAssertEqual(error as? LocalComicExportError, .noImages("Empty"))
        }
    }
}

extension LocalComicImporterTests {
    func testExportManagerPersistsMergedOutputInVisibleExportsDirectory() async throws {
        let source = URL(fileURLWithPath: AppPaths.join(tempDir, "manager_comic"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: source.appendingPathComponent("cover.png"))
        try png.write(to: source.appendingPathComponent("1.png"))
        let comic = try XCTUnwrap(LocalComicImporter.scanAndImportDirectory(source).first)
        var second = comic
        second.id = "manager-comic-2"
        second.title = "Second Comic"

        let outputRoot = URL(fileURLWithPath: AppPaths.join(tempDir, "Documents", "Exports"), isDirectory: true)
        LocalComicExportManager.overrideExportDirectoryURL = outputRoot
        defer {
            LocalComicExportManager.overrideExportDirectoryURL = nil
            LocalComicExportManager.shared.clearHistory()
        }

        let task = try XCTUnwrap(LocalComicExportManager.shared.start(comics: [comic, second], format: .veneraComics, mergeVeneraComics: true))
        var finished = task
        for _ in 0..<100 {
            if let current = LocalComicExportManager.shared.allTasks().first(where: { $0.id == task.id }) {
                finished = current
                if !current.isRunning { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.outputRelativePaths.count, 1)
        XCTAssertEqual(finished.outputCount, 1)
        let output = try XCTUnwrap(LocalComicExportManager.shared.outputURLs(for: finished).first)
        XCTAssertEqual(output.deletingLastPathComponent().standardizedFileURL, outputRoot.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
}
