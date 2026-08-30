import XCTest
@testable import VeneraKit

/// .venera 备份导出→导入往返测试（数据兼容的核心验收）。
final class SyncRoundTripTests: XCTestCase {
    private var dataPath: String!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraSyncTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        Log.setMinimumLevel(.none)
    }

    override func tearDown() {
        AppPaths.overrideDataPath = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        Log.setMinimumLevel(.info)
        super.tearDown()
    }

    func testExportImportRoundTrip() throws {
        // 1) 造数据：历史、收藏、稍后读、设置、源脚本
        let history = HistoryManager(dataPath: dataPath)
        history.addHistory(History(id: "c1", type: 3, title: "Comic One", subtitle: "a", cover: "cv", ep: 2, page: 10))
        history.addReadingTime(id: "c1", type: 3, title: "Comic One", subtitle: "a", cover: "cv", durationMs: 12345)

        let favorites = LocalFavoritesManager(dataPath: dataPath)
        favorites.addFolder("Read")
        favorites.addFavorite("Read", FavoriteItem(id: "m1", name: "Manga", coverPath: "c", author: "a", type: 3, tags: ["x"]))

        let readLater = ReadLaterManager(dataPath: dataPath)
        readLater.add(id: "r1", title: "Later", subtitle: "", cover: "", type: 3, tags: [])

        let appData = AppData.shared
        appData.load()
        appData.settings["theme_mode"] = .string("dark")
        appData.settings["readerMode"] = .string("continuousTopToBottom")

        try FileManager.default.createDirectory(atPath: AppPaths.comicSourcePath, withIntermediateDirectories: true)
        let sourceJS = "class Komiic extends ComicSource { name='Komiic'; key='Komiic'; version='1'; }"
        try sourceJS.write(toFile: AppPaths.join(AppPaths.comicSourcePath, "komiic.js"), atomically: true, encoding: .utf8)
        SourcePlatformResolver.shared.registerLegacyIntSourceKey(3, "ehentai")

        // 2) 导出
        let sync = DataSync.shared
        let exported = try sync.exportAppData(sync: true)
        XCTAssertFalse(exported.isEmpty)

        // 3) 清空数据目录（模拟新设备）
        let files = try FileManager.default.contentsOfDirectory(atPath: dataPath)
        for file in files {
            try? FileManager.default.removeItem(atPath: AppPaths.join(dataPath, file))
        }
        try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        // 4) 导入
        try sync.importAppData(exported)

        // 5) 逐库对拍
        let restoredHistory = HistoryManager(dataPath: dataPath)
        let restoredItem = restoredHistory.findHistory(id: "c1", type: 3)
        XCTAssertEqual(restoredItem?.title, "Comic One")
        XCTAssertEqual(restoredItem?.ep, 2)
        XCTAssertEqual(restoredItem?.page, 10)

        let restoredFavorites = LocalFavoritesManager(dataPath: dataPath)
        XCTAssertTrue(restoredFavorites.getFolders().contains("Read"))
        XCTAssertEqual(restoredFavorites.getComics("Read").first?.name, "Manga")

        let restoredReadLater = ReadLaterManager(dataPath: dataPath)
        XCTAssertEqual(restoredReadLater.getAll().first?.title, "Later")

        // 设置（syncdata 剔除设备本地键后仍保留可同步键）
        XCTAssertEqual(appData.settings["theme_mode"].stringValue, "dark")
        XCTAssertEqual(appData.settings["readerMode"].stringValue, "continuousTopToBottom")

        // 源脚本文件恢复
        XCTAssertTrue(FileIO.exists(AppPaths.join(AppPaths.comicSourcePath, "komiic.js")))

        // int 注册表恢复
        XCTAssertEqual(SourcePlatformResolver.shared.resolve(3), "ehentai")
    }

    func testUploadVersionStampingLogic() {
        // 版本推进逻辑（上传用 nextSyncVersion，下载只进不退）
        let local = 5
        let remote = 9
        XCTAssertEqual(SyncProtocol.nextSyncVersion(local, remote), 10)
        XCTAssertTrue(SyncProtocol.shouldSkipStaleUpload(force: false, localVersion: local, remoteMaxVersion: remote))
    }
}
