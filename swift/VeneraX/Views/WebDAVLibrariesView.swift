import SwiftUI
import VeneraKit

/// WebDAV 远程漫画库管理与浏览（对齐原版 webdav_libraries_page.dart）。
struct WebDAVLibrariesView: View {
    @State private var libraries: [WebdavLibraryConfig] = []
    @State private var showEditSheet = false
    @State private var editingLibrary: WebdavLibraryConfig?
    @State private var selectedLibrary: WebdavLibraryConfig?
    @State private var migrationMessage: String?

    var body: some View {
        List {
            if libraries.isEmpty {
                ContentUnavailableView {
                    Label("No WebDAV libraries".tl, systemImage: "cloud")
                } description: {
                    Text("Add a WebDAV server to browse and stream remote comics".tl)
                }
            } else {
                ForEach(libraries) { lib in
                    NavigationLink(value: lib.id) {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.title2)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: lib.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Text(verbatim: lib.url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            WebDAVLibraryStore.shared.remove(id: lib.id)
                            reload()
                        } label: {
                            Label("Delete".tl, systemImage: "trash")
                        }

                        Button {
                            if DataSyncManager.shared.startWebDAVMigration(libraryID: lib.id) == nil {
                                migrationMessage = "No downloaded local comics or another WebDAV task is already running."
                            } else {
                                migrationMessage = "Migration started. Track progress in Task Center."
                            }
                        } label: {
                            Label("Migrate Local Comics".tl, systemImage: "arrow.up.right")
                        }
                        .tint(.green)

                        Button {
                            editingLibrary = lib
                            showEditSheet = true
                        } label: {
                            Label("Edit".tl, systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("WebDAV Libraries".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingLibrary = nil
                    showEditSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: String.self) { libId in
            if let lib = libraries.first(where: { $0.id == libId }) {
                WebDAVBrowserView(config: lib)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            WebDAVLibraryEditSheet(config: editingLibrary) {
                reload()
            }
        }
        .onAppear(perform: reload)
        .alert("WebDAV Migration".tl, isPresented: Binding(get: { migrationMessage != nil }, set: { if !$0 { migrationMessage = nil } })) {
            Button("OK".tl) { migrationMessage = nil }
        } message: { Text(verbatim: migrationMessage ?? "") }
    }

    private func reload() {
        libraries = WebDAVLibraryStore.shared.all()
    }
}

/// WebDAV 远程文件夹浏览器与流式漫画阅读。
struct WebDAVBrowserView: View {
    let config: WebdavLibraryConfig
    var path: String = "/"

    @State private var items: [String] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Connecting to WebDAV...".tl)
                    Spacer()
                }
                .padding()
            } else if let error {
                ContentUnavailableView {
                    Label("Connection Failed".tl, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Retry".tl) { Task { await loadPath() } }
                }
            } else if items.isEmpty {
                Text("Folder is empty".tl)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    NavigationLink(value: "\(path)\(item)/") {
                        HStack {
                            Image(systemName: item.hasSuffix(".cbz") || item.hasSuffix(".zip") ? "doc.zipper" : "folder.fill")
                                .foregroundStyle(item.hasSuffix(".cbz") || item.hasSuffix(".zip") ? .orange : .blue)
                            Text(verbatim: item)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
        .navigationTitle(path == "/" ? config.displayName : path)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPath()
        }
    }

    private func loadPath() async {
        isLoading = true
        error = nil
        do {
            let client = try WebDAVClient(url: config.url, username: config.user, password: config.pass)
            items = try await client.list(path)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}

/// WebDAV 漫画库配置编辑弹窗。
struct WebDAVLibraryEditSheet: View {
    let config: WebdavLibraryConfig?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var user: String = ""
    @State private var pass: String = ""
    @State private var root: String = ""
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Configuration".tl) {
                    TextField("Display name".tl, text: $name)
                    TextField("Server URL (WebDAV)".tl, text: $url)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Username".tl, text: $user)
                        .autocapitalization(.none)
                    SecureField("Password".tl, text: $pass)
                    TextField("Root Folder (optional)".tl, text: $root)
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test Connection".tl)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    if let testResult {
                        Text(verbatim: testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("OK") ? .green : .red)
                    }
                }
            }
            .navigationTitle(config == nil ? "Add WebDAV library".tl : "Edit WebDAV library".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".tl) {
                        save()
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let config {
                    name = config.name
                    url = config.url
                    user = config.user
                    pass = config.pass
                    root = config.root
                }
            }
        }
    }

    private func testConnection() {
        Task {
            isTesting = true
            testResult = nil
            do {
                let client = try WebDAVClient(url: url, username: user, password: pass)
                _ = try await client.list(root.isEmpty ? "/" : root)
                testResult = "Connection OK".tl
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func save() {
        if let config {
            WebDAVLibraryStore.shared.update(
                id: config.id,
                name: name,
                url: url,
                user: user,
                pass: pass,
                root: root
            )
        } else {
            WebDAVLibraryStore.shared.add(
                name: name,
                url: url,
                user: user,
                pass: pass,
                root: root
            )
        }
        onSave()
    }
}
