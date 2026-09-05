import SwiftUI
import VeneraKit

/// 全局后台任务中心（对齐原版 tasks_page.dart）。
/// 集中展示并管理跨源迁移、追更检测、源批量更新与 WebDAV 数据同步任务。
struct TasksView: View {
    @State private var selectedTab = 0 // 0: 运行中, 1: 任务历史
    @State private var migrationTasks: [SourceMigrationManager.MigrationTask] = []
    @State private var followTasks: [FollowUpdateTask] = []
    @State private var sourceUpdateTasks: [SourceUpdateTask] = []
    @State private var downloadTasks: [DownloadTask] = []
    @State private var dataSyncTasks: [DataSyncTask] = []
    @State private var comicExportTasks: [LocalComicExportTask] = []
    @State private var preTranslationTasks: [PreTranslationTask] = []
    @State private var comicExportPendingCancellation: LocalComicExportTask?
    @State private var showMigrationSheet = false
    @State private var showClearHistoryConfirmation = false
    @State private var removeDownloadObserver: (() -> Void)?
    @State private var removeMigrationObserver: (() -> Void)?
    @State private var removeFollowObserver: (() -> Void)?
    @State private var removeSourceUpdateObserver: (() -> Void)?
    @State private var removeDataSyncObserver: (() -> Void)?
    @State private var removeComicExportObserver: (() -> Void)?
    @State private var removePreTranslationObserver: (() -> Void)?
    @State private var taskPendingCancellation: SourceMigrationManager.MigrationTask?
    @State private var followPendingCancellation: FollowUpdateTask?
    @State private var sourceUpdatePendingCancellation: SourceUpdateTask?
    @State private var dataSyncPendingCancellation: DataSyncTask?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tasks".tl, selection: $selectedTab) {
                Text("Running".tl).tag(0)
                Text("History".tl).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedTab == 0 {
                runningList
            } else {
                historyList
            }
        }
        .navigationTitle("Task Center".tl)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showMigrationSheet = true
                    } label: {
                        Label("Source Migration".tl, systemImage: "arrow.triangle.swap")
                    }
                    if hasHistory {
                        Button(role: .destructive) {
                            showClearHistoryConfirmation = true
                        } label: {
                            Label("Clear Task History".tl, systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showMigrationSheet) {
            SourceMigrationSheet()
                .onDisappear(perform: reload)
        }
        .onAppear {
            reload()
            if removeDownloadObserver == nil {
                removeDownloadObserver = DownloadManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
            if removeMigrationObserver == nil {
                removeMigrationObserver = SourceMigrationManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
            if removeFollowObserver == nil {
                removeFollowObserver = FollowUpdatesManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
            if removeSourceUpdateObserver == nil {
                removeSourceUpdateObserver = SourceUpdateManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
            if removeDataSyncObserver == nil {
                removeDataSyncObserver = DataSyncManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
            if removeComicExportObserver == nil {
                removeComicExportObserver = LocalComicExportManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
            if removePreTranslationObserver == nil {
                removePreTranslationObserver = PreTranslationTaskManager.shared.onChange.add { _ in
                    Task { @MainActor in reload() }
                }
            }
        }
        .onDisappear {
            removeDownloadObserver?()
            removeDownloadObserver = nil
            removeMigrationObserver?()
            removeMigrationObserver = nil
            removeFollowObserver?()
            removeFollowObserver = nil
            removeSourceUpdateObserver?()
            removeSourceUpdateObserver = nil
            removeDataSyncObserver?()
            removeDataSyncObserver = nil
            removeComicExportObserver?()
            removeComicExportObserver = nil
            removePreTranslationObserver?()
            removePreTranslationObserver = nil
        }
        .confirmationDialog("Clear Task History?".tl, isPresented: $showClearHistoryConfirmation, titleVisibility: .visible) {
            Button("Clear History".tl, role: .destructive) {
                SourceMigrationManager.shared.clearHistory()
                FollowUpdatesManager.shared.clearHistory()
                SourceUpdateManager.shared.clearHistory()
                DataSyncManager.shared.clearHistory()
                LocalComicExportManager.shared.clearHistory()
                PreTranslationTaskManager.shared.clearHistory()
                reload()
            }
            Button("Cancel".tl, role: .cancel) {}
        } message: {
            Text("Completed, failed, and cancelled task records will be removed. Running tasks are kept.".tl)
        }
        .alert("Cancel Task?".tl, isPresented: Binding(
            get: { taskPendingCancellation != nil },
            set: { if !$0 { taskPendingCancellation = nil } }
        ), presenting: taskPendingCancellation) { task in
            Button("Cancel Task".tl, role: .destructive) {
                SourceMigrationManager.shared.cancelMigration(id: task.id)
                taskPendingCancellation = nil
                reload()
            }
            Button("Keep Running".tl, role: .cancel) {
                taskPendingCancellation = nil
            }
        } message: { task in
            Text("The migration will stop after the current item and keep its cancellation record.".tl)
        }
        .alert("Cancel Update Check?".tl, isPresented: Binding(
            get: { followPendingCancellation != nil },
            set: { if !$0 { followPendingCancellation = nil } }
        ), presenting: followPendingCancellation) { task in
            Button("Cancel Task".tl, role: .destructive) {
                FollowUpdatesManager.shared.cancelCheck(id: task.id)
                followPendingCancellation = nil
                reload()
            }
            Button("Keep Running".tl, role: .cancel) {
                followPendingCancellation = nil
            }
        } message: { _ in
            Text("The update check will stop and keep its task history.".tl)
        }
        .alert("Cancel Source Updates?".tl, isPresented: Binding(
            get: { sourceUpdatePendingCancellation != nil },
            set: { if !$0 { sourceUpdatePendingCancellation = nil } }
        ), presenting: sourceUpdatePendingCancellation) { task in
            Button("Cancel Task".tl, role: .destructive) {
                SourceUpdateManager.shared.cancel(id: task.id)
                sourceUpdatePendingCancellation = nil
                reload()
            }
            Button("Keep Running".tl, role: .cancel) {
                sourceUpdatePendingCancellation = nil
            }
        } message: { _ in
            Text("Source updates will stop and keep their task history.".tl)
        }
.alert("Cancel Comic Export?".tl, isPresented: Binding(get: { comicExportPendingCancellation != nil }, set: { if !$0 { comicExportPendingCancellation = nil } }), presenting: comicExportPendingCancellation) { task in
            Button("Cancel Task".tl, role: .destructive) { LocalComicExportManager.shared.cancel(id: task.id); comicExportPendingCancellation = nil; reload() }
            Button("Keep Running".tl, role: .cancel) { comicExportPendingCancellation = nil }
        } message: { _ in Text("The export will stop and remove incomplete files.".tl) }
        .alert("Cancel Data Sync?".tl, isPresented: Binding(
            get: { dataSyncPendingCancellation != nil },
            set: { if !$0 { dataSyncPendingCancellation = nil } }
        ), presenting: dataSyncPendingCancellation) { task in
            Button("Cancel Task".tl, role: .destructive) {
                DataSyncManager.shared.cancel(id: task.id)
                dataSyncPendingCancellation = nil
                reload()
            }
            Button("Keep Running".tl, role: .cancel) {
                dataSyncPendingCancellation = nil
            }
        } message: { _ in
            Text("The WebDAV operation will stop and keep its task history.".tl)
        }
    }

    private var hasHistory: Bool {
        !finishedTasks.isEmpty || !finishedFollowTasks.isEmpty || !finishedSourceUpdateTasks.isEmpty || !finishedDataSyncTasks.isEmpty || !finishedComicExportTasks.isEmpty || !finishedPreTranslationTasks.isEmpty
    }

    private var runningTasks: [SourceMigrationManager.MigrationTask] {
        migrationTasks.filter { $0.status == .running }
    }

    private var runningFollowTasks: [FollowUpdateTask] {
        followTasks.filter { $0.status == .running }
    }

    private var runningSourceUpdateTasks: [SourceUpdateTask] {
        sourceUpdateTasks.filter { $0.status == .running }
    }

    private var runningDataSyncTasks: [DataSyncTask] {
        dataSyncTasks.filter { $0.status == .running }
    }

    private var finishedTasks: [SourceMigrationManager.MigrationTask] {
        migrationTasks.filter { $0.status != .running }
    }

    private var finishedFollowTasks: [FollowUpdateTask] {
        followTasks.filter { $0.status != .running }
    }

    private var finishedSourceUpdateTasks: [SourceUpdateTask] {
        sourceUpdateTasks.filter { $0.status != .running }
    }

    private var finishedDataSyncTasks: [DataSyncTask] {
        dataSyncTasks.filter { $0.status != .running }
    }

    private var runningComicExportTasks: [LocalComicExportTask] { comicExportTasks.filter(\.isRunning) }
    private var finishedComicExportTasks: [LocalComicExportTask] { comicExportTasks.filter { !$0.isRunning } }
    private var runningPreTranslationTasks: [PreTranslationTask] { preTranslationTasks.filter(\.isActive) }
    private var finishedPreTranslationTasks: [PreTranslationTask] { preTranslationTasks.filter { !$0.isActive } }

    private var runningList: some View {
        Group {
            if runningTasks.isEmpty && runningFollowTasks.isEmpty && runningSourceUpdateTasks.isEmpty && runningDataSyncTasks.isEmpty && runningComicExportTasks.isEmpty && runningPreTranslationTasks.isEmpty && downloadTasks.isEmpty {
                ContentUnavailableView {
                    Label("No Running Tasks".tl, systemImage: "checkmark.circle")
                } description: {
                    Text("All background tasks have completed".tl)
                }
            } else {
                List {
                    if !downloadTasks.isEmpty {
                        Section("Downloads".tl) {
                            NavigationLink(value: "downloading") {
                                Label("Download Manager".tl, systemImage: "arrow.down.circle")
                                    .badge(downloadTasks.count)
                            }
                        }
                    }
                    if !runningTasks.isEmpty {
                        Section("Source Migration".tl) {
                            ForEach(runningTasks) { task in
                                taskCard(task)
                            }
                        }
                    }
                    if !runningFollowTasks.isEmpty {
                        Section("Follow Updates".tl) {
                            ForEach(runningFollowTasks) { task in
                                followTaskCard(task)
                            }
                        }
                    }
                    if !runningSourceUpdateTasks.isEmpty {
                        Section("Source Updates".tl) {
                            ForEach(runningSourceUpdateTasks) { task in
                                sourceUpdateTaskCard(task)
                            }
                        }
                    }
                    if !runningDataSyncTasks.isEmpty {
                        Section("Data Sync".tl) {
                            ForEach(runningDataSyncTasks) { task in
                                dataSyncTaskCard(task)
                            }
                        }
                    }
                    if !runningComicExportTasks.isEmpty {
                        Section("Comic Export".tl) {
                            ForEach(runningComicExportTasks) { task in comicExportTaskCard(task) }
                        }
                    }
                    if !runningPreTranslationTasks.isEmpty {
                        Section("Pre-translation".tl) {
                            ForEach(runningPreTranslationTasks) { task in preTranslationTaskCard(task) }
                        }
                    }
                }
            }
        }
    }

    private var historyList: some View {
        Group {
            if finishedTasks.isEmpty && finishedFollowTasks.isEmpty && finishedSourceUpdateTasks.isEmpty && finishedDataSyncTasks.isEmpty && finishedComicExportTasks.isEmpty && finishedPreTranslationTasks.isEmpty {
                ContentUnavailableView {
                    Label("No Task History".tl, systemImage: "clock")
                } description: {
                    Text("Completed tasks will appear here".tl)
                }
            } else {
                List {
                    ForEach(finishedTasks) { task in
                        taskCard(task)
                    }
                    ForEach(finishedFollowTasks) { task in
                        followTaskCard(task)
                    }
                    ForEach(finishedSourceUpdateTasks) { task in
                        sourceUpdateTaskCard(task)
                    }
                    ForEach(finishedDataSyncTasks) { task in
                        dataSyncTaskCard(task)
                    }
                    ForEach(finishedComicExportTasks) { task in comicExportTaskCard(task) }
                    ForEach(finishedPreTranslationTasks) { task in preTranslationTaskCard(task) }
                }
            }
        }
    }

    @ViewBuilder
    private func taskCard(_ task: SourceMigrationManager.MigrationTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Source Migration".tl, systemImage: "arrow.triangle.swap")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                statusBadge(task.status)
            }

            Text("Folder: \(task.folder) (\(task.sourceKey) → \(task.targetKey))".tl)
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(task.current), total: Double(max(task.total, 1)))
                .tint(.accentColor)

            HStack {
                Text("Progress: \(task.current)/\(task.total)".tl)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Success: \(task.migrated) · Failed: \(task.failed)".tl)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if task.status == .running {
                Button("Cancel".tl, role: .destructive) {
                    taskPendingCancellation = task
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func followTaskCard(_ task: FollowUpdateTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Follow Updates".tl, systemImage: "bell")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                followStatusBadge(task.status)
            }

            Text(task.manual ? "Manual update check".tl : "Scheduled update check".tl)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verbatim: followUpdateFolderLabel(task.folders))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ProgressView(value: task.progress)
                .tint(.accentColor)

            HStack {
                Text("Progress: \(task.current)/\(task.total)".tl)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Updated: \(task.updated) · Failed: \(task.errors)".tl)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if task.status == .running {
                Button("Cancel".tl, role: .destructive) {
                    followPendingCancellation = task
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func sourceUpdateTaskCard(_ task: SourceUpdateTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Source Updates".tl, systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                sourceUpdateStatusBadge(task.status)
            }
            Text("Updating installed comic sources".tl)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: task.progress)
                .tint(.accentColor)
            HStack {
                Text("Progress: \(task.checked)/\(task.total)".tl)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Updated: \(task.updated) · Failed: \(task.failed)".tl)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if task.status == .running {
                Button("Cancel".tl, role: .destructive) {
                    sourceUpdatePendingCancellation = task
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sourceUpdateStatusBadge(_ status: SourceUpdateTask.Status) -> some View {
        switch status {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running".tl).font(.caption2).foregroundStyle(.blue)
            }
        case .completed:
            Text("Completed".tl).font(.caption2).foregroundStyle(.green)
        case .failed:
            Text("Failed".tl).font(.caption2).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled".tl).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func followStatusBadge(_ status: FollowUpdateTask.Status) -> some View {
        switch status {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running".tl).font(.caption2).foregroundStyle(.blue)
            }
        case .completed:
            Text("Completed".tl)
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15), in: Capsule())
        case .failed:
            Text("Failed".tl)
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15), in: Capsule())
        case .cancelled:
            Text("Cancelled".tl)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: SourceMigrationManager.MigrationTask.Status) -> some View {
        switch status {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running".tl).font(.caption2).foregroundStyle(.blue)
            }
        case .completed:
            Text("Completed".tl)
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15), in: Capsule())
        case .failed:
            Text("Failed".tl)
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15), in: Capsule())
        case .cancelled:
            Text("Cancelled".tl)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func dataSyncTitle(_ operation: DataSyncTask.Operation) -> String {
        switch operation {
        case .upload: return "WebDAV Upload".tl
        case .download: return "WebDAV Download".tl
        case .import: return "Import App Data".tl
        case .export: return "Export App Data".tl
        case .webdavMigration: return "WebDAV Library Migration".tl
        }
    }

    private func dataSyncIcon(_ operation: DataSyncTask.Operation) -> String {
        switch operation {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .import: return "archivebox"
        case .export: return "arrow.up.doc"
        case .webdavMigration: return "externaldrive.badge.person.crop"
        }
    }

    private func dataSyncTaskCard(_ task: DataSyncTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(dataSyncTitle(task.operation),
                      systemImage: dataSyncIcon(task.operation))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                dataSyncStatusBadge(task.status)
            }
            Text(verbatim: task.libraryName ?? task.fileName ?? task.backupName ?? task.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: task.progress)
                .tint(.accentColor)
            if let currentItem = task.currentItem, !currentItem.isEmpty {
                Text(verbatim: currentItem)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if task.failureCount > 0 {
                Text("Failures: @n".tl.replacingOccurrences(of: "@n", with: String(task.failureCount)))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                ForEach(task.failures.prefix(2), id: \.self) { failure in
                    Text(verbatim: failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            if let error = task.error {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if task.status == .running {
                Button("Cancel".tl, role: .destructive) {
                    dataSyncPendingCancellation = task
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func comicExportTaskCard(_ task: LocalComicExportTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Label("Comic Export".tl, systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold)); Spacer(); Text(task.status.rawValue.capitalized).font(.caption2).foregroundStyle(task.status == .failed ? .red : .secondary) }
            Text("\(task.format.displayName) · \(task.currentIndex)/\(task.comicTitles.count)".tl).font(.caption).foregroundStyle(.secondary)
            if !task.outputRelativePaths.isEmpty {
                Label("Files → On My iPhone → VeneraX → Exports".tl, systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                Text(task.outputRelativePaths.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            ProgressView(value: task.progress)
            if let error = task.error { Text(verbatim: error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
            if task.status == .running { Button("Cancel".tl, role: .destructive) { comicExportPendingCancellation = task }.font(.caption) }
        }.padding(.vertical, 4)
    }

    @ViewBuilder
    private func preTranslationTaskCard(_ task: PreTranslationTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Pre-translation".tl, systemImage: "character.book.closed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(task.status.rawValue.capitalized.tl)
                    .font(.caption2)
                    .foregroundStyle(task.status == .failed ? .red : .secondary)
            }
            Text(verbatim: task.title).font(.caption).foregroundStyle(.secondary)
            if task.isRunning, !task.phase.isEmpty {
                Text(verbatim: task.phase).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack {
                if task.total == 0 {
                    Text("\(task.chapters.count) · \("Preparing".tl)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(task.chapters.count) · \(task.done + task.failed)/\(task.total)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if task.failed > 0 {
                    Text("\("Failed".tl): \(task.failed)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            ProgressView(value: task.progress)
            HStack {
                if task.isRunning {
                    Button("Pause".tl) {
                        PreTranslationTaskManager.shared.pause(id: task.id)
                    }
                    .font(.caption)
                    Button("Cancel".tl, role: .destructive) {
                        PreTranslationTaskManager.shared.cancel(id: task.id)
                    }
                    .font(.caption)
                } else if task.isPaused {
                    Button("Resume".tl) {
                        PreTranslationTaskManager.shared.resume(id: task.id)
                    }
                    .font(.caption)
                    Button("Cancel".tl, role: .destructive) {
                        PreTranslationTaskManager.shared.cancel(id: task.id)
                    }
                    .font(.caption)
                } else if task.hasFailures {
                    Button("Retry failed pages".tl) {
                        PreTranslationTaskManager.shared.retryFailed(id: task.id)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func dataSyncStatusBadge(_ status: DataSyncTask.Status) -> some View {
        switch status {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running".tl).font(.caption2).foregroundStyle(.blue)
            }
        case .completed:
            Text("Completed".tl).font(.caption2).foregroundStyle(.green)
        case .failed:
            Text("Failed".tl).font(.caption2).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled".tl).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func reload() {
        migrationTasks = SourceMigrationManager.shared.allTasks()
        followTasks = FollowUpdatesManager.shared.allTasks()
        sourceUpdateTasks = SourceUpdateManager.shared.allTasks()
        dataSyncTasks = DataSyncManager.shared.allTasks()
        comicExportTasks = LocalComicExportManager.shared.allTasks()
        preTranslationTasks = PreTranslationTaskManager.shared.allTasks()
        downloadTasks = DownloadManager.shared.downloadingTasks
    }
}

/// 跨源迁移创建弹窗。
struct SourceMigrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = LocalFavoritesManager.shared.getFoldersSorted()
    @State private var selectedFolder: String = ""
    @State private var selectedSourceKey: String = ""
    @State private var selectedTargetKey: String = ""
    @State private var migrateHistory = true

    private var availableSources: [ComicSource] {
        AppServices.shared.sources
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source Folder".tl) {
                    Picker("Folder".tl, selection: $selectedFolder) {
                        ForEach(folders, id: \.self) { folder in
                            Text(verbatim: folder).tag(folder)
                        }
                    }
                }

                Section("Migration Direction".tl) {
                    Picker("From Source".tl, selection: $selectedSourceKey) {
                        ForEach(availableSources, id: \.key) { s in
                            Text(verbatim: s.name).tag(s.key)
                        }
                    }
                    Picker("To Target Source".tl, selection: $selectedTargetKey) {
                        ForEach(availableSources.filter { $0.key != selectedSourceKey }, id: \.key) { s in
                            Text(verbatim: s.name).tag(s.key)
                        }
                    }
                }

                Section {
                    Toggle("Migrate Reading History".tl, isOn: $migrateHistory)
                } footer: {
                    Text("Searches for matching comic titles in the target source and replaces local favorite records.".tl)
                }
            }
            .navigationTitle("New Migration Task".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start".tl) {
                        start()
                        dismiss()
                    }
                    .disabled(selectedFolder.isEmpty || selectedSourceKey.isEmpty || selectedTargetKey.isEmpty)
                }
            }
            .onAppear {
                if selectedFolder.isEmpty { selectedFolder = folders.first ?? "" }
                if selectedSourceKey.isEmpty { selectedSourceKey = availableSources.first?.key ?? "" }
                if selectedTargetKey.isEmpty { selectedTargetKey = availableSources.last?.key ?? "" }
            }
        }
    }

    private func start() {
        SourceMigrationManager.shared.startMigration(
            folder: selectedFolder,
            sourceKey: selectedSourceKey,
            targetKey: selectedTargetKey,
            migrateHistory: migrateHistory
        )
    }
}
