@preconcurrency import ActivityKit
import Foundation
import UIKit
import VeneraKit

@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()
    static let enabledKey = "liveActivitiesEnabled"
    static let detailsKey = "liveActivityShowDetails"

    private var removePreTranslationObserver: (() -> Void)?
    private var removeDownloadObserver: (() -> Void)?
    private var downloadTaskObservers: [ObjectIdentifier: () -> Void] = [:]
    private var refreshTask: Task<Void, Never>?
    private var delayTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var needsRefresh = false
    private var lastRequestAttempt: [VeneraTaskActivityAttributes.Kind: Date] = [:]
    private let covers = LiveActivityCoverStore()

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    private var showDetails: Bool { UserDefaults.standard.bool(forKey: Self.detailsKey) }
    private init() {}

    func start() {
        guard removePreTranslationObserver == nil else { return }
        removePreTranslationObserver = PreTranslationTaskManager.shared.onChange.add { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Creating an activity must not wait a second before the user backgrounds.
                let exists = Activity<VeneraTaskActivityAttributes>.activities.contains { $0.attributes.kind == .preTranslation }
                self.scheduleRefresh(immediate: !exists)
            }
        }
        removeDownloadObserver = DownloadManager.shared.onChange.add { [weak self] _ in
            Task { @MainActor in
                self?.bindDownloadTasks()
                self?.scheduleRefresh(immediate: true)
            }
        }
        authorizationTask = Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard !Task.isCancelled else { return }
                self?.becameActive()
            }
        }
        bindDownloadTasks()
        if !showDetails { covers.clear() }
        scheduleRefresh(immediate: true)
    }

    func becameActive() {
        guard removePreTranslationObserver != nil else { return }
        lastRequestAttempt.removeAll()
        bindDownloadTasks()
        scheduleRefresh(immediate: true)
    }

    func settingsChanged() {
        lastRequestAttempt.removeAll()
        if !showDetails || !enabled { covers.clear() }
        scheduleRefresh(immediate: true)
    }

    private func bindDownloadTasks() {
        covers.prune(keeping: Set(Activity<VeneraTaskActivityAttributes>.activities.map { $0.content.state.coverURL }))
        downloadTaskObservers.values.forEach { $0() }
        downloadTaskObservers.removeAll()
        for task in DownloadManager.shared.activitySnapshot().tasks {
            downloadTaskObservers[ObjectIdentifier(task)] = task.onChange.add { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        if immediate {
            delayTask?.cancel()
            delayTask = nil
            enqueueRefresh()
        } else if delayTask == nil {
            delayTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.delayTask = nil
                self?.enqueueRefresh()
            }
        }
    }

    /// One writer across all ActivityKit awaits; notifications arriving during an
    /// update trigger another pass instead of racing or losing a terminal state.
    private func enqueueRefresh() {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                needsRefresh = false
                if !enabled || !ActivityAuthorizationInfo().areActivitiesEnabled {
                    for activity in Activity<VeneraTaskActivityAttributes>.activities {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                } else {
                    await syncPreTranslation()
                    await syncDownloads()
                }
            } while needsRefresh
            refreshTask = nil
        }
    }

    private func syncPreTranslation() async {
        let tasks = PreTranslationTaskManager.shared.allTasks()
        let activities = Activity<VeneraTaskActivityAttributes>.activities.filter { $0.attributes.kind == .preTranslation }
        if let active = tasks.first(where: \.isActive) {
            let matching = activities.first { $0.attributes.id == active.id }
            for old in activities where old.id != matching?.id {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            let state = presented(preTranslationState(active))
            if let matching { await matching.update(content(state)) }
            else { request(attributes: .init(id: active.id, kind: .preTranslation), state: state) }
        } else {
            for activity in activities {
                guard let task = tasks.first(where: { $0.id == activity.attributes.id }) else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                await activity.end(ActivityContent(state: presented(preTranslationState(task)), staleDate: nil),
                                   dismissalPolicy: .after(Date().addingTimeInterval(45)))
            }
        }
    }

    private func syncDownloads() async {
        let snapshot = DownloadManager.shared.activitySnapshot()
        let activities = Activity<VeneraTaskActivityAttributes>.activities.filter { $0.attributes.kind == .download }
        guard !snapshot.tasks.isEmpty else {
            for activity in activities {
                guard activity.attributes.id == snapshot.id, let result = snapshot.result else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                var state = activity.content.state
                switch result {
                case .completed:
                    state.status = .completed
                    state.progress = 1
                    state.current = state.total
                    state.phase = "Completed".tl
                case .cancelled:
                    state.status = .cancelled
                    state.phase = "Cancelled".tl
                case .partiallyCancelled:
                    state.status = .cancelled
                    state.phase = "Finished with cancellations".tl
                }
                await activity.end(ActivityContent(state: presented(state), staleDate: nil),
                                   dismissalPolicy: .after(Date().addingTimeInterval(45)))
            }
            return
        }
        let matching = activities.first { $0.attributes.id == snapshot.id }
        for old in activities where old.id != matching?.id {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        let state = presented(downloadState(snapshot.tasks))
        if let matching { await matching.update(content(state)) }
        else { request(attributes: .init(id: snapshot.id, kind: .download), state: state) }
    }

    private func content(_ state: VeneraTaskActivityAttributes.ContentState) -> ActivityContent<VeneraTaskActivityAttributes.ContentState> {
        // A deliberate pause is stable, not stale after 90 seconds.
        ActivityContent(state: state, staleDate: state.status == .running ? Date().addingTimeInterval(90) : nil)
    }

    private func request(attributes: VeneraTaskActivityAttributes, state: VeneraTaskActivityAttributes.ContentState) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        if let last = lastRequestAttempt[attributes.kind], Date().timeIntervalSince(last) < 10 { return }
        lastRequestAttempt[attributes.kind] = Date()
        do {
            _ = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
        } catch {
            Log.warning("Live Activity", "Unable to start \(attributes.kind.rawValue): \(error.localizedDescription)")
        }
    }

    private func presented(_ raw: VeneraTaskActivityAttributes.ContentState) -> VeneraTaskActivityAttributes.ContentState {
        var state = raw
        if !showDetails {
            state.subtitle = ""
            state.phase = state.isIndeterminate ? "Preparing".tl : statusText(state.status)
        }
        return state.bounded(showDetails: showDetails)
    }

    private func cover(_ raw: String, sourceKey: String?, comicID: String?) -> String {
        guard showDetails else { return "" }
        return covers.filename(raw: raw, sourceKey: sourceKey, comicID: comicID) { [weak self] in
            self?.scheduleRefresh(immediate: true)
        }
    }

    private func preTranslationState(_ task: PreTranslationTask) -> VeneraTaskActivityAttributes.ContentState {
        let status: VeneraTaskActivityAttributes.Status = switch task.status {
        case .running: .running
        case .paused: .paused
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
        let phase: String
        if status != .running { phase = statusText(status) }
        else if !task.phase.isEmpty { phase = task.phase }
        else if task.total == 0 { phase = "Preparing".tl }
        else { phase = statusText(status) }
        return .init(activityTitle: "Pre-translation".tl, title: task.title,
                     subtitle: "\(task.chapters.count) \("Chapters".tl)", phase: phase,
                     coverURL: cover(task.cover, sourceKey: task.sourceKey, comicID: task.cid),
                     progress: task.progress, current: task.done + task.failed, total: task.total,
                     queueCount: 1, status: status, failedCount: task.failed)
    }

    private func downloadState(_ tasks: [DownloadTask]) -> VeneraTaskActivityAttributes.ContentState {
        let task = tasks.first(where: { !$0.isPaused && !$0.isError }) ?? tasks[0]
        let status: VeneraTaskActivityAttributes.Status = task.isError ? .failed : (task.isPaused ? .paused : .running)
        let imageTask = task as? ImagesDownloadTask
        let progress = task.progress.isFinite ? min(max(task.progress, 0), 1) : 0
        let counts = imageTask.map { ($0.downloadedCount, $0.totalCount) } ?? (Int(progress * 100), progress > 0 ? 100 : 0)
        return .init(activityTitle: "Downloading".tl, title: task.title,
                     subtitle: "Current task".tl, phase: status == .running ? task.message.tl : statusText(status),
                     coverURL: cover(task.cover ?? "", sourceKey: imageTask?.sourceKey, comicID: task.id),
                     progress: progress, current: counts.0, total: counts.1, queueCount: tasks.count, status: status)
    }

    private func statusText(_ status: VeneraTaskActivityAttributes.Status) -> String {
        switch status {
        case .running: "Running".tl
        case .paused: "Paused".tl
        case .completed: "Completed".tl
        case .failed: "Failed".tl
        case .cancelled: "Cancelled".tl
        }
    }
}
