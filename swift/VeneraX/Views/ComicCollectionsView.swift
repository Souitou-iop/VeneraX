import SwiftUI
import VeneraKit

/// 漫画合集管理与浏览页（对齐原版 comic_collections_page.dart）。
struct ComicCollectionsView: View {
    @State private var collections: [ComicCollection] = []
    @State private var showEditSheet = false
    @State private var editingCollection: ComicCollection?
    @State private var pendingDeletion: ComicCollection?
    @State private var removeCollectionObserver: (() -> Void)?

    var body: some View {
        List {
            if collections.isEmpty {
                ContentUnavailableView {
                    Label("No collections yet".tl, systemImage: "square.stack.3d.down.right")
                } description: {
                    Text("Group the volumes of one story into a single comic".tl)
                }
            } else {
                ForEach(collections) { collection in
                    NavigationLink(value: ComicTarget.details(collection.toComic())) {
                        HStack(spacing: 12) {
                            ComicCover(url: collection.displayCover)
                                .frame(width: 48, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: collection.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                HStack(spacing: 8) {
                                    Text("\(collection.members.count) comics".tl)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(collection.displayMode == .flat ? "Merged chapters".tl : "Chapter tabs".tl)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDeletion = collection
                        } label: {
                            Label("Delete".tl, systemImage: "trash")
                        }

                        Button {
                            editingCollection = collection
                            showEditSheet = true
                        } label: {
                            Label("Edit".tl, systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onMove { from, to in
                    if let sourceIndex = from.first {
                        ComicCollectionStore.shared.reorder(oldIndex: sourceIndex, newIndex: to)
                        reload()
                    }
                }
            }
        }
        .navigationTitle("Collections".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingCollection = nil
                    showEditSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            ComicCollectionEditSheet(collection: editingCollection) {
                reload()
            }
        }
        .onAppear {
            reload()
            guard removeCollectionObserver == nil else { return }
            removeCollectionObserver = ComicCollectionStore.shared.onChange.add { _ in
                Task { @MainActor in reload() }
            }
        }
        .onDisappear {
            removeCollectionObserver?()
            removeCollectionObserver = nil
        }
        .alert("Delete collection?".tl, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { collection in
            Button("Delete".tl, role: .destructive) { deleteCollection(collection) }
            Button("Cancel".tl, role: .cancel) { pendingDeletion = nil }
        } message: { collection in
            Text("Delete collection '\(collection.displayName)'? The comics in it are kept.".tl)
        }
    }

    private func reload() {
        collections = ComicCollectionStore.shared.all()
    }

    private func deleteCollection(_ collection: ComicCollection) {
        ComicCollectionStore.shared.remove(id: collection.id)
        reload()
    }
}

/// 漫画合集编辑与创建弹窗。
struct ComicCollectionEditSheet: View {
    let collection: ComicCollection?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var displayMode: CollectionDisplayMode = .flat
    @State private var members: [CollectionMember] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection Info".tl) {
                    TextField("Collection name".tl, text: $name)
                    Picker("Chapter layout".tl, selection: $displayMode) {
                        Text("Merged chapters".tl).tag(CollectionDisplayMode.flat)
                        Text("Chapter tabs".tl).tag(CollectionDisplayMode.tabs)
                    }
                }

                if !members.isEmpty {
                    Section("Members".tl) {
                        ForEach($members) { $member in
                            HStack {
                                ComicCover(url: member.cachedCover)
                                    .frame(width: 36, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    // 「分部标签」布局下可为每个成员命名 tab
                                    // （对齐原版 feat: edit tab names when adding
                                    // to a collection）：留空则 label 回退到成员
                                    // 标题，标题刷新时标签跟着变。
                                    if displayMode == .tabs {
                                        TextField(
                                            "Tab name".tl,
                                            text: $member.displayName,
                                            prompt: Text("Leave empty to use the comic's title".tl)
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .font(.subheadline)
                                    } else {
                                        Text(verbatim: member.label)
                                            .font(.subheadline)
                                    }
                                    Text(verbatim: member.sourceKey)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            members.remove(atOffsets: indexSet)
                        }
                        .onMove { from, to in
                            members.move(fromOffsets: from, toOffset: to)
                        }
                    }
                }
            }
            .navigationTitle(collection == nil ? "New collection".tl : "Edit collection".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".tl) {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty && members.isEmpty)
                }
            }
            .onAppear {
                if let collection {
                    name = collection.name
                    displayMode = collection.displayMode
                    members = collection.members
                }
            }
        }
    }

    private func save() {
        if let collection {
            ComicCollectionStore.shared.update(
                id: collection.id,
                name: name,
                displayMode: displayMode,
                members: members
            )
        } else {
            ComicCollectionStore.shared.create(
                name: name,
                members: members,
                displayMode: displayMode
            )
        }
        onSave()
    }
}
