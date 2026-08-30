import SwiftUI
import VeneraKit

/// 收藏页：本地漫画库、追更监控、本地收藏文件夹与网络收藏四个分区。
/// 支持网络收藏多文件夹切换、分页加载与滑动快捷管理。
struct FavoritesView: View {
    @State private var localComicsCount = 0
    @State private var activeDownloadCount = 0
    @State private var updatedCount = 0
    @State private var folders: [String] = []
    @State private var networkComics: [Comic] = []
    @State private var networkSourceKey: String?
    @State private var networkFolders: [(id: String, title: String)] = []
    @State private var selectedFolderId: String?
    @State private var networkPage = 1
    @State private var networkMaxPage: Int?
    @State private var isLoadingNetwork = false
    @State private var isLoadingMoreNetwork = false

    private var networkSources: [ComicSource] {
        AppServices.shared.sources.filter { $0.favoriteDataAvailable }
    }

    private var currentNetworkSource: ComicSource? {
        guard let key = networkSourceKey else { return nil }
        return ComicSourceManager.shared.find(key)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Library".tl) {
                    NavigationLink(value: "local-comics") {
                        Label {
                            LabeledContent("Local Comics".tl, value: "\(localComicsCount)")
                        } icon: {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                        }
                    }

                    NavigationLink(value: "follow-updates") {
                        Label {
                            HStack {
                                Text("Follow Updates".tl)
                                Spacer()
                                if updatedCount > 0 {
                                    Text("\(updatedCount)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.red, in: Capsule())
                                }
                            }
                        } icon: {
                            Image(systemName: "bell.badge.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if !folders.isEmpty {
                    Section("Favorites".tl) {
                        ForEach(folders, id: \.self) { folder in
                            NavigationLink(value: LocalFolderTarget(folder: folder)) {
                                LabeledContent(folder, value: "\(LocalFavoritesManager.shared.count(folder))")
                            }
                        }
                    }
                }

                if !networkSources.isEmpty {
                    Section("Network".tl) {
                        Picker("Source".tl, selection: $networkSourceKey) {
                            ForEach(networkSources, id: \.key) { source in
                                Text(verbatim: source.name).tag(Optional(source.key))
                            }
                        }

                        if let source = currentNetworkSource, source.multiFolder, !networkFolders.isEmpty {
                            Picker("Folder".tl, selection: $selectedFolderId) {
                                Text("Default".tl).tag(Optional<String>(nil))
                                ForEach(networkFolders, id: \.id) { f in
                                    Text(verbatim: f.title).tag(Optional(f.id))
                                }
                            }
                        }

                        if isLoadingNetwork {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if networkComics.isEmpty {
                            Text("No favorites found".tl)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(networkComics, id: \.id) { comic in
                                NavigationLink(value: ComicTarget.details(comic)) {
                                    HStack(spacing: 12) {
                                        ComicCover(url: comic.cover)
                                            .frame(width: 44, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(verbatim: comic.title)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            if !comic.subtitle.isEmpty {
                                                Text(verbatim: comic.subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                            }

                            if hasMoreNetworkPages {
                                Button {
                                    Task { await loadMoreNetwork() }
                                } label: {
                                    HStack {
                                        Spacer()
                                        if isLoadingMoreNetwork {
                                            ProgressView()
                                        } else {
                                            Text("Load More".tl)
                                                .font(.caption)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favorites".tl)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "downloading") {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.down.circle")
                            if activeDownloadCount > 0 {
                                Text("\(activeDownloadCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(.red, in: Circle())
                                    .offset(x: 8, y: -6)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "read-later") {
                        Image(systemName: "clock")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "history") {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
            .navigationDestination(for: String.self) { value in
                if value == "local-comics" {
                    LocalComicsView()
                } else if value == "follow-updates" {
                    FollowUpdatesView()
                } else if value == "downloading" {
                    DownloadingView()
                } else if value == "read-later" {
                    ReadLaterView()
                } else if value == "history" {
                    HistoryListView()
                } else if value == "reading-statistics" {
                    ReadingStatisticsView()
                }
            }
            .modifier(AppDestinations())
            .navigationDestination(for: LocalFolderTarget.self) { target in
                LocalFolderView(folder: target.folder)
            }
            .onAppear(perform: reload)
            .onChange(of: networkSourceKey) { _, _ in
                selectedFolderId = nil
                Task {
                    await fetchNetworkFolders()
                    await loadNetwork()
                }
            }
            .onChange(of: selectedFolderId) { _, _ in
                Task { await loadNetwork() }
            }
            .refreshable {
                reload()
                await fetchNetworkFolders()
                await loadNetwork()
            }
        }
    }

    private var hasMoreNetworkPages: Bool {
        if let maxPage = networkMaxPage {
            return networkPage < maxPage
        }
        return !networkComics.isEmpty
    }

    private func reload() {
        localComicsCount = LocalManager.shared.count
        activeDownloadCount = DownloadManager.shared.downloadingTasks.filter { !$0.isPaused && !$0.isError }.count
        updatedCount = FollowUpdatesManager.shared.totalUpdatedCount
        folders = LocalFavoritesManager.shared.getFoldersSorted()
        if networkSourceKey == nil {
            networkSourceKey = networkSources.first?.key
            Task {
                await fetchNetworkFolders()
                await loadNetwork()
            }
        }
    }

    private func fetchNetworkFolders() async {
        guard let source = currentNetworkSource, source.multiFolder else {
            networkFolders = []
            return
        }
        networkFolders = (try? await source.loadFavoriteFolders()) ?? []
    }

    private func loadNetwork() async {
        guard let source = currentNetworkSource else { return }
        isLoadingNetwork = true
        defer { isLoadingNetwork = false }
        networkPage = 1
        let result = try? await source.loadFavoriteComics(folderId: selectedFolderId, page: 1)
        networkComics = result?.comics ?? []
        networkMaxPage = result?.maxPage
    }

    private func loadMoreNetwork() async {
        guard let source = currentNetworkSource, !isLoadingMoreNetwork else { return }
        isLoadingMoreNetwork = true
        defer { isLoadingMoreNetwork = false }
        let nextPage = networkPage + 1
        if let result = try? await source.loadFavoriteComics(folderId: selectedFolderId, page: nextPage) {
            networkComics.append(contentsOf: result.comics)
            networkPage = nextPage
            networkMaxPage = result.maxPage
        }
    }
}

struct LocalFolderTarget: Hashable {
    let folder: String
}

/// 本地收藏夹内容页：滑动删除。
struct LocalFolderView: View {
    let folder: String

    @State private var comics: [FavoriteItem] = []

    var body: some View {
        List {
            ForEach(Array(comics.enumerated()), id: \.offset) { index, item in
                NavigationLink(value: ComicTarget.details(FavoriteItemBridge.comic(from: item))) {
                    HStack(spacing: 12) {
                        ComicCover(url: item.coverPath)
                            .frame(width: 44, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.name)
                                .font(.subheadline)
                            Text(verbatim: item.time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        LocalFavoritesManager.shared.removeFavorite(id: item.id, type: item.type, folder: folder)
                        comics.remove(at: index)
                    } label: {
                        Label("Delete".tl, systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(folder)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            comics = LocalFavoritesManager.shared.getComics(folder)
        }
    }
}

/// FavoriteItem / ReadLaterItem → Comic 转换。
enum FavoriteItemBridge {
    static func comic(from item: FavoriteItem) -> Comic {
        let sourceKey = ComicID(id: item.id, type: item.type).sourceKey ?? "local"
        return Comic(
            id: item.id,
            title: item.name,
            cover: item.coverPath,
            subtitle: item.author,
            tags: item.tags,
            description: "",
            sourceKey: sourceKey
        )
    }

    static func comic(from item: ReadLaterItem) -> Comic {
        let sourceKey = ComicID(id: item.id, type: item.type).sourceKey ?? "local"
        return Comic(
            id: item.id,
            title: item.title,
            cover: item.cover,
            subtitle: item.subtitle,
            tags: item.tags,
            description: "",
            sourceKey: sourceKey
        )
    }
}

/// 稍后读页。
struct ReadLaterView: View {
    @State private var items: [ReadLaterItem] = []

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                NavigationLink(value: ComicTarget.details(FavoriteItemBridge.comic(from: item))) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title)
                            .font(.subheadline)
                        if !item.subtitle.isEmpty {
                            Text(verbatim: item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        ReadLaterManager.shared.remove(id: item.id, type: item.type)
                        items.remove(at: index)
                    } label: {
                        Label("Delete".tl, systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Read Later".tl)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            items = ReadLaterManager.shared.getAll()
        }
    }
}

/// 历史页。
struct HistoryListView: View {
    @State private var items: [History] = []

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title)
                        .font(.subheadline)
                    HStack {
                        if !item.subtitle.isEmpty {
                            Text(verbatim: item.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: "EP\(item.ep) · P\(item.page)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        HistoryManager.shared.removeFromHistory(id: item.id, type: item.type)
                        items.remove(at: index)
                    } label: {
                        Label("Hide".tl, systemImage: "eye.slash")
                    }
                }
            }
        }
        .navigationTitle("History".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: "reading-statistics") {
                    Image(systemName: "chart.bar.xaxis")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear".tl) {
                    HistoryManager.shared.clearHistory()
                    items = HistoryManager.shared.getRecent(200)
                }
            }
        }
        .onAppear {
            items = HistoryManager.shared.getRecent(200)
        }
    }
}
