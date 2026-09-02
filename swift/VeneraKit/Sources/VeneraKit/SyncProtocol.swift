import Foundation

/// WebDAV 数据同步的方向/版本判定纯函数。
///
/// 与 Flutter 版 `lib/utils/sync_protocol.dart` 逐函数对齐，两侧必须
/// 保持一致，否则新旧版本设备无法共存于同一同步组。协议概要：
///
/// 服务器保存整库快照，命名 `<days-since-epoch>-<version>.<platform>.venera`。
/// 数字 `version` 是唯一排序信号：大者胜（last-writer-wins）。
/// 设备通过 `appdata.settings['dataVersion']` 记录自身位置。
public enum SyncProtocol {
    /// 新上传备份应盖的版本号：必须同时高于本地版本与服务器最大版本。
    public static func nextSyncVersion(_ localVersion: Int, _ remoteMaxVersion: Int) -> Int {
        max(localVersion, remoteMaxVersion) + 1
    }

    /// 本地落后于服务器时，自动上传必须跳过（先下载追赶）。
    /// force（手动按钮/本地导入/CLI）是明确的「以本机为准」，绕过该保护。
    public static func shouldSkipStaleUpload(
        force: Bool,
        localVersion: Int,
        remoteMaxVersion: Int
    ) -> Bool {
        !force && remoteMaxVersion > localVersion
    }

    /// 可信同步版本上限。正常 +1 递增十年也到不了 10 万；外部归档若带
    /// 毫秒时间戳（~1.7e12）会被当成垃圾忽略。
    public static let maxReasonableDataVersion = 10_000_000

    /// 合并外来备份的 dataVersion：只进不退；超出可信范围的直接忽略。
    public static func mergeIncomingDataVersion(_ localVersion: Int, _ incomingVersion: Int) -> Int {
        if incomingVersion < 0 || incomingVersion > maxReasonableDataVersion {
            return localVersion
        }
        return max(localVersion, incomingVersion)
    }

    /// 平台后缀必须与 Flutter 版一致，供备份文件名和保留策略复用。
    public static var platformTag: String {
#if os(iOS)
        return "ios"
#elseif os(macOS)
        return "macos"
#elseif os(Windows)
        return "win"
#elseif os(Linux)
        return "linux"
#else
        return "unknown"
#endif
    }

    /// 从文件名列表中取最高备份版本号（数字比较而非字典序；
    /// 忽略非 `.venera` 条目），无有效条目时为 0。
    public static func maxBackupVersion<S: Sequence>(_ fileNames: S) -> Int where S.Element == String? {
        fileNames.compactMap { name in
            guard let name, name.hasSuffix(".venera") else { return nil }
            return RemoteBackupInfo.fromFileName(name).version
        }.max() ?? 0
    }

    /// 与 Flutter `isOwnPendingPublish` 对齐：只有文件名相同且已知大小不冲突时，
    /// 才能把一次 PUT 后客户端未确认的远端文件认领回来。
    public static func isOwnPendingPublish(
        claimedFileName: String?, claimedSize: Int?,
        remoteFileName: String, remoteSize: Int?
    ) -> Bool {
        guard claimedFileName == remoteFileName else { return false }
        if let claimedSize, let remoteSize, claimedSize != remoteSize { return false }
        return true
    }

    public static let backupRetentionPerPlatform = 10

    public static func sanitizedBackupRetention(_ value: Int?) -> Int {
        guard let value else { return backupRetentionPerPlatform }
        return min(100, max(3, value))
    }

    /// 返回上传成功后可删除的旧备份。分平台按数字版本排序，且永不返回新文件。
    public static func backupsBeyondPlatformRetention(
        fileNames: [String?], newFileName: String, keepPerPlatform: Int
    ) -> [String] {
        let keep = sanitizedBackupRetention(keepPerPlatform)
        var groups: [String: [RemoteBackupInfo]] = [:]
        for name in fileNames.compactMap({ $0 }) where name.hasSuffix(".venera") {
            let info = RemoteBackupInfo.fromFileName(name)
            groups[info.platform, default: []].append(info)
        }
        if !fileNames.contains(where: { $0 == newFileName }) {
            let info = RemoteBackupInfo.fromFileName(newFileName)
            groups[info.platform, default: []].append(info)
        }
        return groups.values.flatMap { group in
            group.sorted { lhs, rhs in
                if lhs.version != rhs.version { return lhs.version > rhs.version }
                return lhs.fileName > rhs.fileName
            }.dropFirst(keep).map(\.fileName).filter { $0 != newFileName }
        }
    }
}

/// 远端备份文件名的解析：`<days>-<version>.<platform>.venera`。
/// 解析是宽容的：任何段解析失败都落回 0/unknown，不拒绝整个文件名
/// （与原版 RemoteBackupInfo.fromFileName 一致）。
public struct RemoteBackupInfo: Equatable, Sendable {
    public let fileName: String
    public let days: Int
    public let version: Int
    public let platform: String
    public let date: Date

    private static let msPerDay = 86_400_000
    private static let maxValidMs = 8_640_000_000_000_000

    public static func fromFileName(_ name: String, modifiedTime: Date? = nil) -> RemoteBackupInfo {
        let base = String(name.dropLast(name.hasSuffix(".venera") ? ".venera".count : 0))
        let parts = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let days = parts.first.flatMap(Int.init) ?? 0
        let versionSegment = parts.count > 1 ? parts[1] : ""
        let dotParts = versionSegment.split(separator: ".").map(String.init)
        let version = dotParts.first.flatMap(Int.init) ?? 0
        let platform = dotParts.count >= 2 ? dotParts[1] : "unknown"

        // 天数段通常为 days-since-epoch（~5 位）；旧/外部备份可能是完整毫秒
        // 时间戳（~13 位）。小值乘 86400000，大值按毫秒处理，避免溢出。
        var ms = abs(days) <= maxValidMs / msPerDay ? days * msPerDay : days
        ms = min(max(ms, -maxValidMs), maxValidMs)
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)

        return RemoteBackupInfo(
            fileName: name,
            days: days,
            version: version,
            platform: platform,
            date: modifiedTime ?? date
        )
    }

    public var fileNameForUpload: String {
        "\(days)-\(version).\(platform).venera"
    }
}
