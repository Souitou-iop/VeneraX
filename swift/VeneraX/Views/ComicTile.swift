import SwiftUI
import VeneraKit

/// 漫画卡片组件（ComicTile）
/// 严格对标现代化 iOS 漫画与相册应用规范：
/// 1. 封面图固定 0.70 竖版黄金比例，防变形/防拉伸/防贴边溢出；
/// 2. 标题固定预留 2 行高度（reservesSpace: true），作者/副标题固定预留 1 行，标签固定预留 1 行；
/// 3. 每行中的所有漫画卡片无论文本长短，均保持完全严格一致的高度与基准线对齐；
/// 4. 具备平滑触控缩放反馈与细腻圆角/微阴影/边框质感。
struct ComicTile: View {
    let comic: Comic

    var body: some View {
        NavigationLink(value: ComicTarget.details(comic)) {
            VStack(alignment: .leading, spacing: 5) {
                ComicCover(url: comic.cover, sourceKey: comic.sourceKey, comicID: comic.id)

                // 标题槽位：固定 2 行高度，对齐顶部，避免因 1 行 / 2 行差异导致卡片高度参差不齐
                Text(verbatim: comic.title.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(2)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                // 作者 / 副标题槽位：固定 1 行高度
                let cleanSubtitle = comic.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(verbatim: !cleanSubtitle.isEmpty ? cleanSubtitle : " ")
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1, reservesSpace: true)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 标签槽位：固定 1 行高度
                let tagString = comic.tags.prefix(3).map { $0.translatedTag() }.joined(separator: " ")
                Text(verbatim: !tagString.isEmpty ? tagString : " ")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1, reservesSpace: true)
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ComicTileButtonStyle())
    }
}

/// 漫画卡片点击微交互动画。
struct ComicTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 封面图（固定比例、防裁切溢出、骨架占位与平滑加载过渡）。
struct ComicCover: View {
    let url: String
    var sourceKey: String? = nil
    var comicID: String? = nil
    var aspectRatio: CGFloat = 0.70
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    /// Include source and comic identity: the same URL can require different
    /// signed headers or represent a different cover after a source switch.
    private var loadIdentity: String {
        "\(sourceKey ?? "")|\(comicID ?? "")|\(url)"
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "book.closed")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1.5)
            .task(id: loadIdentity) {
                image = nil
                if let loaded = await CoverLoader.shared.load(url, sourceKey: sourceKey, comicID: comicID) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        image = loaded
                    }
                }
            }
    }
}

/// 封面加载器：CacheManager 磁盘缓存 + URLSession 拉取。
actor CoverLoader {
    static let shared = CoverLoader()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.countLimit = 160
        memory.totalCostLimit = 48 * 1024 * 1024
    }

    func load(_ urlString: String, sourceKey: String? = nil, comicID: String? = nil) async -> UIImage? {
        let cacheKey = "cover@\(urlString)@\(sourceKey ?? "")@\(comicID ?? "")"
        if let cached = memory.object(forKey: cacheKey as NSString) { return cached }
        if let existing = inFlight[cacheKey] { return await existing.value }

        let task: Task<UIImage?, Never> = Task { [weak self] in
            guard let self else { return Optional<UIImage>.none }
            return await self.fetch(urlString, sourceKey: sourceKey, comicID: comicID, cacheKey: cacheKey)
        }
        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        return result
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            UIImage(data: data)
        }.value
    }

    private func fetch(_ urlString: String, sourceKey: String?, comicID: String?, cacheKey: String) async -> UIImage? {
        if urlString.hasPrefix("file://") {
            let path = String(urlString.dropFirst("file://".count))
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            }.value
            guard let data, let image = await Self.decode(data) else { return nil }
            memory.setObject(image, forKey: cacheKey as NSString, cost: data.count)
            return image
        }

        // Use the same source-aware pipeline as reader pages. This preserves
        // onImageLoad url/method/data/headers/onResponse behavior for covers.
        if let sourceKey, let comicID, let source = ComicSourceManager.shared.find(sourceKey) {
            guard !Task.isCancelled,
                  let data = await ImageDownloader.shared.load(
                    imageKey: urlString,
                    sourceKey: sourceKey,
                    cid: comicID,
                    eid: "",
                    source: source
                  ),
                  let image = await Self.decode(data), !Task.isCancelled else { return nil }
            memory.setObject(image, forKey: cacheKey as NSString, cost: data.count)
            return image
        }

        guard URL(string: urlString) != nil else { return nil }
        if let data = CacheManager.shared.getData(cacheKey), let image = await Self.decode(data) {
            memory.setObject(image, forKey: cacheKey as NSString, cost: data.count)
            return image
        }

        guard !Task.isCancelled else { return nil }
        let response = await HTTPClient.shared.request(
            method: "GET", url: urlString, headers: ["User-Agent": HTTPClient.webUA], body: nil,
            ignoreBadCertificate: AppData.shared.settings["ignoreBadCertificate"].boolValue ?? false
        )
        guard let status = response.status, (200..<300).contains(status), !response.body.isEmpty,
              let image = await Self.decode(response.body), !Task.isCancelled else { return nil }
        CacheManager.shared.set(cacheKey, response.body)
        memory.setObject(image, forKey: cacheKey as NSString, cost: response.body.count)
        return image
    }
}

