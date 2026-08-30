import SwiftUI
import VeneraKit

/// 追更列表页面（对齐原版 follow_updates_page.dart）。
/// 集中展示所有收藏夹中有更新的漫画，支持手动触发全量追更检查与标记已读。
struct FollowUpdatesView: View {
    @State private var updatedComics: [(folder: String, item: FavoriteItem)] = []
    @State private var isChecking = false
    @State private var progressText = ""
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Follow Updates".tl)
                            .font(.headline)
                        Text(isChecking ? progressText : "\(updatedComics.count) updated comics".tl)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isChecking {
                        ProgressView()
                    } else {
                        Button {
                            checkUpdates()
                        } label: {
                            Label("Check Now".tl, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            if updatedComics.isEmpty && !isChecking {
                ContentUnavailableView {
                    Label("No updates".tl, systemImage: "bell.slash")
                } description: {
                    Text("Comics with new chapters will appear here".tl)
                }
            } else {
                Section("Updated Comics".tl) {
                    ForEach(updatedComics, id: \.item.id) { pair in
                        NavigationLink(value: ComicTarget.details(FavoriteItemBridge.comic(from: pair.item))) {
                            HStack(spacing: 12) {
                                ComicCover(url: pair.item.coverPath)
                                    .frame(width: 48, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(verbatim: pair.item.name)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("NEW".tl)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.red, in: Capsule())
                                    }

                                    if !pair.item.author.isEmpty {
                                        Text(verbatim: pair.item.author)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    HStack {
                                        Text(verbatim: pair.folder)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())

                                        if let lastUpdate = pair.item.lastUpdateTime, !lastUpdate.isEmpty {
                                            Text(verbatim: lastUpdate)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                FollowUpdatesManager.shared.markComicRead(
                                    id: pair.item.id,
                                    type: pair.item.type,
                                    folder: pair.folder
                                )
                                reload()
                            } label: {
                                Label("Mark Read".tl, systemImage: "checkmark.circle")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Updates".tl)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
        }
    }

    private func reload() {
        updatedComics = FollowUpdatesManager.shared.getAllUpdatedComics()
    }

    private func checkUpdates() {
        guard checkTask == nil else { return }
        checkTask = Task { @MainActor in
            isChecking = true
            progressText = "Checking updates...".tl
            defer {
                isChecking = false
                checkTask = nil
            }
            await FollowUpdatesManager.shared.checkAllFolders()
            guard !Task.isCancelled else { return }
            reload()
        }
    }
}
