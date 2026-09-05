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

    func testStableWebDAVLibraryIDMatchesFlutterNormalizationAndMD5() {
        XCTAssertEqual(
            stableWebdavLibraryId(" HTTPS://Example.com/webdav/// ", " Alice ", " Comics/// "),
            "4ceb4c3289f4"
        )
        XCTAssertEqual(
            stableWebdavLibraryId("https://example.com/webdav", "Alice", ""),
            "d93dd66a1972"
        )
    }

    func testWebDAVLibraryConfigDefaultsDetectLinkedFoldersToFalse() {
        let json = JSON.object([
            "url": .string("https://example.com/webdav"),
            "user": .string("alice"),
            "pass": .string("secret"),
            "root": .string("Comics"),
        ])

        let config = WebdavLibraryConfig.fromJson(json)
        XCTAssertEqual(config?.id, "cf7061c2729d")
        XCTAssertEqual(config?.sourceKey, WebDAVLibraryStore.legacySourceKey)
        XCTAssertFalse(config?.detectLinkedFolders ?? true)
        XCTAssertEqual(config?.toJson()["detectLinkedFolders"].boolValue, false)
    }

    func testWebDAVLibraryStorePrefersCanonicalKeyEvenWhenItIsEmpty() {
        let appData = AppData.shared
        let canonical = appData.settings[WebDAVLibraryStore.settingsKey]
        let legacy = appData.settings[WebDAVLibraryStore.legacySettingsKey]
        defer {
            appData.settings[WebDAVLibraryStore.settingsKey] = canonical
            appData.settings[WebDAVLibraryStore.legacySettingsKey] = legacy
            appData.saveData(sync: false)
        }

        appData.settings[WebDAVLibraryStore.settingsKey] = .array([])
        appData.settings[WebDAVLibraryStore.legacySettingsKey] = .array([
            .object([
                "id": .string("stale-legacy-id"),
                "sourceKey": .string("stale-legacy-source"),
                "url": .string("https://legacy.example/webdav"),
            ])
        ])

        XCTAssertTrue(WebDAVLibraryStore.shared.all().isEmpty)
    }

    func testWebDAVLibraryStoreReadsLegacyKeyAndWritesCanonicalFlutterKey() {
        let appData = AppData.shared
        let canonical = appData.settings[WebDAVLibraryStore.settingsKey]
        let legacy = appData.settings[WebDAVLibraryStore.legacySettingsKey]
        defer {
            appData.settings[WebDAVLibraryStore.settingsKey] = canonical
            appData.settings[WebDAVLibraryStore.legacySettingsKey] = legacy
            appData.saveData(sync: false)
        }

        appData.settings[WebDAVLibraryStore.settingsKey] = .null
        appData.settings[WebDAVLibraryStore.legacySettingsKey] = .array([
            .object([
                "id": .string("legacy-id"),
                "sourceKey": .string("legacy-source"),
                "name": .string("Legacy NAS"),
                "url": .string("https://legacy.example/webdav"),
                "user": .string("alice"),
                "pass": .string("secret"),
                "root": .string("Comics"),
            ])
        ])

        XCTAssertEqual(WebDAVLibraryStore.shared.all().map(\.name), ["Legacy NAS"])
        XCTAssertFalse(WebDAVLibraryStore.shared.all()[0].detectLinkedFolders)

        let added = WebDAVLibraryStore.shared.add(
            name: "New NAS",
            url: "https://new.example/webdav/",
            user: " bob ",
            pass: "secret",
            root: " /Manga/ ",
            detectLinkedFolders: true
        )

        XCTAssertEqual(appData.settings[WebDAVLibraryStore.settingsKey].arrayValue?.count, 2)
        XCTAssertEqual(appData.settings[WebDAVLibraryStore.legacySettingsKey].arrayValue?.count, 1)
        XCTAssertTrue(appData.settings[WebDAVLibraryStore.settingsKey].arrayValue?.contains { $0["id"].stringValue == added.id } == true)
        XCTAssertTrue(WebDAVLibraryStore.shared.find(id: added.id)?.detectLinkedFolders == true)
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

        let tasksRoute = await AppLinksHandler.parse(url: URL(string: "venera://tasks")!)
        XCTAssertEqual(tasksRoute, .tasks)
    }
}

extension MoreFeaturesExtendedTests {
    func testSourceURLStripsCredentialsAndBuildsBasicAuth() {
        let source = SourceURL("http://alice:p%40ss@localhost:8080/source.js")
        XCTAssertEqual(source.url, "http://localhost:8080/source.js")
        XCTAssertEqual(source.headers()["Authorization"], "Basic YWxpY2U6cEBzcw==")
    }

    func testSuggestedScriptFilenameHandlesQueryAndMissingSuffix() {
        XCTAssertEqual(
            SourceURL.suggestedScriptFilename("http://localhost:8080/source.js?token=abc"),
            "source.js"
        )
        XCTAssertEqual(
            SourceURL.suggestedScriptFilename("https://example.com/p/lib.js;jsessionid=x"),
            "lib.js"
        )
        XCTAssertEqual(
            SourceURL.suggestedScriptFilename("https://example.com/get?file=source.js"),
            "get.js"
        )
        XCTAssertTrue(SourceURL.suggestedScriptFilename("https://example.com/").hasSuffix(".js"))
        XCTAssertTrue(SourceURL.suggestedScriptFilename("not a url at all").hasSuffix(".js"))
    }

    func testSourceURLAcceptsLocalhostAndIPv6ButRejectsOtherSchemes() {
        XCTAssertTrue(SourceURL.isValid("http://localhost:8080/source.js"))
        XCTAssertTrue(SourceURL.isValid("https://[::1]/source.js"))
        XCTAssertFalse(SourceURL.isValid("file:///tmp/source.js"))
    }
}
