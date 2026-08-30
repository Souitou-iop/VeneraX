import SwiftUI
import VeneraKit

/// 应用级阶段与启动决策。后续里程碑在 loading 与 main 之间插入
/// 免责声明（M5）与应用锁（M5）。
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum Phase {
        case loading
        case main
    }

    private(set) var phase: Phase = .loading

    /// 应用锁状态（authorizationRequired 设置）。
    var isLocked = false
    /// 自测钩子：程序化打开阅读器（绕过无点击注入的限制）。
    var autoOpenReader: ReaderAutoLaunch?
    /// 等待启动完成后处理的外部 URL。之前 URL 路由只解析不导航，导致漫画深链静默丢失。
    var pendingExternalURL: URL?
    /// 首启迁移：免责声明同意过或已有数据时视为老用户。
    var needsMigration = false

    private init() {}

    /// 阻塞初始化链路对应原版 init()：AppData 加载先行，
    /// 其余（CookieJar/JsEngine/ComicSourceManager）在 M1 接入。
    func initialize() async {
        await Task.yield()
        AppData.shared.load()
        Log.syncVerboseNetwork(AppData.shared.settings["verboseNetworkLog"].boolValue ?? false)
        // 全新安装（从未同意免责声明且无任何本地数据）→ 提供迁移向导
        let hasData = !HistoryManager.shared.getAll().isEmpty
            || !LocalFavoritesManager.shared.getFolders().isEmpty
            || !ComicSourceManager.shared.all().isEmpty
        needsMigration = !hasData && !(AppData.shared.settings["disclaimerConsented"].boolValue ?? false)
        isLocked = AppData.shared.settings["authorizationRequired"].boolValue ?? false
        phase = .main
    }
}
