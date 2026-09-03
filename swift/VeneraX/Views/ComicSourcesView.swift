import SwiftUI
import VeneraKit

/// 漫画源管理与在线市场：已安装源管理（支持拖拽排序与滑动删除）+ 源市场在线目录 + 一键安装与批量更新。
struct ComicSourcesView: View {
    @State private var selectedTab = 0 // 0: Installed, 1: Market
    @State private var sources: [ComicSource] = []
    @State private var availableUpdates: [String: String] = [:]
    @State private var catalogSources: [CatalogSourceItem] = []
    @State private var isCheckingCatalog = false
    @State private var installURL = ""
    @State private var showInstaller = false
    @State private var isInstalling = false
    @State private var message: String?
    @State private var error: String?
    @State private var marketSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab".tl, selection: $selectedTab) {
                Text("Installed".tl).tag(0)
                Text("Source Market".tl).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedTab == 0 {
                installedList
            } else {
                marketList
            }
        }
        .navigationTitle("Comic Sources".tl)
        .toolbar {
            if selectedTab == 0 {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if selectedTab == 0 {
                    Menu {
                        Button {
                            showInstaller = true
                        } label: {
                            Label("Install from URL".tl, systemImage: "link")
                        }

                        Button {
                            checkCatalogUpdates()
                        } label: {
                            Label("Check Updates".tl, systemImage: "arrow.clockwise")
                        }

                        if !availableUpdates.isEmpty {
                            Button {
                                updateAll()
                            } label: {
                                Label("Update All (\(availableUpdates.count))".tl, systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                } else {
                    Button {
                        checkCatalogUpdates()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationDestination(for: SourceTarget.self) { target in
            if let source = sources.first(where: { $0.key == target.key }) {
                SourceSettingsView(source: source)
            }
        }
        .alert("Add Source".tl, isPresented: $showInstaller) {
            TextField("Script URL".tl, text: $installURL)
            Button("Install".tl) { Task { await installFromURL() } }
            Button("Cancel".tl, role: .cancel) {}
        } message: {
            Text("Enter the .js script URL of a comic source".tl)
        }
        .overlay {
            if isInstalling {
                ProgressView("Installing".tl)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: AppServices.shared.sources.count) { _, _ in reload() }
    }

    private var installedList: some View {
        List {
            if !availableUpdates.isEmpty {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(availableUpdates.count) updates available".tl)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Tap to update all installed sources".tl)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update All".tl) {
                            updateAll()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Section("Installed Sources".tl) {
                ForEach(sources, id: \.key) { source in
                    NavigationLink(value: SourceTarget.key(source.key)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: source.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    if source.isLogged {
                                        Image(systemName: "person.crop.circle.badge.checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(verbatim: "v\(source.version) · \(source.key)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let newVer = availableUpdates[source.key] {
                                Text("v\(newVer)".tl)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                            }
                        }
                    }
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
        }
    }

    private var marketList: some View {
        Group {
            if isCheckingCatalog {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading source catalog...".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalogSources.isEmpty {
                ContentUnavailableView {
                    Label("No catalog sources".tl, systemImage: "network.slash")
                } description: {
                    Text("Tap refresh to fetch sources from catalog".tl)
                } actions: {
                    Button("Refresh".tl) { checkCatalogUpdates() }
                }
            } else {
                List {
                    ForEach(filteredMarketSources) { item in
                        let isInstalled = sources.contains { $0.key == item.key }
                        let currentSource = sources.first { $0.key == item.key }
                        let hasUpdate = isInstalled && currentSource != nil && SourceCatalogManager.shared.compareVersions(item.version, currentSource!.version) > 0

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: item.name)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                if !item.description.isEmpty {
                                    // 不限行数（对齐原版 fix: show full description
                                    // in available plugin list）：截断的描述让用户
                                    // 看不到插件实际功能；行数增多时动作按钮仍
                                    // 顶部对齐在标题旁。
                                    Text(verbatim: item.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 6) {
                                    Text(verbatim: "v\(item.version)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    if !item.author.isEmpty {
                                        Text(verbatim: "· \(item.author)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            Spacer()

                            if hasUpdate {
                                Button("Update".tl) {
                                    installFromMarket(item)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else if isInstalled {
                                Text("Installed".tl)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                            } else {
                                Button("Install".tl) {
                                    installFromMarket(item)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .searchable(text: $marketSearch, prompt: "Search sources".tl)
            }
        }
    }

    private var filteredMarketSources: [CatalogSourceItem] {
        if marketSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            return catalogSources
        }
        let kw = marketSearch.lowercased()
        return catalogSources.filter {
            $0.name.lowercased().contains(kw) ||
            $0.key.lowercased().contains(kw) ||
            $0.description.lowercased().contains(kw) ||
            $0.author.lowercased().contains(kw)
        }
    }

    private func reload() {
        sources = AppServices.shared.sources
        availableUpdates = SourceCatalogManager.shared.availableUpdates
        catalogSources = SourceCatalogManager.shared.catalogSources
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let key = sources[index].key
            try? ComicSourceManager.shared.remove(key)
        }
        sources = AppServices.shared.sources
    }

    private func move(from source: IndexSet, to destination: Int) {
        sources.move(fromOffsets: source, toOffset: destination)
        let keys = sources.map { $0.key }
        AppData.shared.settings["comicSourceOrder"] = .array(keys.map { .string($0) })
        AppData.shared.saveData()
        ComicSourceManager.shared.applyOrder()
    }

    private func checkCatalogUpdates() {
        Task {
            isCheckingCatalog = true
            _ = try? await SourceCatalogManager.shared.fetchCatalog()
            isCheckingCatalog = false
            reload()
        }
    }

    private func updateAll() {
        _ = SourceUpdateManager.shared.startAvailableUpdates()
        reload()
    }

    private func installFromMarket(_ item: CatalogSourceItem) {
        Task {
            isInstalling = true
            try? await SourceCatalogManager.shared.installSource(from: item)
            isInstalling = false
            reload()
        }
    }

    private func installFromURL() async {
        let urlString = installURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }
        isInstalling = true
        defer { isInstalling = false }
        let response = await HTTPClient.shared.request(method: "GET", url: urlString)
        if let error = response.error {
            self.error = error
            return
        }
        guard (200..<300).contains(response.status ?? 0) else {
            self.error = "HTTP \(response.status ?? 0)"
            return
        }
        guard let js = String(data: response.body, encoding: .utf8) else {
            self.error = "Invalid script content"
            return
        }
        let fileName = URL(string: urlString)?.lastPathComponent ?? "source_\(Int(Date().timeIntervalSince1970)).js"
        do {
            _ = try await ComicSourceManager.shared.install(js: js, fileName: fileName)
            sources = AppServices.shared.sources
            message = "Installed".tl
            installURL = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SourceTarget: Hashable {
    let key: String

    static func key(_ key: String) -> SourceTarget { SourceTarget(key: key) }
}

/// 源设置与账号：settings 表单（select/switch/input/callback）+ 登录。
struct SourceSettingsView: View {
    let source: ComicSource

    @State private var settingValues: [String: String] = [:]
    @State private var account = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        Form {
            if let accountConfig = source.account {
                Section("Account".tl) {
                    if accountConfig.isLogged {
                        LabeledContent("Status".tl, value: "Logged in".tl)
                        Button("Logout".tl, role: .destructive) {
                            source.logout()
                            refresh()
                        }
                    } else if accountConfig.hasLogin {
                        TextField("Account".tl, text: $account)
                        SecureField("Password".tl, text: $password)
                        Button("Login".tl) {
                            Task { await login() }
                        }
                        .disabled(account.isEmpty || password.isEmpty || isBusy)
                    }
                    if !accountConfig.cookieFields.isEmpty {
                        Text("Cookie fields".tl + ": \(accountConfig.cookieFields.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let registerURL = accountConfig.registerWebsite {
                        Link("Register".tl, destination: URL(string: registerURL) ?? URL(string: "about:blank")!)
                            .font(.caption)
                    }
                }
            }

            if !source.settings.isEmpty {
                Section("Settings".tl) {
                    ForEach(source.settings.keys.sorted(), id: \.self) { key in
                        settingRow(source.settings[key]!)
                    }
                }
            }

            Section("About".tl) {
                LabeledContent("Key".tl, value: source.key)
                LabeledContent("Version".tl, value: source.version)
                if !source.url.isEmpty {
                    LabeledContent("URL".tl) {
                        Text(verbatim: source.url)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }

            if let error {
                Section {
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var values: [String: String] = [:]
        for (key, setting) in source.settings {
            let current = (try? source.loadSetting(key)) ?? setting.defaultValue
            values[key] = current.stringValue ?? current.intValue.map(String.init) ?? ""
        }
        settingValues = values
    }

    @ViewBuilder
    private func settingRow(_ setting: SourceSetting) -> some View {
        switch setting.type {
        case .select:
            Picker(setting.title, selection: Binding(
                get: { settingValues[setting.key] ?? "" },
                set: { newValue in
                    settingValues[setting.key] = newValue
                    source.saveData("settings", savedSettings(with: setting.key, value: .string(newValue)))
                }
            )) {
                ForEach(setting.options, id: \.value) { option in
                    Text(verbatim: option.text).tag(option.value)
                }
            }
        case .input:
            TextField(setting.title, text: Binding(
                get: { settingValues[setting.key] ?? "" },
                set: { newValue in
                    settingValues[setting.key] = newValue
                    source.saveData("settings", savedSettings(with: setting.key, value: .string(newValue)))
                }
            ))
        case .switch:
            EmptyView()
        case .callback:
            Button(setting.title) {
                Task { _ = try? await source.invoke("ComicSource.sources.\(source.key).settings.\(setting.key).callback()") }
            }
        }
    }

    private func savedSettings(with key: String, value: JSON) -> JSON {
        var current = source.loadData("settings").objectValue ?? [:]
        current[key] = value
        return .object(current)
    }

    private func login() async {
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            try await source.login(account: account, password: password)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
