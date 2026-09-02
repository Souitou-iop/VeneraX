import SwiftUI
import VeneraKit

/// 首页：可自定义区块编排（继续阅读 / 稍后阅读 / 本地漫画 / 追更 / 合集 / 单图收藏 / 后台任务 / 抽卡 / 统计）。
struct HomeView: View {
    @State private var sections: [HomeSectionItem] = []
    @State private var recentHistory: [History] = []
    @State private var sources: [ComicSource] = []
    @State private var localComicsCount = 0
    @State private var readLaterCount = 0
    @State private var updatedCount = 0
    @State private var collectionsCount = 0
    @State private var imageFavCount = 0
    @State private var activeTasksCount = 0
    @State private var showRandomDrawSheet = false
    @State private var showLayoutEditor = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections.filter { $0.visible }) { section in
                    renderSection(section)
                }

                if !sources.isEmpty {
                    Section("Comic Sources".tl) {
                        ForEach(sources, id: \.key) { source in
                            LabeledContent(source.name, value: "v\(source.version)")
                        }
                    }
                }
            }
            .navigationTitle("VeneraX")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLayoutEditor = true
                    } label: {
                        Image(systemName: "square.grid.3x3.topleft.filled")
                    }
                }
            }
            .modifier(BrowseToolbar())
            .modifier(AppDestinations())
            .sheet(isPresented: $showRandomDrawSheet) {
                RandomComicDrawView()
            }
            .sheet(isPresented: $showLayoutEditor) {
                HomeLayoutEditorSheet()
                    .onDisappear { Task { await reload() } }
            }
            .task { await reload() }
        }
    }

    @ViewBuilder
    private func renderSection(_ section: HomeSectionItem) -> some View {
        switch section.id {
        case "history":
            if !recentHistory.isEmpty {
                Section("Continue Reading".tl) {
                    historyRow
                }
            }
        case "readLater":
            Section {
                NavigationLink(value: "read-later") {
                    Label("Read Later".tl, systemImage: "clock")
                        .badge(readLaterCount)
                }
            }
        case "local":
            Section {
                NavigationLink(value: "local-comics") {
                    Label("Local Comics".tl, systemImage: "folder.fill")
                        .badge(localComicsCount)
                }
            }
        case "followUpdates":
            Section {
                NavigationLink(value: "follow-updates") {
                    Label("Follow Updates".tl, systemImage: "bell.badge.fill")
                        .badge(updatedCount)
                }
            }
        case "collections":
            Section {
                NavigationLink(value: "collections") {
                    Label("Collections".tl, systemImage: "square.stack.3d.down.right")
                        .badge(collectionsCount)
                }
            }
        case "imageFavorites":
            Section {
                NavigationLink(value: "image-favorites") {
                    Label("Image Favorites".tl, systemImage: "photo.on.rectangle.angled")
                        .badge(imageFavCount)
                }
            }
        case "tasks":
            Section {
                NavigationLink(value: "tasks") {
                    Label("Task Center".tl, systemImage: "checklist")
                        .badge(activeTasksCount)
                }
            }
        case "randomDraw":
            Section {
                Button {
                    showRandomDrawSheet = true
                } label: {
                    Label("Random Draw".tl, systemImage: "dice.fill")
                        .foregroundStyle(.primary)
                }
            }
        case "statistics":
            Section {
                NavigationLink(value: "reading-statistics") {
                    Label("Reading Statistics".tl, systemImage: "chart.bar.xaxis")
                }
            }
        default:
            EmptyView()
        }
    }

    private var historyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(Array(recentHistory.prefix(12).enumerated()), id: \.offset) { _, item in
                    NavigationLink(value: HomeTarget(history: item)) {
                        HistoryCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func reload() async {
        let snapshot = await Task.detached(priority: .utility) {
            HomeSnapshot(
                sections: HomeLayoutStore.loadSections(),
                recentHistory: HistoryManager.shared.getRecent(20),
                localComicsCount: LocalManager.shared.count,
                readLaterCount: ReadLaterManager.shared.getAll().count,
                updatedCount: FollowUpdatesManager.shared.totalUpdatedCount,
                collectionsCount: ComicCollectionStore.shared.all().count,
                imageFavCount: ImageFavoriteManager.shared.count,
                activeTasksCount: SourceMigrationManager.shared.activeTasks().count
            )
        }.value

        guard !Task.isCancelled else { return }
        sections = snapshot.sections
        recentHistory = snapshot.recentHistory
        sources = AppServices.shared.sources
        localComicsCount = snapshot.localComicsCount
        readLaterCount = snapshot.readLaterCount
        updatedCount = snapshot.updatedCount
        collectionsCount = snapshot.collectionsCount
        imageFavCount = snapshot.imageFavCount
        activeTasksCount = snapshot.activeTasksCount
    }

    private struct HomeSnapshot: Sendable {
        let sections: [HomeSectionItem]
        let recentHistory: [History]
        let localComicsCount: Int
        let readLaterCount: Int
        let updatedCount: Int
        let collectionsCount: Int
        let imageFavCount: Int
        let activeTasksCount: Int
    }
}

/// 首页内部导航目标。
struct HomeTarget: Hashable {
    let history: History
}

/// 继续阅读卡片。
struct HistoryCard: View {
    let item: History

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ComicCover(url: item.cover)
                .frame(width: 96, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(verbatim: item.title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(verbatim: progressText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 96)
    }

    private var progressText: String {
        "EP\(item.ep) · P\(item.page)"
    }
}
