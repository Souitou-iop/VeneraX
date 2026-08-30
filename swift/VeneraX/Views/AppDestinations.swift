import SwiftUI
import VeneraKit

/// 每个 Tab 的 NavigationStack 共用的导航目的地注册与工具栏按钮。
struct AppDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: ComicTarget.self) { target in
                switch target {
                case .details(let comic):
                    ComicDetailsView(comic: comic)
                case .comments(let details):
                    CommentsView(details: details)
                case .search(let sourceKey, let keyword):
                    ComicListView(loader: .search(sourceKey: sourceKey, keyword: keyword, options: [:]))
                }
            }
            .navigationDestination(for: ReaderTarget.self) { target in
                if target.comic.sourceKey == "local" || ComicCollectionStore.isCollectionSourceKey(target.comic.sourceKey) {
                    ReaderView(comic: target.comic, source: nil, epIndex: target.epIndex, chapters: target.chapters)
                } else if let source = AppServices.shared.sources.first(where: { $0.key == target.comic.sourceKey }) {
                    ReaderView(comic: target.comic, source: source, epIndex: target.epIndex, chapters: target.chapters)
                }
            }
            .navigationDestination(for: CategoryComicsTarget.self) { target in
                ComicListView(loader: .category(
                    sourceKey: target.sourceKey,
                    category: target.category,
                    param: target.param,
                    options: target.options
                ))
            }
            .navigationDestination(for: RankingTarget.self) { target in
                ComicListView(loader: .ranking(sourceKey: target.sourceKey, option: target.option))
            }
            .navigationDestination(for: HomeTarget.self) { target in
                if target.history.type == ComicID.local {
                    ReaderView(
                        comic: Comic(
                            id: target.history.id,
                            title: target.history.title,
                            cover: target.history.cover,
                            subtitle: target.history.subtitle,
                            sourceKey: "local"
                        ),
                        source: nil,
                        epIndex: max(target.history.ep - 1, 0),
                        chapters: nil
                    )
                } else if let source = AppServices.shared.sources.first(where: {
                    ComicID(id: target.history.id, type: target.history.type).sourceKey == $0.key
                }) {
                    ReaderView(
                        comic: Comic(
                            id: target.history.id,
                            title: target.history.title,
                            cover: target.history.cover,
                            subtitle: target.history.subtitle,
                            sourceKey: source.key
                        ),
                        source: source,
                        epIndex: max(target.history.ep - 1, 0),
                        chapters: nil
                    )
                }
            }
            .navigationDestination(for: ExploreTarget.self) { target in
                ComicListView(loader: .explore(sourceKey: target.sourceKey, exploreIndex: target.pageIndex))
                    .navigationTitle(target.title)
            }
            .navigationDestination(for: SourceTarget.self) { target in
                if let source = AppServices.shared.sources.first(where: { $0.key == target.key }) {
                    SourceSettingsView(source: source)
                }
            }
    }
}

/// 工具栏：搜索 + 漫画源管理 + 设置（放在顶部导航栏）。
struct BrowseToolbar: ViewModifier {
    @State private var showSources = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "search") {
                        Image(systemName: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSources = true
                    } label: {
                        Image(systemName: "shippingbox")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "settings") {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: String.self) { value in
                if value == "search" {
                    SearchView()
                } else if value == "read-later" {
                    ReadLaterView()
                } else if value == "history" {
                    HistoryListView()
                } else if value == "reading-statistics" {
                    ReadingStatisticsView()
                } else if value == "follow-updates" {
                    FollowUpdatesView()
                } else if value == "collections" {
                    ComicCollectionsView()
                } else if value == "image-favorites" {
                    ImageFavoritesView()
                } else if value == "favorites-root" {
                    FavoritesView()
                } else if value == "local-comics" {
                    LocalComicsView()
                } else if value == "downloading" {
                    DownloadingView()
                } else if value == "tasks" {
                    TasksView()
                } else if value == "settings" {
                    SettingsHome()
                }
            }
            .sheet(isPresented: $showSources) {
                NavigationStack {
                    ComicSourcesView()
                }
            }
    }
}
