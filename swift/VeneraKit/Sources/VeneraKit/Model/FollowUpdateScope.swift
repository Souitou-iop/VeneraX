import Foundation

/// 追更范围与检查周期（对齐上游 follow_update_scope.dart）。
///
/// 范围决定追更覆盖哪些收藏夹：「全部收藏夹」（自动覆盖以后新建的）或
/// 明确的列表。范围是设备本地配置——各设备的收藏夹内容不同，某台设备
/// 追哪些是它自己的选择，不入 WebDAV 同步；检查周期是普通偏好，随同步。
public enum FollowUpdateScope {
    public static let foldersKey = "followUpdatesFolders"
    public static let allFoldersKey = "followUpdatesAllFolders"
    public static let intervalKey = "followUpdatesIntervalHours"
    public static let checkOnStartKey = "followUpdatesCheckOnStart"
    public static let fixedTimeKey = "followUpdatesFixedTime"
    static let migratedKey = "followUpdatesFoldersMigrated"

    /// 本设置取代的单收藏夹键。留在磁盘上让旧版本仍能读回自己的选择，
    /// 只被下方迁移逻辑读取。
    static let legacyFolderKey = "followUpdatesFolder"

    public static let intervalOptions: [Int] = [1, 3, 6, 12, 24, 48, 72, 168]

    /// 对齐旧的「一天内查过就不再查」硬编码门槛。
    public static let defaultIntervalHours = 24

    private static var settings: AppData.SettingsProxy { AppData.shared.settings }

    public static var allFolders: Bool {
        settings[allFoldersKey].boolValue == true
    }

    /// 磁盘上原样保存的选择，可能包含已不存在的收藏夹。
    public static var selected: [String] {
        settings[foldersKey].arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// 用户是否配置过追更。开启「全部收藏夹」但库里还没有收藏夹时也为 true。
    public static var isConfigured: Bool {
        allFolders || !selected.isEmpty
    }

    /// 把保存的选择收窄到仍然存在的收藏夹，保持库内顺序并去重。纯函数。
    public static func resolveFolders(allFolders: Bool, selected: [String], existing: [String]) -> [String] {
        if allFolders {
            return existing
        }
        let wanted = Set(selected)
        return existing.filter { wanted.contains($0) }
    }

    /// 一次检查实际运行的收藏夹。未配置时返回空，调用方应视为「无事可查」。
    public static var folders: [String] {
        // 未配置时不要触碰收藏库：这是大多数从未配置追更的用户路径。
        if !allFolders && selected.isEmpty { return [] }
        return resolveFolders(allFolders: allFolders, selected: selected, existing: LocalFavoritesManager.shared.getFolders())
    }

    public static var intervalHours: Int {
        if let value = settings[intervalKey].intValue, value >= 1 {
            return value
        }
        return defaultIntervalHours
    }

    /// 应用启动后是否立即检查一次。缺省视为开启。
    public static var checkOnStart: Bool {
        settings[checkOnStartKey].boolValue ?? true
    }

    /// 自动检查等待的固定时刻（"HH:mm"），空串表示任意时间。
    public static var fixedTime: String {
        settings[fixedTimeKey].stringValue ?? ""
    }

    /// 解析 "HH:mm"，未设置或非法时返回 nil。纯函数。
    public static func parseFixedTime(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// 时刻门控：到点后才允许自动检查。未设置或非法值放行——坏字符串
    /// 不能把自动检查整个卡死。纯函数。
    public static func isPastFixedTime(_ value: String, now: Date = Date()) -> Bool {
        guard let time = parseFixedTime(value) else { return true }
        let scheduled = Calendar.current.date(
            bySettingHour: time.hour, minute: time.minute, second: 0, of: now
        )
        guard let scheduled else { return true }
        return now >= scheduled
    }

    /// 上次检查于 `lastCheck`（毫秒时间戳）的漫画是否到期需要再查。纯函数。
    public static func isDue(lastCheck: Int?, now: Date = Date(), intervalHours override: Int? = nil) -> Bool {
        guard let lastCheck else { return true }
        let hours = override ?? intervalHours
        return now.timeIntervalSince1970 * 1000 - Double(lastCheck) >= Double(hours) * 3_600 * 1_000
    }

    /// 保存范围选择。不带同步上传：这是设备本地配置，上传会覆盖其他
    /// 设备自己的范围选择。
    public static func save(allFolders: Bool, folders: [String]) {
        settings[allFoldersKey] = .bool(allFolders)
        settings[foldersKey] = .array(folders.map { .string($0) })
        AppData.shared.saveData(sync: false)
    }

    /// 保存周期偏好。与范围不同，这些是普通偏好，随正常同步上传。
    public static func saveSchedule(intervalHours: Int, checkOnStart: Bool, fixedTime: String) {
        settings[intervalKey] = .int(intervalHours)
        settings[checkOnStartKey] = .bool(checkOnStart)
        settings[fixedTimeKey] = .string(fixedTime)
        AppData.shared.saveData(sync: true)
    }

    /// 把旧的单收藏夹设置一次性迁移进收藏夹列表。由独立的标志位守护
    /// （该位不参与同步），用户之后清空选择时不会在下次启动又被旧键
    /// 重新播种。
    public static func migrateLegacyIfNeeded() {
        if settings[migratedKey].boolValue == true { return }
        settings[migratedKey] = .bool(true)
        let legacy = settings[legacyFolderKey].stringValue
        if let legacy, !legacy.isEmpty, !allFolders, selected.isEmpty {
            settings[foldersKey] = .array([.string(legacy)])
        }
        AppData.shared.saveData(sync: false)
    }
}
