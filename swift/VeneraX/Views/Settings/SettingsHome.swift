import SwiftUI
import LocalAuthentication
import VeneraKit

/// 设置分区路由。
enum SettingsRoute: String, Hashable, CaseIterable {
    case app, reader, favorites, dataSync, explore, network, debug, about

    var title: String {
        switch self {
        case .app: return "App".tl
        case .reader: return "Reading settings".tl
        case .favorites: return "Local Favorites".tl
        case .dataSync: return "Data & Sync".tl
        case .explore: return "Explore".tl
        case .network: return "Network".tl
        case .debug: return "Debug".tl
        case .about: return "About".tl
        }
    }

    var icon: String {
        switch self {
        case .app: return "paintbrush"
        case .reader: return "book"
        case .favorites: return "books.vertical"
        case .dataSync: return "arrow.triangle.2.circlepath"
        case .explore: return "safari"
        case .network: return "network"
        case .debug: return "ant"
        case .about: return "info.circle"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .app: AppSettingsSection()
        case .reader: ReaderSettingsSection()
        case .favorites: FavoritesSettingsSection()
        case .dataSync: DataSyncSettingsSection()
        case .explore: ExploreSettingsSection()
        case .network: NetworkSettingsSection()
        case .debug: DebugSettingsSection()
        case .about: AboutSettingsSection()
        }
    }
}

/// 设置主页：8 分区导航 + 设置搜索（对齐 settings_page.dart 的分区与
/// settings_search.dart 的搜索入口）。
struct SettingsHome: View {
    @State private var query = ""

    /// 搜索索引：(条目文案, 匹配关键词, 所在分区)。
    private static let searchIndex: [(title: String, route: SettingsRoute)] = [
        ("Theme Mode", .app), ("Theme Color", .app), ("Language", .app),
        ("Authorization Required", .app), ("Unlock method", .app),
        ("Reading mode", .reader), ("Page animation", .reader),
        ("Seamless chapter reading", .reader), ("Fill screen", .reader),
        ("Auto page turning interval", .reader), ("Number of images preloaded", .reader),
        ("Double tap to zoom", .reader), ("Long press to zoom", .reader),
        ("Reading background color", .reader), ("Night mode", .reader),
        ("Display time & battery info in reader", .reader), ("Show Page Number", .reader),
        ("Show Chapter Comments", .reader), ("Limit image width", .reader),
        ("Image enhancement", .reader), ("Quick collect image", .reader),
        ("Show local favorites before network favorites", .favorites),
        ("Add new favorite to", .favorites), ("Move favorite after reading", .favorites),
        ("Quick Favorite", .favorites), ("Click favorite", .favorites),
        ("Storage Path for local comics", .dataSync), ("Cache Size", .dataSync),
        ("Clear Cache", .dataSync), ("Auto clean reading history", .dataSync),
        ("Export App Data", .dataSync), ("Import App Data", .dataSync),
        ("Data Sync", .dataSync), ("Sync Mode", .dataSync),
        ("Backups to keep per platform", .dataSync), ("Skip Sync Items", .dataSync),
        ("Test Connection", .dataSync), ("Sync Logs", .dataSync),
        ("Display mode of comic tile", .explore), ("Size of comic tile", .explore),
        ("Explore Pages", .explore), ("Category Pages", .explore),
        ("Search Sources", .explore), ("Keyword blocking", .explore),
        ("Tag blocking", .explore), ("Comment keyword blocking", .explore),
        ("Default Search Target", .explore), ("Auto Language Filters", .explore),
        ("Initial Page", .explore), ("Reverse default chapter order", .explore),
        ("Proxy", .network), ("Download Threads", .network),
        ("Parallel Downloads", .network), ("Download on WiFi Only", .network),
        ("Reload Configs", .debug), ("Open Log", .debug),
        ("Ignore Certificate Errors", .debug), ("JS Evaluator", .debug),
        ("Check for updates", .about), ("Guide", .about), ("Repository", .about),
        ("User Agreement & Disclaimer", .about),
    ]

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    ForEach(Array(SettingsRoute.allCases.enumerated()), id: \.element) { _, route in
                        NavigationLink(value: route) {
                            Label(route.title, systemImage: route.icon)
                        }
                    }
                }
                Section("Shortcuts".tl) {
                    NavigationLink(value: "sources") {
                        Label("Comic Sources".tl, systemImage: "shippingbox")
                    }
                }
                Section("About".tl) {
                    LabeledContent("Data Path".tl) {
                        Text(verbatim: AppPaths.dataPath)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Search settings".tl) {
                    let q = query.lowercased()
                    let matches = Self.searchIndex.filter {
                        $0.title.lowercased().contains(q) || $0.route.title.lowercased().contains(q)
                    }
                    if matches.isEmpty {
                        Text("No results".tl).foregroundStyle(.secondary)
                    }
                    ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                        NavigationLink(value: match.route) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.title.tl)
                                Text(match.route.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings".tl)
        .searchable(text: $query, prompt: "Search settings".tl)
        .navigationDestination(for: SettingsRoute.self) { route in
            route.destination
        }
        .navigationDestination(for: String.self) { value in
            if value == "sources" {
                ComicSourcesView()
            }
        }
    }
}

/// 应用锁设置表单（开启「Authorization Required」时录入凭据）。
struct AppLockSetupSheet: View {
    enum LockKind: String, CaseIterable, Identifiable {
        case biometric, pin
        var id: String { rawValue }
        var label: String {
            rawValue == "biometric" ? "Biometric".tl : "PIN".tl
        }
    }

    @State private var kind: LockKind = .biometric
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void

    private var biometricAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Unlock method".tl) {
                    Picker("Unlock method".tl, selection: $kind) {
                        if biometricAvailable {
                            Text(LockKind.biometric.label).tag(LockKind.biometric)
                        }
                        Text(LockKind.pin.label).tag(LockKind.pin)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: kind) {
                        error = nil
                    }
                }
                Section {
                    SecureField("PIN (4-32 digits)".tl, text: $pin)
                        .keyboardType(.numberPad)
                    SecureField("Confirm PIN".tl, text: $confirmPin)
                        .keyboardType(.numberPad)
                    if kind == .biometric {
                        Text("Your PIN also works when biometric unlock fails.".tl)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Set PIN".tl)
                }
                if let error {
                    Text(verbatim: error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("App Lock".tl)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".tl) { save() }
                }
            }
        }
    }

    private func save() {
        guard pin.count >= 4, pin.count <= 32, pin.allSatisfy(\.isNumber) else {
            error = "PIN must be 4-32 digits".tl
            return
        }
        guard pin == confirmPin else {
            error = "PINs do not match".tl
            return
        }
        let salt = UUID().uuidString
        let hash = AppLockView.hashPin(pin, salt: salt)
        AppData.shared.settings["appLockCredential"] = .object([
            "salt": .string(salt),
            "hash": .string(hash),
        ])
        AppData.shared.settings["appLockType"] = .string(kind.rawValue)
        AppData.shared.settings["authorizationRequired"] = .bool(true)
        AppData.shared.saveData()
        onDone()
        dismiss()
    }
}
