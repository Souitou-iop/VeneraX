import SwiftUI
import VeneraKit

/// 「Explore」分区（对齐 settings/explore.dart；页过滤编辑器与屏蔽词编辑器
/// 均为真实读写设置）。
struct ExploreSettingsSection: View {
    @State private var refreshID = UUID()

    var body: some View {
        Form {
            Section {
                SettingPickerRow(
                    title: "Display mode of comic tile".tl,
                    key: "comicDisplayMode",
                    options: [
                        .init(value: "detailed", label: "Detailed".tl),
                        .init(value: "brief", label: "Brief".tl),
                    ],
                    defaultValue: "detailed"
                )
                SettingSliderRow(
                    title: "Size of comic tile".tl,
                    key: "comicTileScale",
                    min: 0.5, max: 1.5, step: 0.05, defaultValue: 1.0,
                    format: { String(format: "%.2f", $0) }
                )
            }
            Section {
                NavigationLink("Explore Pages".tl) {
                    PageFilterEditorView(
                        titleKey: "Explore Pages",
                        settingKey: "explore_pages",
                        pages: visibleExplorePages
                    )
                }
                NavigationLink("Category Pages".tl) {
                    PageFilterEditorView(
                        titleKey: "Category Pages",
                        settingKey: "categories",
                        pages: visibleCategoryPages
                    )
                }
                NavigationLink("Network Favorite Pages".tl) {
                    PageFilterEditorView(
                        titleKey: "Network Favorite Pages",
                        settingKey: "favorites",
                        pages: visibleFavoritePages
                    )
                }
                NavigationLink("Search Sources".tl) {
                    PageFilterEditorView(
                        titleKey: "Search Sources",
                        settingKey: "searchSources",
                        pages: visibleSearchSources
                    )
                }
            }
            Section {
                SettingToggleRow(title: "Show favorite status on comic tile".tl, key: "showFavoriteStatusOnTile", defaultValue: true)
                SettingToggleRow(title: "Show history on comic tile".tl, key: "showHistoryStatusOnTile", defaultValue: true)
                SettingToggleRow(title: "Show read later status on comic tile".tl, key: "showReadLaterStatusOnTile", defaultValue: true)
                SettingToggleRow(title: "Reverse default chapter order".tl, key: "reverseChapterOrder", defaultValue: false)
            }
            Section {
                NavigationLink("Keyword blocking".tl) {
                    BlocklistEditorView(
                        settingKey: "blockedWords",
                        titleKey: "Keyword blocking",
                        hintKey: "Hides comics whose title, subtitle or description contains a keyword."
                    )
                }
                NavigationLink("Tag blocking".tl) {
                    BlocklistEditorView(
                        settingKey: "blockedTags",
                        titleKey: "Tag blocking",
                        hintKey: "Hides comics carrying a matching tag. A partial tag works, and tags are matched in the app's language."
                    )
                }
                NavigationLink("Comment keyword blocking".tl) {
                    BlocklistEditorView(
                        settingKey: "blockedCommentWords",
                        titleKey: "Comment keyword blocking",
                        hintKey: "Hides comments containing a keyword."
                    )
                }
            }
            Section {
                defaultSearchTargetPicker
                SettingPickerRow(
                    title: "Auto Language Filters".tl,
                    key: "autoAddLanguageFilter",
                    options: [
                        .init(value: "none", label: "None".tl),
                        .init(value: "chinese", label: "Chinese"),
                        .init(value: "english", label: "English"),
                        .init(value: "japanese", label: "Japanese"),
                    ],
                    defaultValue: "none"
                )
                SettingPickerRow(
                    title: "Initial Page".tl,
                    key: "initialPage",
                    options: [
                        .init(value: "0", label: "Home Page".tl),
                        .init(value: "1", label: "Favorites Page".tl),
                        .init(value: "2", label: "Explore Page".tl),
                        .init(value: "3", label: "Categories Page".tl),
                    ],
                    defaultValue: "0"
                )
                SettingPickerRow(
                    title: "Display mode of comic list".tl,
                    key: "comicListDisplayMode",
                    options: [
                        .init(value: "paging", label: "Paging".tl),
                        .init(value: "Continuous", label: "Continuous".tl),
                    ],
                    defaultValue: "paging"
                )
            }
        }
        .navigationTitle("Explore".tl)
        .id(refreshID)
    }

