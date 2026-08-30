import XCTest
@testable import VeneraKit

final class LocalManagerTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "VeneraLocalTests-\(UUID().uuidString)"
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

    func testAddFindAndRemoveLocalComic() {
        let comic = LocalComic(
            id: "101",
            title: "Test Manga",
            subtitle: "Artist Name",
            tags: ["Action", "Adventure"],
            directory: "test_manga",
            chapters: ComicChapters(flatEntries: [
                ComicChapters.Entry(id: "ch1", title: "Chapter 1"),
                ComicChapters.Entry(id: "ch2", title: "Chapter 2"),
            ]),
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: ["ch1"],
            createdAt: Date(),
            description: "A test comic description"
        )

        LocalManager.shared.add(comic)
        XCTAssertEqual(LocalManager.shared.count, 1)

        guard let found = LocalManager.shared.find(id: "101", type: ComicID.local) else {
            XCTFail("Comic not found in database")
            return
        }
        XCTAssertEqual(found.title, "Test Manga")
        XCTAssertEqual(found.subtitle, "Artist Name")
        XCTAssertEqual(found.tags, ["Action", "Adventure"])
        XCTAssertEqual(found.downloadedChapters, ["ch1"])
        XCTAssertEqual(found.description, "A test comic description")
        XCTAssertTrue(found.hasChapters)

        // Find by name
        let byName = LocalManager.shared.findByName("Test Manga")
        XCTAssertNotNil(byName)
        XCTAssertEqual(byName?.id, "101")

        // Search
        let searchResults = LocalManager.shared.search("Artist")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.id, "101")

        // Remove
        LocalManager.shared.remove(id: "101", type: ComicID.local)
        XCTAssertNil(LocalManager.shared.find(id: "101", type: ComicID.local))
        XCTAssertEqual(LocalManager.shared.count, 0)
    }

    func testFindValidIdGeneration() {
        XCTAssertEqual(LocalManager.shared.findValidId(comicType: ComicID.local), "1")

        let comic1 = LocalComic(
            id: "1",
            title: "Comic 1",
            subtitle: "",
            tags: [],
            directory: "c1",
            chapters: nil,
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: []
        )
        LocalManager.shared.add(comic1)
        XCTAssertEqual(LocalManager.shared.findValidId(comicType: ComicID.local), "2")

        let comic5 = LocalComic(
            id: "5",
            title: "Comic 5",
            subtitle: "",
            tags: [],
            directory: "c5",
            chapters: nil,
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: []
        )
        LocalManager.shared.add(comic5)
        XCTAssertEqual(LocalManager.shared.findValidId(comicType: ComicID.local), "6")
    }

    func testGetImagesNaturalSorting() throws {
        let comicDir = AppPaths.join(LocalManager.shared.path, "natural_sort_test")
        let ch1Dir = AppPaths.join(comicDir, "ch1")
        try FileManager.default.createDirectory(atPath: ch1Dir, withIntermediateDirectories: true)

        // 写入 cover.jpg 与乱序数字页面
        try "cover".write(toFile: AppPaths.join(comicDir, "cover.jpg"), atomically: true, encoding: .utf8)
        try "p10".write(toFile: AppPaths.join(ch1Dir, "10.jpg"), atomically: true, encoding: .utf8)
        try "p2".write(toFile: AppPaths.join(ch1Dir, "2.jpg"), atomically: true, encoding: .utf8)
        try "p1".write(toFile: AppPaths.join(ch1Dir, "1.jpg"), atomically: true, encoding: .utf8)
        try "p20".write(toFile: AppPaths.join(ch1Dir, "20.jpg"), atomically: true, encoding: .utf8)
        try "meta".write(toFile: AppPaths.join(ch1Dir, "metadata.json"), atomically: true, encoding: .utf8)

        let comic = LocalComic(
            id: "10",
            title: "Natural Sort",
            subtitle: "",
            tags: [],
            directory: "natural_sort_test",
            chapters: ComicChapters(flatEntries: [ComicChapters.Entry(id: "ch1", title: "Chapter 1")]),
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: ["ch1"]
        )
        LocalManager.shared.add(comic)

        let images = LocalManager.shared.getImages(id: "10", type: ComicID.local, ep: 1)
        XCTAssertEqual(images.count, 4)
        XCTAssertTrue(images[0].hasSuffix("1.jpg"))
        XCTAssertTrue(images[1].hasSuffix("2.jpg"))
        XCTAssertTrue(images[2].hasSuffix("10.jpg"))
        XCTAssertTrue(images[3].hasSuffix("20.jpg"))
    }

    func testDeleteComicChapters() throws {
        let comicDir = AppPaths.join(LocalManager.shared.path, "delete_chapters_test")
        let ch1Dir = AppPaths.join(comicDir, "ch1")
        let ch2Dir = AppPaths.join(comicDir, "ch2")
        try FileManager.default.createDirectory(atPath: ch1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: ch2Dir, withIntermediateDirectories: true)

        let comic = LocalComic(
            id: "20",
            title: "Chapter Delete Test",
            subtitle: "",
            tags: [],
            directory: "delete_chapters_test",
            chapters: ComicChapters(flatEntries: [
                ComicChapters.Entry(id: "ch1", title: "Chapter 1"),
                ComicChapters.Entry(id: "ch2", title: "Chapter 2"),
            ]),
            cover: "cover.jpg",
            comicType: ComicID.local,
            downloadedChapters: ["ch1", "ch2"]
        )
        LocalManager.shared.add(comic)

        LocalManager.shared.deleteComicChapters(comic, chapters: ["ch1"])

        let updated = LocalManager.shared.find(id: "20", type: ComicID.local)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.downloadedChapters, ["ch2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ch1Dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ch2Dir))

        // 删除最后一个章节时，整部漫画从 comics 表移除
        if let current = updated {
            LocalManager.shared.deleteComicChapters(current, chapters: ["ch2"])
            XCTAssertNil(LocalManager.shared.find(id: "20", type: ComicID.local))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ch2Dir))
        }
    }
}
