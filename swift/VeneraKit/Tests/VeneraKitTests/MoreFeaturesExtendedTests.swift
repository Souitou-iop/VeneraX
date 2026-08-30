import XCTest
@testable import VeneraKit

final class MoreFeaturesExtendedTests: XCTestCase {
    func testSourceCatalogVersionComparison() {
        let mgr = SourceCatalogManager.shared
        XCTAssertEqual(mgr.compareVersions("1.2.0", "1.1.9"), 1)
        XCTAssertEqual(mgr.compareVersions("1.0.0", "1.0.0"), 0)
        XCTAssertEqual(mgr.compareVersions("1.0.0", "1.0.1"), -1)
        XCTAssertEqual(mgr.compareVersions("2.0", "1.9.9"), 1)
        XCTAssertEqual(mgr.compareVersions("1.1", "1.1.0"), 0)
    }

    func testCatalogSourceItemJsonParsing() {
        let json = JSON.object([
            "key": .string("test_source"),
            "name": .string("Test Source"),
            "version": .string("1.5.0"),
            "url": .string("https://example.com/source.js"),
            "description": .string("Test Description"),
            "author": .string("Author"),
        ])
        guard let item = CatalogSourceItem.fromJson(json) else {
            XCTFail("Failed to parse CatalogSourceItem")
            return
        }
        XCTAssertEqual(item.key, "test_source")
        XCTAssertEqual(item.name, "Test Source")
        XCTAssertEqual(item.version, "1.5.0")
        XCTAssertEqual(item.url, "https://example.com/source.js")
    }

    func testWebDAVLibraryStore() {
        let store = WebDAVLibraryStore.shared

        let lib = store.add(name: "Home NAS", url: "https://nas.local:5005", user: "admin", pass: "secret", root: "Comics")
        XCTAssertEqual(lib.name, "Home NAS")
        XCTAssertEqual(lib.root, "Comics")

        let found = store.find(id: lib.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.url, "https://nas.local:5005")

        // Update
        store.update(id: lib.id, name: "Home NAS Updated")
        XCTAssertEqual(store.find(id: lib.id)?.name, "Home NAS Updated")

        // Delete
        store.remove(id: lib.id)
        XCTAssertNil(store.find(id: lib.id))
    }

    func testAppLinksHandler() async {
        // 1. Comic link
        guard let comicUrl = URL(string: "venera://comic?id=999&source=komiic") else { return }
        let comicRoute = await AppLinksHandler.parse(url: comicUrl)
        XCTAssertEqual(comicRoute, .comic(sourceKey: "komiic", id: "999"))

        // 2. Install script link
        guard let installUrl = URL(string: "venera://source/install?url=https://example.com/s.js") else { return }
        let installRoute = await AppLinksHandler.parse(url: installUrl)
        XCTAssertEqual(installRoute, .installSource(url: "https://example.com/s.js"))

        // 3. Sync config link
        guard let syncUrl = URL(string: "venera://sync/config?url=https://dav.test&user=usr&pass=pwd") else { return }
        let syncRoute = await AppLinksHandler.parse(url: syncUrl)
        XCTAssertEqual(syncRoute, .syncConfig(url: "https://dav.test", user: "usr", pass: "pwd"))
    }
}
