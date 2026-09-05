import XCTest
@testable import VeneraKit

final class FollowUpdateScopeTests: XCTestCase {
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

    // MARK: - resolveFolders

    func testResolveFoldersAllFoldersKeepsStoreOrderAndCoversNewFolders() {
        XCTAssertEqual(
            FollowUpdateScope.resolveFolders(allFolders: true, selected: ["a"], existing: ["b", "c"]),
            ["b", "c"]
        )
    }

    func testResolveFoldersSelectionNarrowsToExistingInStoreOrder() {
        XCTAssertEqual(
            FollowUpdateScope.resolveFolders(allFolders: false, selected: ["c", "ghost", "a", "a"], existing: ["b", "a", "c"]),
            ["a", "c"]
        )
    }

    func testResolveFoldersEmptySelectionYieldsNothing() {
        XCTAssertTrue(FollowUpdateScope.resolveFolders(allFolders: false, selected: [], existing: ["a"]).isEmpty)
    }

    // MARK: - parseFixedTime / isPastFixedTime

    func testParseFixedTimeAcceptsValidAndRejectsMalformed() {
        XCTAssertEqual(FollowUpdateScope.parseFixedTime("09:05")?.hour, 9)
        XCTAssertEqual(FollowUpdateScope.parseFixedTime("23:59")?.minute, 59)
        XCTAssertNil(FollowUpdateScope.parseFixedTime("24:00"))
        XCTAssertNil(FollowUpdateScope.parseFixedTime("9:60"))
        XCTAssertNil(FollowUpdateScope.parseFixedTime("9"))
        XCTAssertNil(FollowUpdateScope.parseFixedTime(""))
        XCTAssertNil(FollowUpdateScope.parseFixedTime("ab:cd"))
    }

    func testIsPastFixedTimeGatesByTimeOfDay() {
        let now = components(2026, 9, 5, 8, 0)
        XCTAssertTrue(FollowUpdateScope.isPastFixedTime("", now: now))
        XCTAssertTrue(FollowUpdateScope.isPastFixedTime("garbage", now: now))
        XCTAssertFalse(FollowUpdateScope.isPastFixedTime("09:30", now: now))
        XCTAssertTrue(FollowUpdateScope.isPastFixedTime("08:00", now: now))
        XCTAssertTrue(FollowUpdateScope.isPastFixedTime("07:59", now: now))
    }

    private func components(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - isDue

    func testIsDueNeverCheckedIsAlwaysDue() {
        XCTAssertTrue(FollowUpdateScope.isDue(lastCheck: nil))
    }

    func testIsDueHonorsInterval() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let checked = now.timeIntervalSince1970 - 23 * 3_600
        XCTAssertFalse(FollowUpdateScope.isDue(lastCheck: Int(checked * 1000), now: now, intervalHours: 24))
        XCTAssertTrue(FollowUpdateScope.isDue(lastCheck: Int(checked * 1000), now: now, intervalHours: 12))
        // 默认 24 小时对齐旧的「一天内查过就不再查」。
        XCTAssertFalse(FollowUpdateScope.isDue(lastCheck: Int(checked * 1000), now: now))
        XCTAssertTrue(FollowUpdateScope.isDue(lastCheck: Int(checked * 1000 - 3600 * 1000), now: now))
    }

    // MARK: - 任务记录向后兼容

    func testTaskDecodingWithoutFoldersKeepsLegacyHistory() throws {
        // 持久化用 JSONEncoder 默认 Date 编码（reference-date 秒，Double）。
        let legacy = """
        {"id":"t1","manual":true,"createdAt":810298799.4,"status":"completed",
         "total":3,"current":3,"updated":1,"errors":0}
        """
        let task = try JSONDecoder().decode(FollowUpdateTask.self, from: Data(legacy.utf8))
        XCTAssertNil(task.folders)
        XCTAssertEqual(task.total, 3)

        let multi = """
        {"id":"t2","manual":false,"createdAt":810298799.4,"status":"running",
         "folders":["A","B"],"total":0,"current":0,"updated":0,"errors":0}
        """
        let foldersTask = try JSONDecoder().decode(FollowUpdateTask.self, from: Data(multi.utf8))
        XCTAssertEqual(foldersTask.folders, ["A", "B"])
    }

    // MARK: - 默认值与迁移

    func testDefaultsMatchUpstreamSemantics() {
        let appData = AppData()
        XCTAssertEqual(appData.settings[FollowUpdateScope.intervalKey].intValue, 24)
        XCTAssertEqual(appData.settings[FollowUpdateScope.checkOnStartKey].boolValue, true)
        XCTAssertEqual(appData.settings[FollowUpdateScope.fixedTimeKey].stringValue, "")
        XCTAssertEqual(appData.settings[FollowUpdateScope.allFoldersKey].boolValue, false)
        XCTAssertEqual(appData.settings[FollowUpdateScope.foldersKey].arrayValue?.count, 0)
    }

    func testDisableSyncTreatsScopeAsDeviceLocal() throws {
        let appData = AppData()
        appData.settings[FollowUpdateScope.allFoldersKey] = .bool(true)
        appData.settings[FollowUpdateScope.foldersKey] = .array([.string("a")])
        appData.settings[FollowUpdateScope.migratedKey] = .bool(true)
        appData.saveData(sync: false)

        let syncJSON = JSON.decode(try String(contentsOfFile: AppPaths.join(dataPath, "syncdata.json"), encoding: .utf8))!
        let synced = syncJSON["settings"].objectValue ?? [:]
        XCTAssertNil(synced[FollowUpdateScope.allFoldersKey])
        XCTAssertNil(synced[FollowUpdateScope.foldersKey])
        XCTAssertNil(synced[FollowUpdateScope.migratedKey])
        // 周期偏好是普通设置，应随同步上传。
        XCTAssertNotNil(synced[FollowUpdateScope.intervalKey])
    }
}
