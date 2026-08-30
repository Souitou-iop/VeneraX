import SwiftUI
import VeneraKit

/// WebDAV 同步设置页：配置账号、手动上传/下载、迁移向导入口。
struct SyncSettingsView: View {
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var error: String?
    @State private var configured = false

    var body: some View {
        Form {
            Section("WebDAV Account".tl) {
                TextField("Server URL".tl, text: $urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                TextField("Username".tl, text: $username)
                    .textInputAutocapitalization(.never)
                SecureField("Password".tl, text: $password)
                Button("Save".tl) { save() }
            }

            Section("Sync".tl) {
                Button {
                    Task { await sync(true) }
                } label: {
                    if isBusy { ProgressView() } else { Label("Upload (This device wins)".tl, systemImage: "square.and.arrow.up") }
                }
                .disabled(isBusy || !configured)
                Button {
                    Task { await sync(false) }
                } label: {
                    if isBusy { ProgressView() } else { Label("Download Latest".tl, systemImage: "square.and.arrow.down") }
                }
                .disabled(isBusy || !configured)
                LabeledContent("Data Version".tl, value: AppData.shared.settings["dataVersion"].intValue.map(String.init) ?? "0")
            }

            if let message {
                Section { Text(verbatim: message).font(.footnote).foregroundStyle(.green) }
            }
            if let error {
                Section { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Data Sync".tl)
        .onAppear(perform: reload)
    }

    private func reload() {
        configured = DataSync.shared.isConfigured
        if let config = DataSync.shared.config {
            urlString = config.url
            username = config.user
            password = config.password
        }
    }

    private func save() {
        let list = [urlString, username, password].map { $0.trimmingCharacters(in: .whitespaces) }
        AppData.shared.settings["webdav"] = .array(list.map { .string($0) })
        configured = DataSync.shared.isConfigured
        if configured {
            message = "Saved".tl
            error = nil
        } else {
            error = "All three fields are required".tl
        }
    }

    private func sync(_ force: Bool) async {
        message = nil
        error = nil
        let task = force
            ? DataSyncManager.shared.startUpload(force: true)
            : DataSyncManager.shared.startDownload()
        if task != nil {
            message = "Task started; monitor it in Task Center".tl
        } else {
            error = "Another data sync task is already running".tl
        }
    }
}

/// 首启迁移向导：从 WebDAV 拉取 Flutter 版备份，或导入本地 .venera 文件。
struct MigrationWizard: View {
    @Environment(AppState.self) private var appState
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var done = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !done {
                    Section {
                        Text("Import data from the Flutter version of VeneraX. Configure the same WebDAV account to pull the latest backup, or import a .venera backup file from Files.".tl)
                            .font(.footnote)
                    }
                    Section("WebDAV Import".tl) {
                        TextField("Server URL".tl, text: $urlString)
                        TextField("Username".tl, text: $username)
                        SecureField("Password".tl, text: $password)
                        Button {
                            Task { await importFromWebDAV() }
                        } label: {
                            if isBusy { ProgressView() } else { Text("Import".tl) }
                        }
                        .disabled(isBusy)
                    }
                    Section("Local File".tl) {
                        Button {
                            importFromClipboardOrSkip()
                        } label: {
                            Label("Skip for now".tl, systemImage: "forward")
                        }
                    }
                    if let error {
                        Text(verbatim: error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } else {
                    Section {
                        Label("Import finished. Restarting data…".tl, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .navigationTitle("Migrate".tl)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip".tl) { finish() }
                }
            }
        }
    }

    private func importFromWebDAV() async {
        isBusy = true
        defer { isBusy = false }
        error = nil
        let list = [urlString, username, password].map { $0.trimmingCharacters(in: .whitespaces) }
        guard list.allSatisfy({ !$0.isEmpty }) else {
            error = "All three fields are required".tl
            return
        }
        AppData.shared.settings["webdav"] = .array(list.map { .string($0) })
        do {
            try await DataSync.shared.download()
            done = true
            await ComicSourceManager.shared.reloadSources()
            AppServices.shared.refreshAfterMigration()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importFromClipboardOrSkip() {
        finish()
    }

    /// 结束向导：标记已选择（不再提示），回到主界面。
    private func finish() {
        AppData.shared.settings["disclaimerConsented"] = .bool(true)
        appState.needsMigration = false
    }
}
