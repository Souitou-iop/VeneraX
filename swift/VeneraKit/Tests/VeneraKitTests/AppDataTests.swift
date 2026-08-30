import XCTest
@testable import VeneraKit

final class AppDataTests: XCTestCase {
    private var dataPath: String!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraKitTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AppPaths.overrideDataPath = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    func testDefaultsContainCoreKeys() {
        let appData = AppData()
        XCTAssertEqual(appData.settings["readerMode"].stringValue, "galleryLeftToRight")
        XCTAssertEqual(appData.settings["theme_mode"].stringValue, "system")
        XCTAssertEqual(appData.settings["color"].stringValue, "system")
        XCTAssertEqual(appData.settings["preloadImageCount"].intValue, 4)
        XCTAssertEqual(appData.settings["comicTileScale"].doubleValue, 1.0)
        XCTAssertEqual(appData.settings["webdav"].arrayValue?.count, 0)
        XCTAssertTrue(appData.settings["dataVersion"].intValue == 0)
        XCTAssertEqual(appData.settings["imageTranslationInpaintMode"].stringValue, "smart")
    }

    func testSettingPersistsAndSyncdataStripsDeviceLocalFields() throws {
        let appData = AppData()
        appData.settings["theme_mode"] = .string("dark")
        appData.settings["proxy"] = .string("127.0.0.1:7890")
        appData.settings["deviceId"] = .string("device-1")
        appData.settings["webdav"] = .array([.string("http://dav")])
        appData.saveData(sync: false)

        let appdataJSON = JSON.decode(try String(contentsOfFile: AppPaths.join(dataPath, "appdata.json"), encoding: .utf8))!
        XCTAssertEqual(appdataJSON["settings"]["theme_mode"].stringValue, "dark")
        XCTAssertEqual(appdataJSON["settings"]["proxy"].stringValue, "127.0.0.1:7890")

        let syncJSON = JSON.decode(try String(contentsOfFile: AppPaths.join(dataPath, "syncdata.json"), encoding: .utf8))!
        XCTAssertEqual(syncJSON["settings"]["theme_mode"].stringValue, "dark")
        XCTAssertNil(syncJSON["settings"].objectValue?["proxy"], "proxy 是设备本地键，不得进入 syncdata")
        XCTAssertNil(syncJSON["settings"].objectValue?["deviceId"])
        XCTAssertNil(syncJSON["settings"].objectValue?["webdav"])
        XCTAssertNil(syncJSON["settings"].objectValue?["appLockType"])
        // 可同步键必须在
        XCTAssertEqual(syncJSON["settings"]["webdavBackupRetention"].intValue, 10)
    }

    func testCustomDisableSyncFields() throws {
        let appData = AppData()
        appData.settings["disableSyncFields"] = .string("color, readerMode")
        appData.saveData(sync: false)

        let syncJSON = JSON.decode(try String(contentsOfFile: AppPaths.join(dataPath, "syncdata.json"), encoding: .utf8))!
        XCTAssertNil(syncJSON["settings"].objectValue?["color"])
        XCTAssertNil(syncJSON["settings"].objectValue?["readerMode"])
        XCTAssertEqual(syncJSON["settings"]["theme_mode"].stringValue, "system")
    }

    func testSearchHistoryDeduplicationAndLimit() {
        let appData = AppData()
        for index in 0..<60 {
            appData.addSearchHistory("kw\(index)")
        }
        XCTAssertEqual(appData.searchHistory.count, 50)
        XCTAssertEqual(appData.searchHistory.first, "kw59")
        appData.addSearchHistory("kw30")
        XCTAssertEqual(appData.searchHistory.first, "kw30")
        XCTAssertEqual(appData.searchHistory.filter { $0 == "kw30" }.count, 1)
        appData.removeSearchHistory("kw30")
        XCTAssertFalse(appData.searchHistory.contains("kw30"))
        appData.clearSearchHistory()
        XCTAssertTrue(appData.searchHistory.isEmpty)
    }

    func testSaveLoadRoundTrip() {
        let appData = AppData()
        appData.settings["comicDisplayMode"] = .string("brief")
        appData.settings["readerPageSpacing"] = .double(12.5)
        appData.addSearchHistory("hello")
        appData.setImplicitValue("taskHistory", .object(["a": .int(1)]))

        let reloaded = AppData()
        reloaded.load()
        XCTAssertEqual(reloaded.settings["comicDisplayMode"].stringValue, "brief")
        XCTAssertEqual(reloaded.settings["readerPageSpacing"].doubleValue, 12.5)
        XCTAssertEqual(reloaded.searchHistory, ["hello"])
        XCTAssertEqual(reloaded.implicitValue("taskHistory")["a"].intValue, 1)
        XCTAssertFalse(reloaded.settings["deviceId"].stringValue!.isEmpty)
    }

    func testSyncDataSkipsDeviceLocalKeysAndNeverRollsBackVersion() {
        let appData = AppData()
        appData.settings["dataVersion"] = .int(42)
        appData.settings["theme_mode"] = .string("light")

        let remote: JSON = .object([
            "settings": .object([
                "theme_mode": .string("dark"),
                "proxy": .string("evil:1080"), // 设备本地键必须被忽略
                "dataVersion": .int(10), // 落后于本地，不得回退
            ]),
            "searchHistory": .array([.string("remote-kw")]),
            "implicitData": .object([
                "sourceTypeRegistry": .object(["3": .string("ehentai")]),
                "deviceOnlyThing": .string("ignored"),
            ]),
        ])
        appData.syncData(remote)

        XCTAssertEqual(appData.settings["theme_mode"].stringValue, "dark")
        XCTAssertEqual(appData.settings["proxy"].stringValue, "system")
        XCTAssertEqual(appData.settings["dataVersion"].intValue, 42)
        XCTAssertEqual(appData.searchHistory, ["remote-kw"])
        XCTAssertEqual(appData.implicitValue("sourceTypeRegistry")["3"].stringValue, "ehentai")
        XCTAssertNil(appData.implicitValue("deviceOnlyThing").objectValue)
    }

    func testSyncDataAdoptsForwardVersion() {
        let appData = AppData()
        appData.settings["dataVersion"] = .int(5)
        appData.syncData(.object([
            "settings": .object(["dataVersion": .int(7)]),
        ]))
        XCTAssertEqual(appData.settings["dataVersion"].intValue, 7)
    }

    func testSettingsChangeNotification() {
        let appData = AppData()
        let expectation = expectation(description: "notified")
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            var keys: [String] = []
            func append(_ key: String) {
                lock.lock()
                keys.append(key)
                lock.unlock()
            }
        }
        let box = ResultBox()
        let token = appData.onSettingsChanged.add { key in
            box.append(key)
            if key == "color" { expectation.fulfill() }
        }
        appData.settings["color"] = .string("red")
        // dataVersion 变更不通知（对齐原版）
        appData.settings["dataVersion"] = .int(1)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(box.keys, ["color"])
        token()
    }
}
