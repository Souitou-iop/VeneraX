import SwiftUI
import VeneraKit

/// 多源聚合搜索视图（对齐原版 aggregated_search_page.dart）。
/// 按设置 searchSources 的键序并发向各源发起查询，以分源横滑网格聚合呈现；
/// 页内可改写关键词重搜（写入共享搜索历史），各源结果渐进刷新。
struct AggregatedSearchView: View {
    @State private var keyword: String
    @State private var searchField: String
    @State private var sourceResults: [SourceSearchResult] = []
    @State private var isSearching = true

    init(keyword: String) {
        _keyword = State(initialValue: keyword)
        _searchField = State(initialValue: keyword)
    }

    struct SourceSearchResult: Identifiable, Sendable {
        var id: String { source.key }
        let source: ComicSource
        var comics: [Comic] = []
        var error: String? = nil
        var isLoading: Bool = true
    }

    var body: some View {
        Group {
            if sourceResults.isEmpty && !isSearching {
                ContentUnavailableView {
                    Label("No search sources selected".tl, systemImage: "magnifyingglass")
                } description: {
                    Text("Enable sources under Settings > Search Sources".tl)
                }
            } else {
                sections
            }
        }
        .navigationTitle(keyword)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchField,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Search".tl)
        )
        .onSubmit(of: .search) { reSearch(from: searchField) }
        .task(id: keyword) {
            await performAggregatedSearch()
        }
    }

    private var sections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sourceResults) { result in
                    sourceSection(result)
                }

                if !isSearching && !sourceResults.isEmpty
                    && sourceResults.allSatisfy({ $0.comics.isEmpty && $0.error == nil }) {
                    ContentUnavailableView {
                        Label("No search results found".tl, systemImage: "magnifyingglass")
                    } description: {
                        Text("Try searching with different keywords".tl)
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
        .id(keyword)
    }

    @ViewBuilder
    private func sourceSection(_ result: SourceSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 原版点击整个分区头跳转单源结果页，这里以整行链接等价实现。
            NavigationLink(value: ComicTarget.search(result.source.key, keyword)) {
                HStack {
                    Text(verbatim: result.source.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 2) {
                        Text("More".tl)
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            if result.isLoading {
                HStack {
                    ProgressView()
                    Text("Searching...".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 160)
            } else if let error = result.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: 60)
            } else if result.comics.isEmpty {
                Text("No results".tl)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(result.comics, id: \.id) { comic in
                            ComicTile(comic: comic)
                                .frame(width: 105)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Divider()
                .padding(.top, 8)
        }
    }

    private func reSearch(from text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        AppData.shared.addSearchHistory(trimmed)
        searchField = trimmed
        keyword = trimmed
    }

    @MainActor
    private func performAggregatedSearch() async {
        let searchKeyword = keyword
        guard !searchKeyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            sourceResults = []
            isSearching = false
            return
        }

        isSearching = true
        let sources = ComicSourceManager.shared.aggregatedSearchSources()
        sourceResults = sources.map { SourceSearchResult(source: $0) }

        await withTaskGroup(of: (String, [Comic]?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let page = try await source.search(
                            keyword: searchKeyword,
                            page: 1,
                            options: source.defaultSearchOptions()
                        )
                        return (source.key, page.comics, nil)
                    } catch {
                        return (source.key, nil, error.localizedDescription)
                    }
                }
            }

            for await (key, comics, error) in group {
                // 关键词已被改写（任务被取消）时丢弃迟到的结果，避免写入新一轮的状态。
                guard !Task.isCancelled,
                      let idx = sourceResults.firstIndex(where: { $0.source.key == key }) else { continue }
                sourceResults[idx].isLoading = false
                sourceResults[idx].comics = comics ?? []
                sourceResults[idx].error = error.map(Self.friendlyError)
            }
        }
        guard !Task.isCancelled else { return }
        isSearching = false
    }

    private static func friendlyError(_ message: String) -> String {
        message.lowercased().contains("cloudflare") ? "Cloudflare verification required".tl : message
    }
}
