import SwiftUI
import VeneraKit

/// 探索页：对标原版 Flutter ExplorePage。
/// 顶部提供与演示网页完全一致的「自适应横向流体胶囊滑块（Scrollable Fluid Capsule Slider）」，
/// 带有平滑滑动的悬浮白色药丸滑块、源标识 Badge 与「+」管理入口，文字自适应展开永不截断，
/// 支持单页多分段（singlePageWithMultiPart）与多页瀑布流（multiPageComicList）两种形态。
struct ExploreView: View {
    @State private var selectedTabKey: String = ""
    @State private var showSettingsSheet = false
    @State private var refreshID = UUID()

    struct ExploreTabItem: Identifiable, Hashable {
        var id: String { "\(sourceKey)::\(pageIndex)::\(title)" }
        let sourceKey: String
        let sourceName: String
        let pageIndex: Int
        let title: String
        let type: ComicSource.ExplorePage.PageType
    }

    /// 获取所有应该展示的探索分区（结合设置与所有已安装源）。
    private var allExploreTabs: [ExploreTabItem] {
        var allItems: [ExploreTabItem] = []
        for source in AppServices.shared.sources {
            for page in source.explorePages {
                allItems.append(ExploreTabItem(
                    sourceKey: source.key,
                    sourceName: source.name,
                    pageIndex: page.index,
                    title: page.title,
                    type: page.type
                ))
            }
        }

        let configuredKeys = AppData.shared.settings["explore_pages"].arrayValue?
            .compactMap { $0.stringValue } ?? []

        if !configuredKeys.isEmpty {
            var ordered: [ExploreTabItem] = []
            for key in configuredKeys {
                if let matched = allItems.first(where: { $0.title == key || $0.id == key }) {
                    ordered.append(matched)
                }
            }
            for item in allItems {
                if !ordered.contains(where: { $0.sourceKey == item.sourceKey && $0.pageIndex == item.pageIndex }) {
                    ordered.append(item)
                }
            }
            return ordered
        }

        return allItems
    }

    private var effectiveTabKey: String {
        if !selectedTabKey.isEmpty && allExploreTabs.contains(where: { $0.id == selectedTabKey }) {
            return selectedTabKey
        }
        return allExploreTabs.first?.id ?? ""
    }

