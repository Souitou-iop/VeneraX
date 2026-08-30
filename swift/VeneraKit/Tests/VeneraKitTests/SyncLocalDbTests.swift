import XCTest
import ZIPFoundation
@testable import VeneraKit

final class SyncLocalDbTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "VeneraSyncLocalTests-\(UUID().uuidString)"
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

    func testExportIncludesLocalDbWhenSyncLocalComicsEnabled() throws {
        let comic = LocalComic(
            id: "sync_1",
            title: "Sync Test Comic",
            subtitle: "Author",
            tags: ["Fantasy"],
            directory: "sync_comic_dir",
            chapters: nil,
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: []
        )
        LocalManager.shared.add(comic)

        AppData.shared.settings["syncLocalComics"] = .bool(true)
        let data = try DataSync.shared.exportAppData(sync: true)

        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: .utf8) else {
            XCTFail("Failed to read export archive")
            return
        }
        let entries = archive.map(\.path)
        XCTAssertTrue(entries.contains("local.db"))
    }

    func testExportExcludesLocalDbWhenSyncLocalComicsDisabled() throws {
        let comic = LocalComic(
            id: "sync_2",
            title: "Sync Test Comic 2",
            subtitle: "Author",
            tags: [],
            directory: "sync_comic_dir_2",
            chapters: nil,
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: []
        )
        LocalManager.shared.add(comic)

        AppData.shared.settings["syncLocalComics"] = .bool(false)
        let data = try DataSync.shared.exportAppData(sync: true)

        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: .utf8) else {
            XCTFail("Failed to read export archive")
            return
        }
        let entries = archive.map(\.path)
        XCTAssertFalse(entries.contains("local.db"))
    }
}
