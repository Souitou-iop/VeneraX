import Foundation
import Observation
import VeneraKit

/// 应用服务启动链（对应原版 initDeferred）：JS 引擎 → 消息分发 →
/// 漫画源管理器 → 目录加载。UI delegate 提供原生对话框与 Cloudflare 解盾。
@Observable
@MainActor
final class AppServices {
    static let shared = AppServices()

    private(set) var sources: [ComicSource] = []
    var bootError: String?
    private(set) var isBooted = false
    private var isBooting = false

    /// 源脚本触发的 UI 消息（Toast/对话框）。
    private(set) var toast: String?
    var jsAlert: JSAlert?
    var jsInput: JSInput?
    var jsSelect: JSSelect?
    var cloudflareRequest: CloudflareRequest?

    struct JSAlert: Identifiable {
        let id = UUID()
        let title: String
        let content: String
    }

    struct JSInput: Identifiable {
        let id = UUID()
        let title: String
        let completion: (String?) -> Void
    }

    struct JSSelect: Identifiable {
        let id = UUID()
        let title: String
        let options: [String]
        let initialIndex: Int?
        let completion: (Int?) -> Void
    }

    struct CloudflareRequest: Identifiable {
        let id = UUID()
        let url: URL
        let headers: [String: String]
        let completion: (Bool) -> Void
    }

    private let runtime = JSRuntime()
    private let dispatcher = JSDispatcher()

    private init() {}

    func boot() async {
        guard !isBooted, !isBooting else { return }
        isBooting = true
        defer { isBooting = false }
        let startedAt = Date()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.uiDelegate = self
        dispatcher.install(to: runtime)
        CloudflareSolver.shared.delegate = self

        do {
            try runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
        } catch {
            bootError = "init.js failed: \(error)"
            Log.error("JS Engine", "Failed to evaluate init.js: \(error)")
        }
        ComicSourceManager.shared.attach(runtime: runtime)

        await ComicSourceManager.shared.loadFromDirectory()
        refreshSources()

        ComicSourceManager.shared.onChange.add { [weak self] _ in
            Task { @MainActor in
                self?.refreshSources()
            }
        }
        isBooted = true
        LiveActivityCoordinator.shared.start()
        Log.info("Startup", "Runtime services ready in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")

        // Sources are now available, so interrupted pre-translation jobs can
        // safely rebuild their page lists and continue from persisted prefixes.
        PreTranslationTaskManager.shared.resumePendingTasks()
        FollowUpdatesManager.shared.startChecker()
        runStartupMaintenance()

        if SelfTest.shouldRun() {
            Task {
                await SelfTest.run()
                Log.flush()
            }
        }
    }

    private func runStartupMaintenance() {
        let rawDays = AppData.shared.settings["autoCleanHistoryDays"].stringValue ?? "0"
        let days = Int(rawDays) ?? 0
        guard days > 0 else { return }
        Task.detached(priority: .utility) {
            HistoryManager.shared.cleanHistoryOlderThan(days: days)
            Log.info("Startup", "History maintenance completed")
        }
    }

    private func refreshSources() {
        sources = ComicSourceManager.shared.all()
    }

    func refreshAfterMigration() {
        refreshSources()
    }
}

extension AppServices: @preconcurrency JSDispatcher.UIDelegate {
    func showMessage(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if self.toast == message { self.toast = nil }
        }
    }

    func showDialog(title: String, content: String) {
        jsAlert = JSAlert(title: title, content: content)
    }

    func launchUrl(_ url: String) {
        guard let url = URL(string: url) else { return }
        UIApplication.shared.open(url)
    }

    func showInputDialog(title: String, completion: @escaping (String?) -> Void) {
        jsInput = JSInput(title: title, completion: completion)
    }

    func showSelectDialog(title: String, options: [String], initialIndex: Int?, completion: @escaping (Int?) -> Void) {
        jsSelect = JSSelect(title: title, options: options, initialIndex: initialIndex, completion: completion)
    }
}

extension AppServices: CloudflareChallengeDelegate {
    func requestSolveCloudflare(url: URL, headers: [String: String]) async -> Bool {
        await withCheckedContinuation { continuation in
            self.cloudflareRequest = CloudflareRequest(url: url, headers: headers) { solved in
                self.cloudflareRequest = nil
                continuation.resume(returning: solved)
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