    var body: some View {
        NavigationStack {
            Group {
                if allExploreTabs.isEmpty {
                    ContentUnavailableView {
                        Label("Explore".tl, systemImage: "globe.asia.australia.fill")
                    } description: {
                        Text("Add a comic source to start exploring".tl)
                    } actions: {
                        NavigationLink(value: "sources") {
                            Text("Manage Comic Sources".tl)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 0) {
                        tabHeaderBar
                        tabContentView
                    }
                }
            }
            .navigationTitle("Explore".tl)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(BrowseToolbar())
            .modifier(AppDestinations())
            .sheet(isPresented: $showSettingsSheet) {
                ExplorePagesSettingsSheet()
                    .onDisappear {
                        refreshID = UUID()
                        ensureSelection()
                    }
            }
            .onAppear {
                ensureSelection()
            }
            .id(refreshID)
        }
    }

    private func ensureSelection() {
        if selectedTabKey.isEmpty || !allExploreTabs.contains(where: { $0.id == selectedTabKey }) {
            selectedTabKey = allExploreTabs.first?.id ?? ""
        }
    }

    /// 顶部与演示网页 1:1 对齐的流体胶囊滑块栏。
    private var tabHeaderBar: some View {
        HStack(spacing: 8) {
            ScrollableCapsuleSegmentedControl(
                items: allExploreTabs,
                selection: Binding(
                    get: { effectiveTabKey },
                    set: { selectedTabKey = $0 }
                ),
                title: { $0.title },
                badge: { $0.sourceName }
            )

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showSettingsSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 34, height: 34)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    /// 探索页面内容展示：直接渲染当前选中的分区分页。
    @ViewBuilder
    private var tabContentView: some View {
        let key = effectiveTabKey
        if let currentTab = allExploreTabs.first(where: { $0.id == key }) {
            SingleExplorePageView(tab: currentTab)
                .id(currentTab.id)
                // TabView's translucent tab bar overlays scroll content on iOS.
                // Reserve a real bottom viewport so the last row remains readable.
                .safeAreaPadding(.bottom, 88)
        } else {
            ContentUnavailableView("Select an explore page".tl, systemImage: "tray")
        }
    }
}

/// 单个探索页视图：支持 multiPageComicList 与 singlePageWithMultiPart。
struct SingleExplorePageView: View {
    let tab: ExploreView.ExploreTabItem

    @State private var multiPartSections: [(title: String, comics: [Comic])] = []
    @State private var isLoadingMultiPart = false
    @State private var multiPartError: String?

    private var source: ComicSource? {
        ComicSourceManager.shared.find(tab.sourceKey)
    }

    var body: some View {
        Group {
            if tab.type == .singlePageWithMultiPart {
                multiPartView
            } else {
                ComicListView(loader: .explore(sourceKey: tab.sourceKey, exploreIndex: tab.pageIndex))
            }
        }
    }

    @ViewBuilder
    private var multiPartView: some View {
        Group {
            if isLoadingMultiPart && multiPartSections.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = multiPartError, multiPartSections.isEmpty {
                ContentUnavailableView {
                    Label("Network Error".tl, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Retry".tl) {
                        Task { await loadMultiPart() }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(multiPartSections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(verbatim: section.title)
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 12) {
                                        ForEach(section.comics, id: \.id) { comic in
                                            ComicTile(comic: comic)
                                                .frame(width: 110)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                    .padding(.top, 14)
                    // The iPhone tab bar is translucent and overlays the scroll view.
                    // Keep a complete final card row above it.
                    .padding(.bottom, 112)
                }
                .refreshable {
                    await loadMultiPart()
                }
            }
        }
        .task {
            if multiPartSections.isEmpty {
                await loadMultiPart()
            }
        }
    }

    private func loadMultiPart() async {
        guard let source else { return }
        isLoadingMultiPart = true
        defer { isLoadingMultiPart = false }
        multiPartError = nil
        do {
            let sections = try await source.loadExploreMultiPart(tab.pageIndex)
            multiPartSections = sections.map { (title: $0.title, comics: BlockListFilter.filterComics($0.comics)) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var error: String? {
        get { multiPartError }
        nonmutating set { multiPartError = newValue }
    }
}

/// 探索页分区管理弹窗（对齐原版 setExplorePagesWidget）。
struct ExplorePagesSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var availablePages: [ComicSource.ExplorePage] = []
    @State private var selectedTitles: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppServices.shared.sources, id: \.key) { source in
                    Section(source.name) {
                        ForEach(source.explorePages, id: \.index) { page in
                            HStack {
                                Text(verbatim: page.title)
                                Spacer()
                                if selectedTitles.contains(page.title) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedTitles.contains(page.title) {
                                    selectedTitles.remove(page.title)
                                } else {
                                    selectedTitles.insert(page.title)
                                }
                                save()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Explore Pages".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done".tl) { dismiss() }
                }
            }
            .onAppear {
                let current = AppData.shared.settings["explore_pages"].arrayValue?
                    .compactMap { $0.stringValue } ?? []
                selectedTitles = Set(current)
            }
        }
    }

    private func save() {
        AppData.shared.settings["explore_pages"] = .array(selectedTitles.map { .string($0) })
        AppData.shared.saveData(sync: true)
    }
}

/// 分类总览页（对齐原版 category_page.dart）。
struct CategoriesView: View {
    private var sources: [ComicSource] {
        AppServices.shared.sources.filter { $0.categoryData != nil || $0.rankingAvailable }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty {
                    ContentUnavailableView {
                        Label("Categories".tl, systemImage: "square.grid.2x2.fill")
                    } description: {
                        Text("Install a comic source that provides categories".tl)
                    }
                } else {
                    List {
                        ForEach(sources, id: \.key) { source in
                            Section(source.name) {
                                if let categoryData = source.categoryData {
                                    ForEach(categoryData.parts, id: \.name) { part in
                                        NavigationLink(value: CategoryPartTarget(
                                            sourceKey: source.key,
                                            partName: part.name
                                        )) {
                                            Label(part.name.isEmpty ? "Categories".tl : part.name, systemImage: "tag")
                                        }
                                    }
                                }
                                if source.rankingAvailable {
                                    NavigationLink(value: CategoryPartTarget(
                                        sourceKey: source.key,
                                        partName: "__ranking__"
                                    )) {
                                        Label("Ranking".tl, systemImage: "chart.bar")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Categories".tl)
            .modifier(BrowseToolbar())
            .modifier(AppDestinations())
            .navigationDestination(for: CategoryPartTarget.self) { target in
                CategoryPartView(sourceKey: target.sourceKey, partName: target.partName)
            }
        }
    }
}

/// 某源某分类分区的标签页 / 排行榜选项页。
struct CategoryPartView: View {
    let sourceKey: String
    let partName: String

    private var source: ComicSource? {
        ComicSourceManager.shared.find(sourceKey)
    }

    var body: some View {
        Group {
            if partName == "__ranking__" {
                rankingList
            } else {
                categoryList
            }
        }
        .navigationTitle(partName == "__ranking__" ? "Ranking".tl : partName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var categoryList: some View {
        let part = source?.categoryData?.parts.first { $0.name == partName }
        if let part {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                    ForEach(Array(part.categories.enumerated()), id: \.offset) { index, name in
                        NavigationLink(value: CategoryComicsTarget(
                            sourceKey: sourceKey,
                            category: name,
                            param: part.param(at: index),
                            options: source?.categoryComicsOptionDefaults() ?? []
                        )) {
                            Text(verbatim: name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No Data".tl, systemImage: "tray")
        }
    }

    @ViewBuilder
    private var rankingList: some View {
        let options = source?.readJSONPublic("categoryComics.ranking.options")??.arrayValue?.compactMap { $0.stringValue } ?? []
        List {
            ForEach(options, id: \.self) { option in
                NavigationLink(value: RankingTarget(sourceKey: sourceKey, option: option)) {
                    Text(verbatim: option.contains("-") ? String(option.split(separator: "-", maxSplits: 1).last ?? "") : option)
                }
            }
            if options.isEmpty {
                Text("No options".tl)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 分类分区目标（partName == "__ranking__" 表示排行榜）。
struct CategoryPartTarget: Hashable {
    let sourceKey: String
    let partName: String
}

/// 分类漫画列表目标。
struct CategoryComicsTarget: Hashable {
    let sourceKey: String
    let category: String
    let param: String
    let options: [String]
}

struct RankingTarget: Hashable {
    let sourceKey: String
    let option: String
}

/// 探索目标（用于 NavigationStack 跳转至某源的分页列表）。
struct ExploreTarget: Hashable {
    let sourceKey: String
    let pageIndex: Int
    let title: String
}
