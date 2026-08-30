import SwiftUI
import VeneraKit

/// 单图收藏画册视图（对齐原版 image_favorites_page.dart）。
/// 支持多选批量删除、全屏预览、离线文件分享，以及跨页面数据变化自动刷新。
struct ImageFavoritesView: View {
    @State private var items: [SingleImageFavorite] = []
    @State private var selectedItem: SingleImageFavorite?
    @State private var selectedIDs: Set<String> = []
    @State private var isSelecting = false
    @State private var showDeleteConfirmation = false
    @State private var removeChangeObserver: (() -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No favorite images".tl, systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Long-press or tap favorite in the reader to save comic pages".tl)
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        imageTile(item)
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle(isSelecting ? "\(selectedIDs.count)" : "Image Favorites".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { exitSelection() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Select All".tl) { selectedIDs = Set(items.map(\.id)) }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSelecting = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Multi-Select".tl)
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            ImageFavoriteDetailView(item: item) { delete(item) }
        }
        .confirmationDialog(
            "Delete selected images?".tl,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete".tl, role: .destructive) { deleteSelected() }
            Button("Cancel".tl, role: .cancel) {}
        }
        .onAppear {
            reload()
            guard removeChangeObserver == nil else { return }
            removeChangeObserver = ImageFavoriteManager.shared.onChange.add { _ in
                Task { @MainActor in reload() }
            }
        }
        .onDisappear {
            removeChangeObserver?()
            removeChangeObserver = nil
        }
    }

    @ViewBuilder
    private func imageTile(_ item: SingleImageFavorite) -> some View {
        Button {
            if isSelecting {
                toggleSelection(item)
            } else {
                selectedItem = item
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                    if let local = item.localFilePath, FileManager.default.fileExists(atPath: local) {
                        ComicCover(url: "file://\(local)")
                    } else {
                        ComicCover(url: item.imageKey)
                    }
                    LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .bottom, endPoint: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.title).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Text("P\(item.pageIndex + 1)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.8))
                    }.padding(6)
                }
                .aspectRatio(3 / 4, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if isSelecting {
                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selectedIDs.contains(item.id) ? Color.accentColor : Color.black.opacity(0.55))
                        .padding(7)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { selectedItem = item } label: { Label("Open".tl, systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { toggleSelection(item); isSelecting = true } label: { Label("Select".tl, systemImage: "checkmark.circle") }
            Button(role: .destructive) { delete(item) } label: { Label("Delete".tl, systemImage: "trash") }
        }
        .accessibilityLabel("\(item.title), P\(item.pageIndex + 1)".tl)
        .accessibilityAddTraits(isSelecting && selectedIDs.contains(item.id) ? .isSelected : [])
    }

    private func reload() {
        let latest = ImageFavoriteManager.shared.getAll()
        items = latest
        selectedIDs = selectedIDs.intersection(Set(latest.map(\.id)))
        if selectedIDs.isEmpty && isSelecting { isSelecting = false }
    }

    private func toggleSelection(_ item: SingleImageFavorite) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        isSelecting = false
    }

    private func deleteSelected() {
        let selected = items.filter { selectedIDs.contains($0.id) }
        ImageFavoriteManager.shared.removeFavorites(selected)
        exitSelection()
        reload()
    }

    private func delete(_ item: SingleImageFavorite) {
        ImageFavoriteManager.shared.removeFavorite(comicId: item.comicId, sourceKey: item.sourceKey, epIndex: item.epIndex, pageIndex: item.pageIndex)
        selectedIDs.remove(item.id)
        reload()
    }
}

/// 单图详情全屏预览视图。
struct ImageFavoriteDetailView: View {
    let item: SingleImageFavorite
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let local = item.localFilePath, FileManager.default.fileExists(atPath: local) {
                    ComicCover(url: "file://\(local)")
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ComicCover(url: item.imageKey)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close".tl) { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let local = item.localFilePath {
                            shareURL = URL(fileURLWithPath: local)
                            showShare = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
        }
    }
}
