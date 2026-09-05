import SwiftUI
import VeneraKit

/// 跨源换源搜索弹窗（对齐原版 related_sources_dialog.dart）。
/// 用当前漫画标题在其他所有源中搜索同名漫画，支持一键查看详情或换源阅读。
struct RelatedSourcesSheet: View {
    let comic: Comic

    @Environment(\.dismiss) private var dismiss
    @State private var searchKeyword: String = ""
    @State private var results: [Comic] = []
    @State private var isSearching = false
    @State private var failedSourceKeys: [String] = []
    @State private var selectedTargetComic: Comic?

    private var otherSearchableSources: [ComicSource] {
        AppServices.shared.sources.filter { $0.searchAvailable && $0.key != comic.sourceKey }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        ComicCover(url: comic.cover)
                            .frame(width: 44, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: comic.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Current Source: \(sourceName(for: comic.sourceKey))".tl)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Current Comic".tl)
                }

                Section {
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("Searching in other sources...".tl)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if results.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No matching comics found in other sources".tl)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                            if !failedSourceKeys.isEmpty {
                                retryRow
                            }
                        }
                    } else {
                        ForEach(results, id: \.id) { result in
                            Button {
                                selectedTargetComic = result
                            } label: {
                                HStack(spacing: 12) {
                                    ComicCover(url: result.cover)
                                        .frame(width: 44, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if !result.subtitle.isEmpty {
                                            Text(verbatim: result.subtitle)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Text(verbatim: sourceName(for: result.sourceKey))
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    if !results.isEmpty && !failedSourceKeys.isEmpty {
                        retryRow
                    }
                } header: {
                    Text("Results in other sources (\(results.count))".tl)
                }
            }
            .navigationTitle("Related Sources".tl)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchKeyword, prompt: "Search title".tl)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close".tl) { dismiss() }
                }
            }
            .navigationDestination(item: $selectedTargetComic) { targetComic in
                ComicDetailsView(comic: targetComic)
            }
            .onAppear {
                searchKeyword = comic.title
                Task {
                    await performSearch()
                }
            }
            .onSubmit(of: .search) {
                Task {
                    await performSearch()
                }
            }
        }
    }

    private func sourceName(for key: String) -> String {
        ComicSourceManager.shared.find(key)?.name ?? key
    }

    @MainActor
    private func performSearch() async {
        let kw = searchKeyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        isSearching = true
        results = []
        let sources = otherSearchableSources

        let searchKW = kw
        let allFound = await withTaskGroup(of: (String, [Comic]?).self) { group -> [Comic] in
            for source in sources {
                group.addTask {
                    do {
                        let page = try await source.search(keyword: searchKW, page: 1, options: [:])
                        return (source.key, page.comics)
                    } catch {
                        return (source.key, nil)
                    }
                }
            }

            var listAccum: [Comic] = []
            var failed: [String] = []
            for await (key, list) in group {
                if let list {
                    listAccum.append(contentsOf: list)
                } else {
                    failed.append(key)
                }
            }
            failedSourceKeys = failed
            return listAccum
        }
        results = allFound
        isSearching = false
    }

    /// 部分源搜索失败时给出明确的失败数与重试入口，而不是把失败伪装
    /// 成「无结果」。
    private var retryRow: some View {
        HStack {
            Text("@a sources failed".tl.replacingOccurrences(of: "@a", with: String(failedSourceKeys.count)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await performSearch() }
            } label: {
                Label("Retry".tl, systemImage: "arrow.clockwise")
            }
            .font(.caption)
        }
    }
}
