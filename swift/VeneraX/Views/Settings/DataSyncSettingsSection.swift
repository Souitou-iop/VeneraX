import SwiftUI
import UniformTypeIdentifiers
import VeneraKit

/// 「Data & Sync」分区（对齐 settings/data_sync.dart + app.dart 中的
/// _WebdavSetting/_WebdavSyncOptions：数据组 + WebDAV 组）。
struct DataSyncSettingsSection: View {
    @State private var cacheSize: Int = CacheManager.shared.size
    @State private var showImporter = false
    @State private var showWebdavConfig = false
    @State private var showBackupPicker = false
    @State private var showSyncLogs = false
    @State private var showSkipSync = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isBusy = false
    @State private var removeDataSyncObserver: (() -> Void)?

    var body: some View {
        Form {
            dataGroup
            webdavGroup
            if let message {
                Section { Text(verbatim: message).font(.footnote).foregroundStyle(.green) }
            }
            if let errorMessage {
                Section { Text(verbatim: errorMessage).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Data & Sync".tl)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importBackup(result)
        }
        .sheet(isPresented: $showWebdavConfig) {
            WebdavConfigSheet()
        }
        .sheet(isPresented: $showBackupPicker) {
            RemoteBackupPicker { name in
                showBackupPicker = false
                downloadBackup(name)
            }
        }
        .sheet(isPresented: $showSyncLogs) {
            SyncLogsView()
        }
        .sheet(isPresented: $showSkipSync) {
            SkipSyncItemsSheet()
        }
        .onAppear {
            guard removeDataSyncObserver == nil else { return }
            removeDataSyncObserver = DataSyncManager.shared.onChange.add { _ in
                Task { @MainActor in
                    presentCompletedExportIfNeeded()
                }
            }
            presentCompletedExportIfNeeded()
        }
        .onDisappear {
            removeDataSyncObserver?()
            removeDataSyncObserver = nil
        }
    }

    // MARK: - 数据组

    private var dataGroup: some View {
        Section("Data".tl) {
            // 存储路径 + 复制（iOS 沙盒内不支持改路径，仅展示/复制，对齐信息面）。
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage Path for local comics".tl)
                    Text(verbatim: AppPaths.dataPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = AppPaths.dataPath
                    message = "Path copied to clipboard".tl
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            LabeledContent("Cache Size".tl, value: ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))
            SettingActionRow(title: "Clear Cache".tl, actionTitle: "Clear".tl) {
                Task {
                    CacheManager.shared.clear()
                    cacheSize = CacheManager.shared.size
                    message = "Cache cleared".tl
                }
            }
            SettingActionRow(
                title: "Cache Limit".tl,
                subtitle: "\(AppData.shared.settings["cacheSize"].intValue ?? 2048) MB",
                actionTitle: "Set".tl
            ) {
                promptForCacheLimit()
            }
            SettingPickerRow(
                title: "Auto clean reading history".tl,
                key: "autoCleanHistoryDays",
                options: [
                    .init(value: "0", label: "Never".tl),
                    .init(value: "7", label: "7 days".tl),
                    .init(value: "30", label: "30 days".tl),
                    .init(value: "90", label: "90 days".tl),
                    .init(value: "180", label: "180 days".tl),
                    .init(value: "365", label: "365 days".tl),
                ],
                defaultValue: "0",
                help: "Automatically delete reading history older than the selected period when the app starts.".tl
            )
            SettingActionRow(
                title: "Export App Data".tl,
                subtitle: "Creates a portable .venera backup in the background and opens the share sheet when ready.".tl,
                actionTitle: "Export".tl
            ) {
                exportAppData()
            }
            SettingActionRow(title: "Import App Data".tl, actionTitle: "Import".tl) {
                showImporter = true
            }
        }
    }

    // MARK: - WebDAV 组

    private var webdavGroup: some View {
        Section("WebDAV Sync".tl) {
            SettingActionRow(
                title: "Data Sync".tl,
                subtitle: DataSync.shared.isConfigured
                    ? (DataSync.shared.config?.url ?? "")
                    : "Not configured".tl,
                actionTitle: "Set".tl
            ) {
                showWebdavConfig = true
            }
            syncModeRow
            retentionRow
            SettingToggleRow(
                title: "Sync Local Comics".tl,
                key: "syncLocalComics",
                subtitle: "Include this device's local comic library in sync. Turn off to read or download comics online instead of receiving the whole library from other devices.".tl,
                defaultValue: true
            )
            SettingToggleRow(
                title: "Use Proxy for Sync".tl,
                key: "webdavUseProxy",
                subtitle: "Route WebDAV sync through the app proxy. Turn off if an unstable proxy makes sync fail.".tl,
                defaultValue: true
            )
            SettingActionRow(title: "Skip Sync Items (Optional)".tl, actionTitle: "Edit".tl) {
                showSkipSync = true
            }
            SettingActionRow(title: "Test Connection".tl, actionTitle: "Test".tl) {
                testConnection()
            }
            SettingActionRow(title: "Sync Logs".tl, actionTitle: "View".tl) {
                showSyncLogs = true
            }
            SettingActionRow(title: "Remote Backups".tl, actionTitle: "Browse".tl) {
                browseRemoteBackups()
            }
        }
    }

    /// 三档同步模式（对齐 _WebdavSyncOptions 的模式行）。
    private var syncModeRow: some View {
        Picker("Sync Mode".tl, selection: Binding(
            get: { DataSync.shared.syncMode },
            set: { DataSync.shared.setSyncMode($0) }
        )) {
            Text("Realtime".tl).tag(WebdavSyncMode.realtime)
            Text("Data Saver".tl).tag(WebdavSyncMode.dataSaver)
            Text("Manual Only".tl).tag(WebdavSyncMode.manual)
        }
    }

    /// 每平台保留份数（3/5/10/20）。
    private var retentionRow: some View {
        let choices = [3, 5, 10, 20]
        let current = AppData.shared.settings["webdavBackupRetention"].intValue ?? 10
        return Picker("Backups to keep per platform".tl, selection: Binding(
            get: { current },
            set: {
                AppData.shared.settings["webdavBackupRetention"] = .int($0)
                AppData.shared.saveData()
            }
        )) {
            if !choices.contains(current) {
                Text(verbatim: String(current)).tag(current)
            }
            ForEach(choices, id: \.self) { choice in
                Text(verbatim: String(choice)).tag(choice)
            }
        }
    }

    // MARK: - 动作

    private func promptForCacheLimit() {
        let alert = UIAlertController(
            title: "Set Cache Limit".tl,
            message: "Size in MB".tl,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Size in MB".tl
            field.keyboardType = .numberPad
            field.text = String(AppData.shared.settings["cacheSize"].intValue ?? 2048)
        }
        alert.addAction(UIAlertAction(title: "Cancel".tl, style: .cancel))
        alert.addAction(UIAlertAction(title: "OK".tl, style: .default) { _ in
            guard let text = alert.textFields?.first?.text,
                  let value = Int(text), value > 0 else { return }
            AppData.shared.settings["cacheSize"] = .int(value)
            AppData.shared.saveData()
        })
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?
            .present(alert, animated: true)
    }

    /// 导出整库 .venera → 任务中心 → 分享面板。
    private func exportAppData() {
        guard DataSyncManager.shared.startExport() != nil else {
            errorMessage = "Another data sync task is already running".tl
            return
        }
        message = "Export task started; the share sheet will open when ready".tl
        errorMessage = nil
    }

    private func presentCompletedExportIfNeeded() {
        guard let task = DataSyncManager.shared.allTasks().first(where: {
            $0.operation == .export && $0.status == .completed
        }), let url = DataSyncManager.shared.takeCompletedExportURL(for: task.id) else {
            return
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?
            .present(activityVC, animated: true)
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard DataSyncManager.shared.startImport(fileURL: url) != nil else {
            errorMessage = "Another data sync task is already running".tl
            return
        }
        message = "Import task started; monitor it in Task Center".tl
        errorMessage = nil
    }

    private func testConnection() {
        isBusy = true
        Task {
            do {
                try await DataSync.shared.testConnection()
                await MainActor.run {
                    isBusy = false
                    message = "Connection successful".tl
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = "Connection failed: @error"
                        .replacingOccurrences(of: "@error", with: error.localizedDescription).tl
                }
            }
        }
    }

    private func browseRemoteBackups() {
        isBusy = true
        Task {
            do {
                let backups = try await DataSync.shared.listRemoteBackups()
                await MainActor.run {
                    isBusy = false
                    if backups.isEmpty {
                        message = "No backups found".tl
                    } else {
                        showBackupPicker = true
                        RemoteBackupPicker.latest = backups
                    }
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func downloadBackup(_ name: String) {
        guard DataSyncManager.shared.startDownload(backupName: name) != nil else {
            errorMessage = "Another data sync task is already running".tl
            return
        }
        message = "Download task started; monitor it in Task Center".tl
        errorMessage = nil
    }
}

/// WebDAV 配置表单（URL/用户名/密码 + 保存即首同步，对齐 _WebdavSetting）。
struct WebdavConfigSheet: View {
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isBusy = false
    @State private var removeDataSyncObserver: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("WebDAV Account".tl) {
                    TextField("Server URL".tl, text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username".tl, text: $username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password".tl, text: $password)
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isBusy { ProgressView() } else { Text("Save".tl) }
                    }
                }
                if let message {
                    Text(verbatim: message).font(.footnote).foregroundStyle(.green)
                }
                if let errorMessage {
                    Text(verbatim: errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Webdav".tl)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let config = DataSync.shared.config {
            urlString = config.url
            username = config.user
            password = config.password
        }
    }

    /// 保存配置；非 manual 档立即首同步（空库则拉取远端，对齐原版 _saveConfig）。
    private func save() async {
        let fields = [urlString, username, password].map { $0.trimmingCharacters(in: .whitespaces) }
        if fields.allSatisfy({ $0.isEmpty }) {
            AppData.shared.settings["webdav"] = .array([])
            AppData.shared.saveData()
            message = "Saved".tl
            dismiss()
            return
        }
        guard fields.allSatisfy({ !$0.isEmpty }) else {
            errorMessage = "All three fields are required".tl
            return
        }
        AppData.shared.settings["webdav"] = .array(fields.map { .string($0) })
        AppData.shared.saveData()
        if DataSync.shared.syncMode == .manual {
            message = "Saved".tl
            dismiss()
            return
        }
        guard DataSyncManager.shared.startUpload(force: false) != nil else {
            errorMessage = "Saved, but another data sync task is already running".tl
            return
        }
        message = "Saved; sync task started".tl
        dismiss()
    }
}

/// 远程备份选择（对齐 _RemoteBackupListDialog）。
struct RemoteBackupPicker: View {
    /// 通过 sheet 传递的列表（backups 数组过大不宜放进闭包状态时用静态中转）。
    static var latest: [RemoteBackupInfo] = []

    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Self.latest, id: \.fileName) { backup in
                Button {
                    onSelect(backup.fileName)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "v\(backup.version)  \(platformLabel(backup.platform))")
                                .foregroundStyle(.primary)
                            Text(verbatim: backup.date.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                    }
                }
            }
            .navigationTitle("Select Backup".tl)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
            }
        }
    }

    private func platformLabel(_ platform: String) -> String {
        switch platform {
        case "win": return "Windows"
        case "ios": return "iOS"
        case "android": return "Android"
        case "macos": return "macOS"
        case "linux": return "Linux"
        case "web": return "Web"
        default: return platform
        }
    }
}

/// 同步日志（对齐 _showSyncLogsDialog）。
struct SyncLogsView: View {
    @State private var logs: [[String: JSON]] = []

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty {
                    ContentUnavailableView("No logs".tl, systemImage: "tray")
                } else {
                    List(Array(logs.enumerated().reversed()), id: \.offset) { _, log in
                        let time = Date(timeIntervalSince1970: Double(log["time"]?.intValue ?? 0) / 1000)
                        let action = log["action"]?.stringValue ?? ""
                        let success = log["success"]?.boolValue ?? false
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(success ? .green : .red)
                                Text(action == "upload" ? "Upload".tl : (action == "download" ? "Download".tl : action))
                                Spacer()
                                Text(verbatim: time.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let fileName = log["fileName"]?.stringValue {
                                Text(verbatim: fileName).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = log["error"]?.stringValue {
                                Text(verbatim: error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sync Logs".tl)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close".tl) {
                        dismissLast()
                    }
                }
            }
            .onAppear { logs = DataSync.shared.syncLogs }
        }
    }

    @Environment(\.dismiss) private var dismissLast
}

/// 跳过同步条目（分类勾选，写入 disableSyncFields 原始键列表，对齐
/// _skipSyncCategories / _editSkipSyncFields）。
struct SkipSyncItemsSheet: View {
    /// 分类 → (说明, 键列表)。键与原版逐字一致（同步协议兼容）。
    private static let categories: [(label: String, description: String, keys: [String])] = [
        ("Appearance", "Theme color, light/dark mode, comic tile layout",
         ["color", "theme_mode", "comicDisplayMode", "comicTileScale"]),
        ("Reading Options", "Reader mode, page-turn, image enhance and other reading options",
         [
            "readerMode", "enableContinuousChapterReading", "readerScreenPicNumberForLandscape",
            "readerScreenPicNumberForPortrait", "enableTapToTurnPages", "reverseTapToTurnPages",
            "enableCustomTapZones", "tapZoneTop", "tapZoneBottom", "tapZoneLeft", "tapZoneRight",
            "enablePageAnimation", "autoPageTurningInterval", "enableLongPressToZoom",
            "longPressZoomPosition", "enableTurnPageByVolumeKey", "enableClockAndBatteryInfoInReader",
            "showPageNumberInReader", "showSingleImageOnFirstPage", "enableDoubleTapToZoom",
            "reverseChapterOrder", "showSystemStatusBar", "readerScrollSpeed", "readerCenterPageOnTurn",
            "readerPageSpacing", "comicListDisplayMode", "galleryFillScreen", "readerBackgroundColor",
            "readerNightModeFollowSystem", "readerNightModeColor", "readerNightModeIntensity",
            "enableReaderImageEnhance", "readerImageEnhanceStrength", "readerImageEnhanceClarity",
            "readerImageEnhanceContrast", "readerImageEnhanceVibrance", "limitImageWidth",
            "preloadImageCount", "showChapterComments", "commentsFontSize", "showChapterCommentsAtEnd",
         ]),
        ("Explore", "Explore pages, categories, search options and content filters",
         [
            "explore_pages", "categories", "searchSources", "defaultSearchTarget",
            "autoAddLanguageFilter", "blockedWords", "blockedCommentWords",
            "showFavoriteStatusOnTile", "showHistoryStatusOnTile", "showReadLaterStatusOnTile",
         ]),
        ("Favorites", "Favorite folders, sort order and quick-favorite options",
         [
            "favorites", "newFavoriteAddTo", "moveFavoriteAfterRead", "quickFavorite",
            "quickCollectImage", "autoFavoriteCover", "onClickFavorite", "localFavoritesFirst",
            "autoCloseFavoritePanel",
         ]),
        ("Comic Source list", "The subscribed comic source list",
         ["comicSourceLibraries", "comicSourceListUrl"]),
    ]

    @State private var disabledKeys: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Chosen categories stay on this device only: they are never uploaded, and won't be overwritten by other devices.".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Array(Self.categories.enumerated()), id: \.offset) { index, category in
                        Toggle(isOn: categoryBinding(index)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.label.tl)
                                Text(category.description.tl)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Skip Sync Items".tl)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done".tl) { dismiss() }
                }
            }
            .onAppear {
                let raw = AppData.shared.settings["disableSyncFields"].stringValue ?? ""
                disabledKeys = Set(raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty })
            }
        }
    }

    private func categoryBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: {
                Self.categories[index].keys.allSatisfy { disabledKeys.contains($0) }
            },
            set: { skip in
                if skip {
                    disabledKeys.formUnion(Self.categories[index].keys)
                } else {
                    disabledKeys.subtract(Self.categories[index].keys)
                }
                AppData.shared.settings["disableSyncFields"] = .string(disabledKeys.sorted().joined(separator: ", "))
                AppData.shared.saveData()
            }
        )
    }
}
