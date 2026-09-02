import SwiftUI
import VeneraKit

/// 主框架：支持 iPhone 底部 TabView 与 iPad / Mac 宽屏 NavigationSplitView 侧边栏自适应（对齐原版多端响应式）。
struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tabSelection = 0
    @State private var sidebarSelection: SidebarItem? = .home

    enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
        case home = "home"
        case favorites = "favorites"
        case explore = "explore"
        case categories = "categories"
        case local = "local"
        case followUpdates = "followUpdates"
        case readLater = "readLater"
        case history = "history"
        case collections = "collections"
        case imageFavorites = "imageFavorites"
        case statistics = "statistics"
        case tasks = "tasks"
        case sources = "sources"
        case settings = "settings"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home".tl
            case .favorites: return "Favorites".tl
            case .explore: return "Explore".tl
            case .categories: return "Categories".tl
            case .local: return "Local Comics".tl
            case .followUpdates: return "Follow Updates".tl
            case .readLater: return "Read Later".tl
            case .history: return "History".tl
            case .collections: return "Collections".tl
            case .imageFavorites: return "Image Favorites".tl
            case .statistics: return "Reading Statistics".tl
            case .tasks: return "Task Center".tl
            case .sources: return "Comic Sources".tl
            case .settings: return "Settings".tl
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .favorites: return "heart.fill"
            case .explore: return "globe.asia.australia.fill"
            case .categories: return "square.grid.2x2.fill"
            case .local: return "folder.fill"
            case .followUpdates: return "bell.badge.fill"
            case .readLater: return "clock"
            case .history: return "clock.arrow.circlepath"
            case .collections: return "square.stack.3d.down.right"
            case .imageFavorites: return "photo.on.rectangle.angled"
            case .statistics: return "chart.bar.xaxis"
            case .tasks: return "checklist"
            case .sources: return "shippingbox"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            padSidebarLayout
        } else {
            phoneTabLayout
        }
    }

    /// iPhone 紧凑布局：4 基础 Tab。
    private var phoneTabLayout: some View {
        TabView(selection: $tabSelection) {
            TabSection {
                Tab("Home".tl, systemImage: "house.fill", value: 0) {
                    HomeView()
                }
                Tab("Favorites".tl, systemImage: "heart.fill", value: 1) {
                    FavoritesView()
                }
                Tab("Explore".tl, systemImage: "globe.asia.australia.fill", value: 2) {
                    ExploreView()
                }
                Tab("Categories".tl, systemImage: "square.grid.2x2.fill", value: 3) {
                    CategoriesView()
                }
            } header: {
                Label("Browse".tl, systemImage: "circle.hexagonpath")
            }
            Tab("Search".tl, systemImage: "magnifyingglass", value: 4, role: .search) {
                NavigationStack {
                    SearchView()
                }
            }
        }
        .modifier(SearchTabActivationModifier())
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            tabSelection = initialPageSelection
        }
    }

    private var initialPageSelection: Int {
        min(max(AppData.shared.settings["initialPage"].intValue ?? 0, 0), 3)
    }

    /// iPad / Mac 宽屏布局：侧边栏 NavigationSplitView。
    private var padSidebarLayout: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Discover".tl) {
                    sidebarRow(.home)
                    sidebarRow(.favorites)
                    sidebarRow(.explore)
                    sidebarRow(.categories)
                }

                Section("Library".tl) {
                    sidebarRow(.local)
                    sidebarRow(.followUpdates)
                    sidebarRow(.readLater)
                    sidebarRow(.history)
                    sidebarRow(.collections)
                    sidebarRow(.imageFavorites)
                    sidebarRow(.statistics)
                }

                Section("System".tl) {
                    sidebarRow(.tasks)
                    sidebarRow(.sources)
                    sidebarRow(.settings)
                }
            }
            .navigationTitle("VeneraX")
        } detail: {
            NavigationStack {
                detailView(for: sidebarSelection ?? .home)
                    .modifier(AppDestinations())
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        NavigationLink(value: item) {
            Label(item.title, systemImage: item.icon)
        }
    }

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .home: HomeView()
        case .favorites: FavoritesView()
        case .explore: ExploreView()
        case .categories: CategoriesView()
        case .local: LocalComicsView()
        case .followUpdates: FollowUpdatesView()
        case .readLater: ReadLaterView()
        case .history: HistoryListView()
        case .collections: ComicCollectionsView()
        case .imageFavorites: ImageFavoritesView()
        case .statistics: ReadingStatisticsView()
        case .tasks: TasksView()
        case .sources: ComicSourcesView()
        case .settings: SettingsHome()
        }
    }
}

/// 全局覆盖层：源脚本 UI 消息（Toast / 对话框 / 输入框 / Cloudflare 挑战）。
struct AppOverlays: View {
    @State private var services = AppServices.shared

    var body: some View {
        EmptyView()
            .overlay(alignment: .top) {
                if let toast = services.toast {
                    Text(verbatim: toast)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .alert(
                services.jsAlert?.title ?? "",
                isPresented: Binding(
                    get: { services.jsAlert != nil },
                    set: { if !$0 { services.jsAlert = nil } }
                )
            ) {
                Button("OK".tl) { services.jsAlert = nil }
            } message: {
                Text(verbatim: services.jsAlert?.content ?? "")
            }
            .sheet(item: $services.jsInput) { input in
                JSInputSheet(input: input) { result in
                    input.completion(result)
                    services.jsInput = nil
                }
            }
            .sheet(item: $services.jsSelect) { select in
                JSSelectSheet(select: select) { result in
                    select.completion(result)
                    services.jsSelect = nil
                }
            }
            .sheet(item: $services.cloudflareRequest) { req in
                CloudflareChallengeSheet(url: req.url, headers: req.headers, onComplete: req.completion)
            }
    }
}


/// JS 源的原生输入对话框。不能用 alert 代替，否则确认按钮会丢失用户输入。
private struct JSInputSheet: View {
    let input: AppServices.JSInput
    let finish: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(input.title, text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(input.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) {
                        finish(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK".tl) {
                        finish(value)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(180)])
    }
}


/// JS 源的选项对话框。原先会直接回传 initialIndex，用户没有机会选择。
private struct JSSelectSheet: View {
    let select: AppServices.JSSelect
    let finish: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int

    init(select: AppServices.JSSelect, finish: @escaping (Int?) -> Void) {
        self.select = select
        self.finish = finish
        _selectedIndex = State(initialValue: min(max(select.initialIndex ?? 0, 0), max(select.options.count - 1, 0)))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(select.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        selectedIndex = index
                    } label: {
                        HStack {
                            Text(verbatim: option)
                            Spacer()
                            if selectedIndex == index {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(select.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) {
                        finish(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK".tl) {
                        finish(select.options.indices.contains(selectedIndex) ? selectedIndex : nil)
                        dismiss()
                    }
                    .disabled(select.options.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}


private struct SearchTabActivationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }
}
