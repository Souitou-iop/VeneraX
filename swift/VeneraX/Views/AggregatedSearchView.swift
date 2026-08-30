import SwiftUI
import VeneraKit

/// 多源聚合搜索视图（对齐原版 aggregated_search_page.dart）。
/// 并发向所有已安装且支持搜索的源发起查询，以分源横滑网格聚合呈现。
struct AggregatedSearchView: View {
    let keyword: String

    @State private var sourceResults: [SourceSearchResult] = []
    @State private var isSearching = true

    struct SourceSearchResult: Identifiable, Sendable {
        var id: String { source.key }
        let source: ComicSource
        var comics: [Comic] = []
        var error: String? = nil
        var isLoading: Bool = true
    }

    private var searchableSources: [ComicSource] {
        AppServices.shared.sources.filter { $0.searchAvailable }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sourceResults) { result in
                    sourceSection(result)
                }

                if !isSearching && sourceResults.allSatisfy({ $0.comics.isEmpty && $0.error == nil }) {
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
        .navigationTitle(keyword)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await performAggregatedSearch()
        }
    }

    @ViewBuilder
    private func sourceSection(_ result: SourceSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: result.source.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                if !result.comics.isEmpty {
                    NavigationLink(value: ComicTarget.search(result.source.key, keyword)) {
                        HStack(spacing: 2) {
                            Text("More".tl)
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
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

    @MainActor
    private func performAggregatedSearch() async {
        isSearching = true
        let sources = searchableSources
        var results = sources.map { SourceSearchResult(source: $0) }
        sourceResults = results

        let searchKW = keyword
        await withTaskGroup(of: (String, [Comic]?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let page = try await source.search(keyword: searchKW, page: 1, options: [:])
                        return (source.key, page.comics, nil)
                    } catch {
                        return (source.key, nil, error.localizedDescription)
                    }
                }
            }

            for await (key, comics, error) in group {
                if let idx = results.firstIndex(where: { $0.source.key == key }) {
                    results[idx].isLoading = false
                    results[idx].comics = comics ?? []
                    results[idx].error = error
                }
            }
        }
        sourceResults = results
        isSearching = false
    }
}
