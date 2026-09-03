import XCTest
import ZIPFoundation
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

    /// 修复回归：压缩包内设置成员必须固定命名为 appdata.json（Flutter 端
    /// 导入只认这个名字，此前导出为 syncdata.json 导致设置被静默跳过）；
    /// source_type_map.json 必须真正进包（此前路径解析错误导致永远缺失）。
    func testExportSettingsMemberFollowsFlutterProtocol() throws {
        let appData = AppData.shared
        appData.load()
        appData.settings["theme_mode"] = .string("dark")
        SourcePlatformResolver.shared.registerLegacyIntSourceKey(3, "ehentai")

        let exported = try DataSync.shared.exportAppData(sync: true)
        guard let archive = try? Archive(data: exported, accessMode: .read, pathEncoding: .utf8) else {
            XCTFail("archive unreadable")
            return
        }
        let names = archive.map(\.path)
        XCTAssertTrue(names.contains("appdata.json"))
        XCTAssertFalse(names.contains("syncdata.json"))
        XCTAssertTrue(names.contains("source_type_map.json"))
    }

    /// 修复回归：导入必须读取原版包裹格式 {"types": {intKey: sourceKey}}。
    func testImportReadsFlutterWrappedSourceTypeMap() throws {
        let staging = NSTemporaryDirectory() + "VeneraWrappedMap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let mapFile = AppPaths.join(staging, "source_type_map.json")
        try #"{"types":{"4242":"wrapped-src"}}"#.write(toFile: mapFile, atomically: true, encoding: .utf8)
        let archiveURL = URL(fileURLWithPath: staging).appendingPathComponent("backup.venera")
        guard let archive = try? Archive(url: archiveURL, accessMode: .create, preferredEncoding: .utf8) else {
            XCTFail("failed to create archive")
            return
        }
        try archive.addEntry(with: "source_type_map.json", fileURL: URL(fileURLWithPath: mapFile))
        try DataSync.shared.importAppData(try Data(contentsOf: archiveURL))
        // 键 4242 仅经该文件注册，resolve 成功即证明正确解析了包裹格式
        XCTAssertEqual(SourcePlatformResolver.shared.resolve(4242), "wrapped-src")
    }

    /// 修复回归：本端不消费的 Flutter 专有文件（domain 库 / 图片翻译）必须
    /// 经导入→导出原样中继，多设备链路经过 Swift 设备时数据不丢。
    func testRelayFilesSurviveRoundTrip() throws {
        try FileManager.default.createDirectory(
            atPath: AppPaths.join(dataPath, "data"), withIntermediateDirectories: true)
        try "domain-db-payload".write(
            toFile: AppPaths.join(dataPath, "data/venera.db"), atomically: true, encoding: .utf8)
        try "translation-db-payload".write(
            toFile: AppPaths.join(dataPath, "image_translation.db"), atomically: true, encoding: .utf8)
        try #"{"prefs":true}"#.write(
            toFile: AppPaths.join(dataPath, "image_translation_prefs.json"), atomically: true, encoding: .utf8)

        let exported = try DataSync.shared.exportAppData(sync: true)
        guard let archive = try? Archive(data: exported, accessMode: .read, pathEncoding: .utf8) else {
            XCTFail("archive unreadable")
            return
        }
        let names = archive.map(\.path)
        XCTAssertTrue(names.contains("data/venera.db"))
        XCTAssertTrue(names.contains("image_translation.db"))
        XCTAssertTrue(names.contains("image_translation_prefs.json"))

        // 清空数据目录（模拟中继设备）后导入，中继文件原样回归
        let files = try FileManager.default.contentsOfDirectory(atPath: dataPath)
        for file in files {
            try? FileManager.default.removeItem(atPath: AppPaths.join(dataPath, file))
        }
        try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        try DataSync.shared.importAppData(exported)
        XCTAssertEqual(
            try String(contentsOfFile: AppPaths.join(dataPath, "data/venera.db"), encoding: .utf8),
            "domain-db-payload")
        XCTAssertEqual(
            try String(contentsOfFile: AppPaths.join(dataPath, "image_translation.db"), encoding: .utf8),
            "translation-db-payload")
        XCTAssertEqual(
            try String(contentsOfFile: AppPaths.join(dataPath, "image_translation_prefs.json"), encoding: .utf8),
            #"{"prefs":true}"#)
    }

    /// 修复回归：合集封面必须随备份中继（配置在 appdata.json 只存文件名，
    /// 文件本体以 collection_covers/<名> 成员传输）；导出不做引用剪枝（对齐
    /// 原版全量打包），导入后按刚应用的新配置清理未引用封面（对齐原版
    /// 「复制后剪枝」，避免弃用封面随同步永久堆积）。
    func testCollectionCoverRelayRoundTrip() throws {
        let appData = AppData.shared
        appData.load()
        let coverDir = AppPaths.join(dataPath, "collection_covers")
        try FileManager.default.createDirectory(atPath: coverDir, withIntermediateDirectories: true)
        try "cover-a-payload".write(
            toFile: AppPaths.join(coverDir, "cover-a.jpg"), atomically: true, encoding: .utf8)
        try "stale-payload".write(
            toFile: AppPaths.join(coverDir, "cover-stale.jpg"), atomically: true, encoding: .utf8)
        ComicCollectionStore.shared.create(
            name: "Relay", members: [], customCover: "collection://cover-a.jpg")

        // 导出：两个文件全量入包（导出端不按引用过滤）
        let exported = try DataSync.shared.exportAppData(sync: true)
        guard let archive = try? Archive(data: exported, accessMode: .read, pathEncoding: .utf8) else {
            XCTFail("archive unreadable")
            return
        }
        let names = archive.map(\.path)
        XCTAssertTrue(names.contains("collection_covers/cover-a.jpg"))
        XCTAssertTrue(names.contains("collection_covers/cover-stale.jpg"))

        // 清空数据目录（模拟中继设备）后导入：被引用的封面原样回归，
        // 未被新配置引用的陈旧封面被剪枝删除
        let files = try FileManager.default.contentsOfDirectory(atPath: dataPath)
        for file in files {
            try? FileManager.default.removeItem(atPath: AppPaths.join(dataPath, file))
        }
        try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        try DataSync.shared.importAppData(exported)
        XCTAssertEqual(
            try String(contentsOfFile: AppPaths.join(coverDir, "cover-a.jpg"), encoding: .utf8),
            "cover-a-payload")
        XCTAssertFalse(FileIO.exists(AppPaths.join(coverDir, "cover-stale.jpg")))
        // 合集配置随设置同步回归，customCover 仍指向本地封面标记
        XCTAssertEqual(
            ComicCollectionStore.shared.all().first?.customCover, "collection://cover-a.jpg")
    }
}
