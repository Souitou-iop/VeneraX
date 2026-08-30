import SwiftUI
import VeneraKit

/// 搜索页：支持全源聚合搜索、单源精准搜索、高级搜索参数抽屉及搜索历史持久化。
struct SearchView: View {
    @State private var keyword = ""
    @State private var selectedSourceKey: String = "__all__"
    @State private var searchOptions: [String: String] = [:]
    @State private var showOptionsSheet = false
    @State private var history: [String] = AppData.shared.searchHistory
    @State private var submitted: (sourceKey: String, keyword: String, options: [String: String])?

    private var searchableSources: [ComicSource] {
        AppServices.shared.sources.filter { $0.searchAvailable }
    }

    private var currentSource: ComicSource? {
        guard selectedSourceKey != "__all__" else { return nil }
        return ComicSourceManager.shared.find(selectedSourceKey)
    }

    private var availableOptions: [(key: String, label: String, defaultValue: String, options: [(value: String, text: String)])] {
        currentSource?.loadSearchOptions() ?? []
    }

    var body: some View {
        Group {
            if let submitted {
                if submitted.sourceKey == "__all__" {
                    AggregatedSearchView(keyword: submitted.keyword)
                } else {
                    ComicListView(loader: .search(
                        sourceKey: submitted.sourceKey,
                        keyword: submitted.keyword,
                        options: submitted.options
                    ))
                }
            } else {
                searchHome
            }
        }
        .navigationTitle("Search".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectedSourceKey != "__all__" && !availableOptions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOptionsSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showOptionsSheet) {
            SearchOptionsSheet(
                optionsList: availableOptions,
                selectedOptions: $searchOptions
            )
        }
    }

    private var searchHome: some View {
        List {
            Section {
                Picker("Search Scope".tl, selection: $selectedSourceKey) {
                    Text("All Sources (Aggregated)".tl).tag("__all__")
                    ForEach(searchableSources, id: \.key) { source in
                        Text(verbatim: source.name).tag(source.key)
                    }
                }
            }

            if selectedSourceKey != "__all__" && !availableOptions.isEmpty {
                Section("Filter Options".tl) {
                    ForEach(availableOptions, id: \.key) { opt in
                        Picker(opt.label.isEmpty ? opt.key : opt.label, selection: Binding(
                            get: { searchOptions[opt.key] ?? opt.defaultValue },
                            set: { searchOptions[opt.key] = $0 }
                        )) {
                            ForEach(opt.options, id: \.value) { item in
                                Text(verbatim: item.text).tag(item.value)
                            }
                        }
                    }
                }
            }

            if !history.isEmpty {
                Section {
                    ForEach(history, id: \.self) { item in
                        Button {
                            submit(item)
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                    Button(role: .destructive) {
                        AppData.shared.clearSearchHistory()
                        history = []
                    } label: {
                        Text("Clear History".tl)
                            .font(.footnote)
                    }
                } header: {
                    Text("Search History".tl)
                }
            }
        }
        .searchable(text: $keyword, prompt: Text("Search".tl))
        .onSubmit(of: .search) {
            submit(keyword)
        }
        .onAppear {
            history = AppData.shared.searchHistory
        }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        AppData.shared.addSearchHistory(trimmed)
        history = AppData.shared.searchHistory
        submitted = (selectedSourceKey, trimmed, searchOptions)
    }
}

/// 单源高级搜索选项弹窗。
struct SearchOptionsSheet: View {
    let optionsList: [(key: String, label: String, defaultValue: String, options: [(value: String, text: String)])]
    @Binding var selectedOptions: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(optionsList, id: \.key) { opt in
                    Section(opt.label.isEmpty ? opt.key : opt.label) {
                        Picker(opt.label, selection: Binding(
                            get: { selectedOptions[opt.key] ?? opt.defaultValue },
                            set: { selectedOptions[opt.key] = $0 }
                        )) {
                            ForEach(opt.options, id: \.value) { item in
                                Text(verbatim: item.text).tag(item.value)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("Search Options".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done".tl) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset".tl) {
                        for opt in optionsList {
                            selectedOptions[opt.key] = opt.defaultValue
                        }
                    }
                }
            }
        }
    }
}