    /// 默认搜索目标（聚合 + 全部支持搜索的源，对齐原版选项）。
    @ViewBuilder
    private var defaultSearchTargetPicker: some View {
        let sources = ComicSourceManager.shared.all().filter { $0.searchAvailable }
        Picker("Default Search Target".tl, selection: Binding(
            get: { AppData.shared.settings["defaultSearchTarget"].stringValue ?? "_aggregated_" },
            set: {
                AppData.shared.settings["defaultSearchTarget"] = .string($0)
                AppData.shared.saveData()
            }
        )) {
            Text("Aggregated".tl).tag("_aggregated_")
            ForEach(sources, id: \.key) { source in
                Text(verbatim: source.name).tag(source.key)
            }
        }
    }

    /// 各可见页候选（对齐 setExplorePagesWidget 等的键语义：探索页用标题，
    /// 分类页/网络收藏页用 key，搜索源用源 key）。
    private var visibleExplorePages: [(id: String, label: String)] {
        ComicSourceManager.shared.all().flatMap { source in
            source.explorePages.map { page in
                (id: page.title, label: "\(source.name) · \(page.title)")
            }
        }
    }

    private var visibleCategoryPages: [(id: String, label: String)] {
        ComicSourceManager.shared.all().compactMap { source in
            source.categoryData.map { (id: $0.key, label: "\(source.name) · \($0.title)") }
        }
    }

    private var visibleFavoritePages: [(id: String, label: String)] {
        ComicSourceManager.shared.all().compactMap { source in
            guard source.favoriteDataAvailable, let key = source.favoriteDataKey else { return nil }
            return (id: key, label: "\(source.name) · Network Favorites".tl)
        }
    }

    private var visibleSearchSources: [(id: String, label: String)] {
        ComicSourceManager.shared.all().filter { $0.searchAvailable }
            .map { (id: $0.key, label: $0.name) }
    }
}

/// 「Local Favorites」分区（对齐 settings/local_favorites.dart）。
struct FavoritesSettingsSection: View {
    @State private var message: String?
    @State private var isCleaning = false

    private var folderNames: [String] {
        LocalFavoritesManager.shared.getFoldersSorted()
    }