/// 漫画列表目标（用于 NavigationStack 值导航）。
enum ComicTarget: Hashable {
    case details(Comic)
    case comments(ComicDetails)
    case search(String, String) // sourceKey, keyword
}

/// 通用分页漫画列表：探索页 / 搜索结果 / 分类列表共用。
/// 具备标准的外边距（16pt）、列间距（12pt）、行间距（18pt）与严格的行对齐。
struct ComicListView: View {
    enum PageLoader {
        /// 探索页：sourceKey + exploreIndex。
        case explore(sourceKey: String, exploreIndex: Int)
        /// 搜索。
        case search(sourceKey: String, keyword: String, options: [String: String])
        /// 分类漫画。
        case category(sourceKey: String, category: String, param: String, options: [String])
        /// 排行榜。
        case ranking(sourceKey: String, option: String)
    }

    let loader: PageLoader

    @State private var comics: [Comic] = []
    @State private var currentPage = 1
    @State private var maxPage: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var reachedEnd = false

    private var source: ComicSource? {
        ComicSourceManager.shared.find(sourceKey)
    }

    private var sourceKey: String {
        switch loader {
        case .explore(let key, _): return key
        case .search(let key, _, _): return key
        case .category(let key, _, _, _): return key
        case .ranking(let key, _): return key
        }
    }

    var body: some View {
        Group {
            if let error, comics.isEmpty {
                ContentUnavailableView {
                    Label("Network Error".tl, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Retry".tl) {
                        Task { await loadNextPage() }
                    }
                }
            } else if comics.isEmpty && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 18) {
                        ForEach(Array(comics.enumerated()), id: \.offset) { _, comic in
                            ComicTile(comic: comic)
                                .onAppear {
                                    if comic.id == comics.last?.id {
                                        Task { await loadNextPage() }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 96)

                    if isLoading && !comics.isEmpty {
                        ProgressView()
                            .padding(.vertical, 16)
                    }
                    if reachedEnd && !comics.isEmpty {
                        Text("No More".tl)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 24)
                    }
                }
                .refreshable {
                    await refresh()
                }
            }
        }
        .navigationTitle(source?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if comics.isEmpty {
                await loadNextPage()
            }
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 100, maximum: 145), spacing: 12, alignment: .top)
        ]
    }

    private func refresh() async {
        currentPage = 1
        reachedEnd = false
        error = nil
        comics = []
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoading, !reachedEnd else { return }
        guard let source else {
            error = "Source not found: \(sourceKey)"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            switch loader {
            case .explore(_, let exploreIndex):
                let (pageComics, pageMax) = try await source.loadExplorePage(exploreIndex, page: currentPage)
                let filtered = BlockListFilter.filterComics(pageComics)
                comics.append(contentsOf: filtered)
                if let pageMax {
                    if currentPage >= pageMax { reachedEnd = true }
                } else if pageComics.isEmpty {
                    reachedEnd = true
                }
                currentPage += 1
            case .search(_, let keyword, let options):
                let (pageComics, pageMax) = try await source.search(keyword: keyword, page: currentPage, options: options)
                let filtered = BlockListFilter.filterComics(pageComics)
                comics.append(contentsOf: filtered)
                if pageMax == nil {
                    reachedEnd = true
                } else if currentPage >= (pageMax ?? 0) {
                    reachedEnd = true
                }
                currentPage += 1
            case .category(_, let category, let param, let options):
                let (pageComics, pageMax) = try await source.loadCategoryComics(category: category, param: param, options: options, page: currentPage)
                let filtered = BlockListFilter.filterComics(pageComics)
                comics.append(contentsOf: filtered)
                if pageMax == nil || pageComics.isEmpty {
                    reachedEnd = true
                }
                currentPage += 1
            case .ranking(_, let option):
                let (pageComics, pageMax) = try await source.loadRanking(option: option, page: currentPage)
                let filtered = BlockListFilter.filterComics(pageComics)
                comics.append(contentsOf: filtered)
                if pageMax == nil || pageComics.isEmpty {
                    reachedEnd = true
                }
                currentPage += 1
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
