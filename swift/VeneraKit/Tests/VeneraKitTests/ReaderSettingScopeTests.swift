import XCTest
@testable import VeneraKit

/// 阅读设置作用域生效链（漫画级 → 设备级 → 全局）回归测试（对齐上游 appdata.dart 语义）。
final class ReaderSettingScopeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppPaths.overrideDataPath = NSTemporaryDirectory() + "VeneraReaderScopeTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: AppPaths.overrideDataPath!, withIntermediateDirectories: true)
        let settings = AppData.shared.settings
        settings["comicSpecificSettings"] = .object([:])
        settings["deviceSpecificSettings"] = .object([:])
        settings["deviceId"] = .string("")
        settings["readerMode"] = .string("galleryLeftToRight")
        settings["enableTapToTurnPages"] = .bool(true)
    }

    override func tearDown() {
        AppPaths.overrideDataPath = nil
        super.tearDown()
    }

    private func enableComic(_ comicId: String = "c1", _ source: String = "src") {
        AppData.shared.settings.setComicSpecificSettingsEnabled(comicId: comicId, sourceKey: source, enabled: true)
    }

    /// 上游 setDeviceReaderSetting 只写值不写 enabled；开关由 UI 写入条目的 "enabled" 键。
    private func enableDevice() {
        let s = AppData.shared.settings
        let deviceId = s["deviceId"].stringValue ?? ""
        var all = s["deviceSpecificSettings"].objectValue ?? [:]
        var device = all[deviceId]?.objectValue ?? [:]
        device["enabled"] = .bool(true)
        all[deviceId] = .object(device)
        s["deviceSpecificSettings"] = .object(all)
    }

    func testGlobalFallbackWhenNoScopesEnabled() {
        let s = AppData.shared.settings
        XCTAssertEqual(
            s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue,
            "galleryLeftToRight"
        )
        XCTAssertFalse(s.isComicSpecificSettingsEnabled(comicId: "c1", sourceKey: "src"))
        XCTAssertFalse(s.isDeviceSpecificSettingsEnabled())
    }

    func testComicOverrideWinsOverDeviceAndGlobal() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        enableDevice()
        s.setReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode", value: .string("galleryRightToLeft"))
        enableComic()

        XCTAssertEqual(
            s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue,
            "galleryRightToLeft"
        )
        // 其他漫画不受该漫画覆盖影响：沿生效链落到设备级
        XCTAssertEqual(
            s.getReaderSetting(comicId: "c2", sourceKey: "src", key: "readerMode").stringValue,
            "continuousTopToBottom"
        )
    }

    func testComicValueWithoutEnableFlagFallsThroughToDevice() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        enableDevice()
        s.setReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode", value: .string("galleryRightToLeft"))
        // 值已写入但 enabled 开关未打开 → 生效链跳过漫画级，落到已启用的设备级
        XCTAssertFalse(s.isComicSpecificSettingsEnabled(comicId: "c1", sourceKey: "src"))
        XCTAssertEqual(
            s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue,
            "continuousTopToBottom"
        )
    }

    func testDeviceValueWithoutEnableFlagReadsGlobal() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        XCTAssertFalse(s.isDeviceSpecificSettingsEnabled())
        XCTAssertEqual(s.getDeviceReaderSetting(key: "readerMode").stringValue, "galleryLeftToRight")
    }

    func testDeviceEnabledFallsBackToGlobalForMissingKeys() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        enableDevice()

        XCTAssertTrue(s.isDeviceSpecificSettingsEnabled())
        XCTAssertEqual(s.getDeviceReaderSetting(key: "readerMode").stringValue, "continuousTopToBottom")
        // 未被设备覆盖的键沿生效链读全局
        XCTAssertEqual(s.getDeviceReaderSetting(key: "enableTapToTurnPages").boolValue, true)
        XCTAssertNil(s.getDeviceReaderSetting(key: "nonexistentKey").stringValue)
        XCTAssertEqual(
            s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue,
            "continuousTopToBottom"
        )
    }

    func testSetDeviceReaderSettingCreatesStableDeviceId() {
        let s = AppData.shared.settings
        XCTAssertEqual(s["deviceId"].stringValue ?? "", "")

        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        let id = s["deviceId"].stringValue ?? ""
        XCTAssertFalse(id.isEmpty)

        s.setDeviceReaderSetting(key: "enableTapToTurnPages", value: .bool(false))
        XCTAssertEqual(s["deviceId"].stringValue ?? "", id, "重复写入不得更换 deviceId")
    }

    func testComicWritesPreserveOtherComics() {
        let s = AppData.shared.settings
        s.setReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode", value: .string("galleryRightToLeft"))
        s.setReaderSetting(comicId: "c2", sourceKey: "src", key: "readerMode", value: .string("continuousTopToBottom"))
        enableComic("c1")

        XCTAssertEqual(
            s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue,
            "galleryRightToLeft",
            "第二部漫画写入不得清空第一部的独立设置"
        )
    }

    func testResetComicReaderSettingsRemovesWholeEntry() {
        let s = AppData.shared.settings
        enableComic()
        s.setReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode", value: .string("galleryRightToLeft"))

        s.resetComicReaderSettings(comicId: "c1", sourceKey: "src")

        XCTAssertFalse(s.isComicSpecificSettingsEnabled(comicId: "c1", sourceKey: "src"))
        XCTAssertEqual(
            s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue,
            "galleryLeftToRight"
        )
    }

    func testResetDeviceReaderSettingsKeepsDeviceId() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        enableDevice()
        let id = s["deviceId"].stringValue ?? ""

        s.resetDeviceReaderSettings()

        XCTAssertFalse(s.isDeviceSpecificSettingsEnabled())
        XCTAssertEqual(s.getDeviceReaderSetting(key: "readerMode").stringValue, "galleryLeftToRight")
        XCTAssertEqual(s["deviceId"].stringValue ?? "", id, "重置设置不得删除 deviceId 本身")
    }

    // MARK: - ReaderSettingScope 写入路由

    func testScopeWriteRoutesToComicScopeWhenEnabled() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        enableDevice()
        enableComic()

        let scope = ReaderSettingScope(comicId: "c1", sourceKey: "src")
        XCTAssertTrue(scope.isComicEnabled)
        scope.write("readerMode", value: .string("galleryTopToBottom"))

        XCTAssertEqual(s.getReaderSetting(comicId: "c1", sourceKey: "src", key: "readerMode").stringValue, "galleryTopToBottom")
        // 设备级值不受漫画作用域写入影响
        XCTAssertEqual(s.getDeviceReaderSetting(key: "readerMode").stringValue, "continuousTopToBottom")
    }

    func testScopeWriteFallsBackToGlobalWhenNoScopeEnabled() {
        let s = AppData.shared.settings
        let scope = ReaderSettingScope(comicId: "c1", sourceKey: "src")
        XCTAssertFalse(scope.isComicEnabled)
        XCTAssertFalse(scope.isDeviceEnabled)

        scope.write("readerMode", value: .string("galleryTopToBottom"))

        XCTAssertEqual(s["readerMode"].stringValue, "galleryTopToBottom", "无任何作用域开启时应写全局")
        XCTAssertEqual(scope.effective("readerMode").stringValue, "galleryTopToBottom")
    }

    func testScopeWithoutComicContextUsesDeviceChain() {
        let s = AppData.shared.settings
        s.setDeviceReaderSetting(key: "readerMode", value: .string("continuousTopToBottom"))
        enableDevice()

        let scope = ReaderSettingScope()
        XCTAssertFalse(scope.hasComicContext)
        XCTAssertEqual(scope.effective("readerMode").stringValue, "continuousTopToBottom")

        scope.write("readerMode", value: .string("galleryTopToBottom"))
        XCTAssertEqual(s.getDeviceReaderSetting(key: "readerMode").stringValue, "galleryTopToBottom", "设备开关开启时无上下文写入应落设备级")
    }
}