    var body: some View {
        Form {
            Section {
                SettingToggleRow(
                    title: "Show local favorites before network favorites".tl,
                    key: "localFavoritesFirst",
                    defaultValue: true
                )
                SettingToggleRow(
                    title: "Auto close favorite panel after operation".tl,
                    key: "autoCloseFavoritePanel",
                    defaultValue: false
                )
                SettingPickerRow(
                    title: "Add new favorite to".tl,
                    key: "newFavoriteAddTo",
                    options: [
                        .init(value: "start", label: "Start".tl),
                        .init(value: "end", label: "End".tl),
                    ],
                    defaultValue: "end"
                )
                SettingPickerRow(
                    title: "Move favorite after reading".tl,
                    key: "moveFavoriteAfterRead",
                    options: [
                        .init(value: "none", label: "None".tl),
                        .init(value: "end", label: "End".tl),
                        .init(value: "start", label: "Start".tl),
                    ],
                    defaultValue: "none"
                )
                quickFavoritePicker
                SettingPickerRow(
                    title: "Click favorite".tl,
                    key: "onClickFavorite",
                    options: [
                        .init(value: "viewDetail", label: "View Detail".tl),
                        .init(value: "read", label: "Read".tl),
                    ],
                    defaultValue: "viewDetail"
                )
            }
            Section {
                SettingActionRow(
                    title: "Delete all unavailable local favorite items".tl,
                    actionTitle: isCleaning ? "…" : "Delete".tl
                ) {
                    cleanInvalid()
                }
                if let message {
                    Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Local Favorites".tl)
    }

    /// 长按收藏按钮快速加入的文件夹。
    @ViewBuilder
    private var quickFavoritePicker: some View {
        let folders = folderNames
        Picker("Quick Favorite".tl, selection: Binding(
            get: { AppData.shared.settings["quickFavorite"].stringValue ?? "" },
            set: {
                AppData.shared.settings["quickFavorite"] = $0.isEmpty ? .null : .string($0)
                AppData.shared.saveData()
            }
        )) {
            Text("Not enable".tl).tag("")
            ForEach(folders, id: \.self) { folder in
                Text(verbatim: folder).tag(folder)
            }
        }
        Text("Long press on the favorite button to quickly add to this folder".tl)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func cleanInvalid() {
        isCleaning = true
        Task {
            let count = LocalFavoritesManager.shared.removeInvalid()
            await MainActor.run {
                isCleaning = false
                message = "Deleted @a favorite items".replacingOccurrences(of: "@a", with: String(count)).tl
            }
        }
    }
}

/// 「Network」分区（对齐 settings/network.dart；DNS 覆盖/SNI 为 URLSession
/// 平台限制未迁移，见 PARITY 已知差异）。
struct NetworkSettingsSection: View {
    @State private var showProxyEditor = false

    var body: some View {
        Form {
            Section {
                SettingActionRow(
                    title: "Proxy".tl,
                    subtitle: proxySummary,
                    actionTitle: "Edit".tl
                ) {
                    showProxyEditor = true
                }
            }
            Section {
                SettingSliderRow(
                    title: "Download Threads".tl,
                    key: "downloadThreads",
                    min: 1, max: 16, step: 1, defaultValue: 5
                )
                SettingSliderRow(
                    title: "Parallel Downloads".tl,
                    key: "maxParallelDownloads",
                    min: 1, max: 3, step: 1, defaultValue: 1
                )
                SettingToggleRow(
                    title: "Download on WiFi Only".tl,
                    key: "downloadWifiOnly",
                    defaultValue: false
                )
            }
        }
        .navigationTitle("Network".tl)
        .sheet(isPresented: $showProxyEditor) {
            ProxyEditorView()
        }
    }

    private var proxySummary: String {
        let proxy = AppData.shared.settings["proxy"].stringValue ?? "system"
        switch proxy {
        case "direct": return "Direct".tl
        case "system": return "System".tl
        default:
            if proxy.contains("@") {
                let auth = proxy.split(separator: "@").first.map(String.init) ?? ""
                let host = proxy.split(separator: "@").last.map(String.init) ?? proxy
                return "Manual".tl + " (\(auth.components(separatedBy: ":").first ?? ""))@\(host)"
            }
            return "Manual".tl + " (\(proxy))"
        }
    }
}

/// 代理设置（direct/system/manual，manual 为 [user:pass@]host:port，对齐
/// 原版 _ProxySettingView 的字符串协议；HTTPClient 消费同一格式）。
struct ProxyEditorView: View {
    enum ProxyType: String, CaseIterable, Identifiable {
        case direct, system, manual
        var id: String { rawValue }
    }

    @State private var type: ProxyType = .system
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type".tl, selection: $type) {
                        Text("Direct".tl).tag(ProxyType.direct)
                        Text("System".tl).tag(ProxyType.system)
                        Text("Manual".tl).tag(ProxyType.manual)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: type) {
                        if type != .manual {
                            persist()
                            dismiss()
                        }
                    }
                }
                if type == .manual {
                    Section("Manual".tl) {
                        TextField("Host".tl, text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port".tl, text: $port)
                            .keyboardType(.numberPad)
                        TextField("Username".tl, text: $username)
                            .textInputAutocapitalization(.never)
                        SecureField("Password".tl, text: $password)
                    }
                }
            }
            .navigationTitle("Proxy".tl)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".tl) {
                        persist()
                        dismiss()
                    }
                    .disabled(type == .manual && host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let proxy = AppData.shared.settings["proxy"].stringValue ?? "system"
        if proxy == "direct" || proxy == "system" {
            type = ProxyType(rawValue: proxy) ?? .system
            return
        }
        type = .manual
        var rest = proxy
        if let at = proxy.firstIndex(of: "@") {
            let auth = String(proxy[..<at])
            rest = String(proxy[proxy.index(after: at)...])
            let parts = auth.components(separatedBy: ":")
            username = parts.count > 0 ? parts[0] : ""
            password = parts.count > 1 ? parts[1] : ""
        }
        let hostPort = rest.components(separatedBy: ":")
        host = hostPort.count > 0 ? hostPort[0] : ""
        port = hostPort.count > 1 ? hostPort[1] : ""
    }

    /// 序列化为原版协议字符串（USERNAME:PASSWORD@HOST:PORT）。
    private func persist() {
        let value: String
        switch type {
        case .direct:
            value = "direct"
        case .system:
            value = "system"
        case .manual:
            var prefix = ""
            if !username.isEmpty {
                prefix = username + (password.isEmpty ? "" : ":\(password)") + "@"
            }
            value = prefix + host + (port.isEmpty ? "" : ":\(port)")
        }
        AppData.shared.settings["proxy"] = .string(value)
        AppData.shared.saveData()
    }
}
