import SwiftUI
import UniformTypeIdentifiers
import VeneraKit

/// 本地漫画管理页（对齐原版 local_comics_page.dart）。
/// 支持 4 档状态过滤、搜索、排序、CBZ/ZIP/.venera_comics/目录导入、
/// CBZ/.venera_comics 导出与多选批量删除。
struct LocalComicsView: View {
    @State private var comics: [LocalComic] = []
    @State private var selectedStatus: LocalComicStatus? = nil
    @State private var sortType: LocalSortType = .defaultSort
    @State private var searchKeyword: String = ""
    @State private var showArchiveImporter = false
    @State private var showFolderImporter = false
    @State private var exportShareURL: URL?
    @State private var showShareSheet = false
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var activeDownloadCount = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Status".tl, selection: $selectedStatus) {
                Text("All".tl).tag(Optional<LocalComicStatus>.none)
                Text("Downloaded".tl).tag(Optional<LocalComicStatus>.some(.downloaded))
                Text("Downloading".tl).tag(Optional<LocalComicStatus>.some(.downloading))
                Text("Not Downloaded".tl).tag(Optional<LocalComicStatus>.some(.notDownloaded))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if isImporting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Importing comics...".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if filteredComics.isEmpty {
                ContentUnavailableView {
                    Label("No local comics".tl, systemImage: "books.vertical")
                } description: {
                    Text("Tap + to import CBZ, ZIP, or folders".tl)
                }
            } else {
                List {
                    ForEach(filteredComics) { comic in
                        LocalComicRow(comic: comic)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteComic(comic)
                                } label: {
                                    Label("Delete".tl, systemImage: "trash")
                                }

                                Button {
                                    exportComic(comic)
                                } label: {
                                    Label("Export CBZ".tl, systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)

                                Button {
                                    exportVeneraComics(comic)
                                } label: {
                                    Label("Export .venera_comics".tl, systemImage: "archivebox")
                                }
                                .tint(.purple)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Local Comics".tl)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchKeyword, prompt: "Search local comics".tl)
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
                Menu {
                    Picker("Sort".tl, selection: $sortType) {
                        Text("Default".tl).tag(LocalSortType.defaultSort)
                        Text("Name Asc".tl).tag(LocalSortType.name)
                        Text("Name Desc".tl).tag(LocalSortType.nameDesc)
                        Text("Newest First".tl).tag(LocalSortType.timeDesc)
                        Text("Oldest First".tl).tag(LocalSortType.timeAsc)
                        Text("Author".tl).tag(LocalSortType.author)
                        Text("Last Read".tl).tag(LocalSortType.lastRead)
                    }

                    Divider()

                    Button {
                        showArchiveImporter = true
                    } label: {
                        Label("Import Archive (CBZ/ZIP/.venera_comics)".tl, systemImage: "doc.zipper")
                    }

                    Button {
                        showFolderImporter = true
                    } label: {
                        Label("Import Folder".tl, systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(
            isPresented: $showArchiveImporter,
            allowedContentTypes: [.zip, UTType(filenameExtension: "cbz") ?? .zip, UTType(filenameExtension: "venera_comics") ?? .data, UTType(filenameExtension: "7z") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            handleArchiveImport(result)
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderImport(result)
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportShareURL {
                ShareSheet(items: [exportShareURL])
            }
        }
        .onAppear(perform: reload)
        .onChange(of: sortType) { _, _ in reload() }
    }

    private var filteredComics: [LocalComic] {
        var result = comics
        if let status = selectedStatus {
            result = result.filter { $0.status == status }
        }
        if !searchKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
            let kw = searchKeyword.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(kw) ||
                $0.subtitle.lowercased().contains(kw) ||
                $0.tags.contains { $0.lowercased().contains(kw) }
            }
        }
        return result
    }

    private func reload() {
        comics = LocalManager.shared.getComics(sortType)
        activeDownloadCount = DownloadManager.shared.downloadingTasks.filter { !$0.isPaused && !$0.isError }.count
    }

    private func deleteComic(_ comic: LocalComic) {
        LocalManager.shared.batchDeleteComics([comic], removeFiles: true, removeFavoriteAndHistory: true)
        reload()
    }

    private func exportComic(_ comic: LocalComic) {
        Task {
            let safeTitle = LocalManager.sanitizeFileName(comic.title)
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(safeTitle).cbz")
            do {
                try LocalComicImporter.exportToCBZ(comic: comic, destinationURL: tempURL)
                await MainActor.run {
                    self.exportShareURL = tempURL
                    self.showShareSheet = true
                }
            } catch {
                Log.error("Export", "Failed to export CBZ: \(error)")
            }
        }
    }

    private func exportVeneraComics(_ comic: LocalComic) {
        Task {
            let safeTitle = LocalManager.sanitizeFileName(comic.title)
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(safeTitle).venera_comics")
            do {
                _ = try LocalComicImporter.exportVeneraComics(
                    comics: [comic],
                    destinationURL: tempURL
                )
                await MainActor.run {
                    self.exportShareURL = tempURL
                    self.showShareSheet = true
                }
            } catch {
                Log.error("Export", "Failed to export .venera_comics: \(error)")
            }
        }
    }

    private func handleArchiveImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isImporting = true
        Task {
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if url.pathExtension.lowercased() == "venera_comics" {
                    _ = try? LocalComicImporter.importVeneraComics(url)
                } else {
                    _ = try? LocalComicImporter.importArchive(url)
                }
            }
            await MainActor.run {
                isImporting = false
                reload()
            }
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        Task {
            guard url.startAccessingSecurityScopedResource() else {
                await MainActor.run { isImporting = false }
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            _ = try? LocalComicImporter.scanAndImportDirectory(url)
            await MainActor.run {
                isImporting = false
                reload()
            }
        }
    }
}

/// 本地漫画行视图。
struct LocalComicRow: View {
    let comic: LocalComic

    var body: some View {
        NavigationLink(value: comicTarget) {
            HStack(alignment: .top, spacing: 12) {
                ComicCover(url: comic.coverURL)
                    .frame(width: 60, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: comic.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)

                    if !comic.subtitle.isEmpty {
                        Text(verbatim: comic.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if comic.hasChapters {
                            Text("\(comic.downloadedChapters.count) ch".tl)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        statusBadge
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var comicTarget: ComicTarget {
        .details(comic.toComic())
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch comic.status {
        case .downloaded:
            Text("Downloaded".tl)
                .font(.caption2)
                .foregroundStyle(.green)
        case .downloading:
            Text("Downloading".tl)
                .font(.caption2)
                .foregroundStyle(.orange)
        case .notDownloaded:
            Text("Not Downloaded".tl)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// 导出分享 Sheet。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
