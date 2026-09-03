import SwiftUI
import VeneraKit

/// 收藏与加入合集操作面板（对齐原版 favorite.dart + add_to_collection.dart）。
struct FavoriteActionSheet: View {
    let comic: Comic
    var onFinished: (() -> Void)?

    @State private var folders: [String] = []
    @State private var newFolderName = ""
    @State private var networkFolders: [(id: String, title: String)] = []
    @State private var collections: [ComicCollection] = []
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    private var source: ComicSource? {
        ComicSourceManager.shared.find(comic.sourceKey)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Local Folders".tl) {
                    ForEach(folders, id: \.self) { folder in
                        Button {
                            addTo(folder: folder)
                        } label: {
                            Label(folder, systemImage: "folder")
                                .foregroundStyle(.primary)
                        }
                    }
                    HStack {
                        TextField("New Folder".tl, text: $newFolderName)
                        Button("Create".tl) {
                            let name = newFolderName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            LocalFavoritesManager.shared.addFolder(name)
                            folders = LocalFavoritesManager.shared.getFoldersSorted()
                            addTo(folder: name)
                            newFolderName = ""
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if !collections.isEmpty && !ComicCollectionStore.isCollectionSourceKey(comic.sourceKey) {
                    Section("Add to Collection".tl) {
                        ForEach(collections) { collection in
                            Button {
                                addTo(collection: collection)
                            } label: {
                                HStack {
                                    Label(collection.displayName, systemImage: "square.stack.3d.down.right")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if collection.contains(sourceKey: comic.sourceKey, comicId: comic.id) {
                                        Text("Already in collection".tl)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if let source, source.favoriteDataAvailable, source.multiFolder {
                    Section("Network Folders".tl) {
                        ForEach(networkFolders, id: \.id) { folder in
                            Button {
                                Task { await addNetwork(folderId: folder.id) }
                            } label: {
                                Label(folder.title, systemImage: "cloud")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                if let message {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add to Favorites".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done".tl) { dismiss() }
                }
            }
            .onAppear {
                folders = LocalFavoritesManager.shared.getFoldersSorted()
                collections = ComicCollectionStore.shared.all()
                Task { await loadNetworkFolders() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addTo(folder: String) {
        let item = FavoriteItem(
            id: comic.id,
            name: comic.title,
            coverPath: comic.cover,
            author: comic.subtitle,
            type: ComicID.forSource(comic.sourceKey),
            tags: comic.tags,
            authors: comic.subtitle.isEmpty ? [] : [comic.subtitle]
        )
        LocalFavoritesManager.shared.addFavorite(folder, item)
        message = "Added to \(folder)".tl
        onFinished?()
    }

    private func addTo(collection: ComicCollection) {
        let member = CollectionMember(
            sourceKey: comic.sourceKey,
            comicId: comic.id,
            // 未显式命名时不存储标签名（对齐原版 feat: edit tab names when
            // adding to a collection）：留空让 label 回退到 cachedTitle，之后
            // 详情加载刷新标题时标签跟着变；存标题则永远冻结在加入那一刻。
            displayName: "",
            cachedTitle: comic.title,
            cachedSubtitle: comic.subtitle,
            cachedCover: comic.cover
        )
        _ = ComicCollectionStore.shared.addMembers(id: collection.id, incoming: [member])
        message = "Added to \(collection.displayName)".tl
        collections = ComicCollectionStore.shared.all()
        onFinished?()
    }

    private func addNetwork(folderId: String) async {
        guard let source else { return }
        do {
            try await source.addOrDelFavorite(comicId: comic.id, folderId: folderId, isAdding: true)
            message = "Added to network favorites".tl
            onFinished?()
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadNetworkFolders() async {
        guard let source, source.favoriteDataAvailable, source.multiFolder else { return }
        networkFolders = (try? await source.loadFavoriteFolders()) ?? []
    }
}
