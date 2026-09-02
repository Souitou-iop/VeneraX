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
    /// Latest release discovered during this launch, if any.
    private(set) var startupUpdateTag: String?

    private var startupUpdateTask: Task<Void, Never>?

    private init() {}

    /// 阻塞初始化链路对应原版 init()：AppData 加载先行，
    /// 其余（CookieJar/JsEngine/ComicSourceManager）在 M1 接入。
    func initialize() async {
        let startedAt = Date()
        await Task.yield()
        AppData.shared.load()
        Log.syncVerboseNetwork(AppData.shared.settings["verboseNetworkLog"].boolValue ?? false)
        // 全新安装（从未同意免责声明且无任何本地数据）→ 提供迁移向导。
        // 不在首屏触碰 SQLite 单例：History/Favorites 的首次 schema 创建会在
        // 主线程同步执行，导致启动 ProgressView 长时间停留。文件存在性足够
        // 判断是否已有本地数据，具体数据库内容交给对应页面按需加载。
        let dataPath = AppPaths.dataPath
        let hasDatabaseData = ["history.db", "local_favorite.db", "read_later.db"]
            .contains { FileIO.exists(AppPaths.join(dataPath, $0)) }
        let hasInstalledSource = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.comicSourcePath))?
            .contains { $0.hasSuffix(".js") } ?? false
        let hasData = hasDatabaseData || hasInstalledSource
        needsMigration = !hasData && !(AppData.shared.settings["disclaimerConsented"].boolValue ?? false)
        isLocked = AppData.shared.settings["authorizationRequired"].boolValue ?? false
        phase = .main
        Log.info("Startup", "AppData ready in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
        startStartupUpdateCheckIfNeeded()
    }
    private func startStartupUpdateCheckIfNeeded() {
        guard startupUpdateTask == nil,
              AppData.shared.settings["checkUpdateOnStart"].boolValue ?? true else { return }

        startupUpdateTask = Task { [weak self] in
            // Keep the network check out of the first-render path and give the
            // initial UI a chance to become interactive before it starts.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            do {
                let result = try await AppUpdateChecker.shared.check()
                guard let self else { return }
                if result.hasUpdate {
                    self.startupUpdateTag = result.tag
                    Log.info("App Update", "New release available: \(result.tag)")
                } else {
                    Log.info("App Update", "Already up to date")
                }
            } catch {
                // Startup checks are best-effort and must never gate the app.
                Log.warning("App Update", "Startup check skipped: \(error.localizedDescription)")
            }
        }
    }

}
