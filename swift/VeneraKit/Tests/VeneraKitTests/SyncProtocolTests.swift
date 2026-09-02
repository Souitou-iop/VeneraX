import XCTest
@testable import VeneraKit

final class SyncProtocolTests: XCTestCase {
    func testNextSyncVersionBeatsBothLocalAndRemote() {
        XCTAssertEqual(SyncProtocol.nextSyncVersion(0, 0), 1)
        XCTAssertEqual(SyncProtocol.nextSyncVersion(5, 9), 10)
        XCTAssertEqual(SyncProtocol.nextSyncVersion(9, 5), 10)
    }

    func testShouldSkipStaleUpload() {
        // 本机落后：自动上传必须跳过
        XCTAssertTrue(SyncProtocol.shouldSkipStaleUpload(force: false, localVersion: 3, remoteMaxVersion: 5))
        // 本机不落后：允许上传
        XCTAssertFalse(SyncProtocol.shouldSkipStaleUpload(force: false, localVersion: 5, remoteMaxVersion: 5))
        XCTAssertFalse(SyncProtocol.shouldSkipStaleUpload(force: false, localVersion: 7, remoteMaxVersion: 5))
        // 强制上传永远允许
        XCTAssertFalse(SyncProtocol.shouldSkipStaleUpload(force: true, localVersion: 3, remoteMaxVersion: 5))
    }

    func testMergeIncomingDataVersion() {
        // 正常：只进不退
        XCTAssertEqual(SyncProtocol.mergeIncomingDataVersion(10, 20), 20)
        XCTAssertEqual(SyncProtocol.mergeIncomingDataVersion(20, 10), 20)
        // 负数与超可信上限的（如毫秒时间戳）忽略
        XCTAssertEqual(SyncProtocol.mergeIncomingDataVersion(10, -1), 10)
        XCTAssertEqual(SyncProtocol.mergeIncomingDataVersion(10, 1_700_000_000_000), 10)
        // 恰好在边界内可采纳
        XCTAssertEqual(SyncProtocol.mergeIncomingDataVersion(10, SyncProtocol.maxReasonableDataVersion), SyncProtocol.maxReasonableDataVersion)
    }

    func testMaxBackupVersionComparesNumerically() {
        let names: [String?] = [
            "20777-9.ios.venera",
            "20777-10.android.venera",
            "20778-2.linux.venera",
            "not-a-backup.txt",
            nil,
        ]
        XCTAssertEqual(SyncProtocol.maxBackupVersion(names), 10)
        XCTAssertEqual(SyncProtocol.maxBackupVersion([]), 0)
        XCTAssertEqual(SyncProtocol.maxBackupVersion([nil, "x.txt"]), 0)
    }

    func testRemoteBackupInfoParsing() {
        let info = RemoteBackupInfo.fromFileName("20777-42.ios.venera")
        XCTAssertEqual(info.version, 42)
        XCTAssertEqual(info.platform, "ios")
        XCTAssertEqual(info.days, 20777)

        // 无平台段
        let legacy = RemoteBackupInfo.fromFileName("20777-7.venera")
        XCTAssertEqual(legacy.version, 7)
        XCTAssertEqual(legacy.platform, "unknown")

        // 非法天数回退 0，版本取第一段
        let garbage = RemoteBackupInfo.fromFileName("abc-1.ios.venera")
        XCTAssertEqual(garbage.version, 1)
        XCTAssertEqual(garbage.platform, "ios")

        // 毫秒时间戳形式的天数段（旧版/外部归档）
        let ms = RemoteBackupInfo.fromFileName("1700000000000-3.android.venera")
        XCTAssertEqual(ms.version, 3)
        XCTAssertEqual(ms.platform, "android")
        // 毫秒值被直接当作时间戳使用（不乘 86400000）
        XCTAssertEqual(ms.date.timeIntervalSince1970, 1_700_000_000.0, accuracy: 1.5)
    }
}

extension SyncProtocolTests {
    func testAliyunVPSBackupShapeSelectsNumericFleetMaximum() {
        // 脱敏自 /tmp/venerax-webdav-audit.../venerax-backup-metadata.tsv，
        // 只保留文件名形状，不读取任何远端备份内容。
        let names: [String?] = [
            "20687-7524.win.venera",
            "20688-8231.macos.venera",
            "20688-8523.ios.venera",
            "20692-11612.android.venera",
            "20694-11619.ios.venera",
            "20697-11620.ios.venera",
            "20697-11621.ios.venera",
            "20698-11622.android.venera",
            "not-a-backup.venera.tmp",
            "readme.txt",
            nil,
        ]
        XCTAssertEqual(SyncProtocol.maxBackupVersion(names), 11622)
        XCTAssertEqual(RemoteBackupInfo.fromFileName("20698-11622.android.venera").fileNameForUpload,
                       "20698-11622.android.venera")
    }

    func testPendingPublishRequiresMatchingNameAndCompatibleSize() {
        XCTAssertTrue(SyncProtocol.isOwnPendingPublish(
            claimedFileName: "20698-11623.ios.venera", claimedSize: 100,
            remoteFileName: "20698-11623.ios.venera", remoteSize: 100
        ))
        XCTAssertTrue(SyncProtocol.isOwnPendingPublish(
            claimedFileName: "20698-11623.ios.venera", claimedSize: nil,
            remoteFileName: "20698-11623.ios.venera", remoteSize: 100
        ))
        XCTAssertFalse(SyncProtocol.isOwnPendingPublish(
            claimedFileName: "20698-11623.ios.venera", claimedSize: 100,
            remoteFileName: "20698-11623.ios.venera", remoteSize: 99
        ))
        XCTAssertFalse(SyncProtocol.isOwnPendingPublish(
            claimedFileName: "20698-11623.ios.venera", claimedSize: 100,
            remoteFileName: "20698-11624.ios.venera", remoteSize: 100
        ))
    }

    func testRetentionIsPerPlatformAndUsesNumericVersions() {
        let names: [String?] = (1...10).map { "20600-\($0).ios.venera" }
            + (1...10).map { "20600-\($0).android.venera" }
            + ["20698-100.ios.venera", "20698-99.android.venera"]
        let stale = SyncProtocol.backupsBeyondPlatformRetention(
            fileNames: names,
            newFileName: "20698-101.ios.venera",
            keepPerPlatform: 10
        )
        XCTAssertEqual(Set(stale), ["20600-1.ios.venera", "20600-2.ios.venera", "20600-1.android.venera"])
        XCTAssertEqual(SyncProtocol.sanitizedBackupRetention(nil), 10)
        XCTAssertEqual(SyncProtocol.sanitizedBackupRetention(1), 3)
        XCTAssertEqual(SyncProtocol.sanitizedBackupRetention(1000), 100)
    }

    func testSyncLocalComicsIsDevicePolicyInArchiveImport() {
        XCTAssertTrue(AppData.syncDisabledFields([]).contains("syncLocalComics"))
        XCTAssertTrue(AppData.syncDisabledFields([]).contains("syncLocalComicImages"))
    }
}
