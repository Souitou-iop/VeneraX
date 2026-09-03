import SwiftUI
import VeneraKit

/// 漫画详情页：封面信息头 / 标签 / 章节列表（支持分组与下载状态标记、正倒序切换）/ 推荐区 /
/// 评论入口 / 收藏、多模式批量下载与跨源换源搜索操作。
struct ComicDetailsView: View {
    let comic: Comic

    @State private var details: ComicDetails?
    @State private var error: String?
    @State private var selectedGroup: String?
    @State private var isFavorite = false
    @State private var isLoading = true
    @State private var showFavoriteSheet = false
    @State private var showDownloadSheet = false
    @State private var showRelatedSourcesSheet = false
    @State private var isChapterReversed: Bool = AppData.shared.settings["reverseChapterOrder"].boolValue ?? false
    @State private var readerTarget: ReaderTarget?
    /// 「隐藏重复章节」开关（每部漫画、设备本地，对齐原版 ChapterDuplicatePrefs）。
    @State private var hideDuplicateChapters = false
    @State private var duplicateChapterIndices: Set<Int> = []

    private func refreshDuplicateChapterState() {
        hideDuplicateChapters = ChapterDuplicatePrefs.isHidden(comicId: comic.id, sourceKey: comic.sourceKey)
        duplicateChapterIndices = details?.chapters?.duplicateTitleIndices() ?? []
    }

    private func addToReadLater() {
        ReadLaterManager.shared.add(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            cover: comic.cover,
            type: ComicID.forSource(comic.sourceKey),
            tags: comic.tags
        )
        AppServices.shared.showMessage("Added to read later".tl)
    }

    private var source: ComicSource? {
        ComicSourceManager.shared.find(comic.sourceKey)
    }

    private var comicType: Int {
        ComicID.forSource(comic.sourceKey)
    }

    private func handleDownloadTap() {
        if DownloadManager.shared.isDownloading(id: comic.id, type: comicType) {
            AppServices.shared.showMessage("The comic is downloading".tl)
            return
        }
        guard let details else { return }
        if details.chapters == nil || details.chapters?.isEmpty == true {
            if LocalManager.shared.isDownloaded(id: comic.id, type: comicType, ep: 1) {
                AppServices.shared.showMessage("The comic is downloaded".tl)
                return
            }
            let task = ImagesDownloadTask(
                sourceKey: comic.sourceKey,
                comicId: comic.id,
                comic: details,
                chapters: nil,
                comicTitle: comic.title,
                comicCover: comic.cover
            )
            DownloadManager.shared.addTask(task)
            AppServices.shared.showMessage("Download started".tl)
        } else {
            showDownloadSheet = true
        }
    }

    var body: some View {
        Group {
            if let details {
                detailsContent(details)
            } else if let error {
                ContentUnavailableView {
                    Label("Network Error".tl, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Retry".tl) { Task { await load() } }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(details?.title ?? comic.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    handleDownloadTap()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFavoriteSheet = true
                } label: {
                    Image(systemName: "heart")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        addToReadLater()
                    } label: {
                        Label("Read Later".tl, systemImage: "clock.badge.plus")
                    }

                    if comic.sourceKey != "local" {
                        Button {
                            showRelatedSourcesSheet = true
                        } label: {
                            Label("Search in other sources".tl, systemImage: "arrow.triangle.branch")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showFavoriteSheet) {
            FavoriteActionSheet(comic: comic)
        }
        .sheet(isPresented: $showDownloadSheet) {
            if let details, let chapters = details.chapters {
                ChapterDownloadPickerSheet(comic: comic, details: details, chapters: chapters)
            }
        }
        .sheet(isPresented: $showRelatedSourcesSheet) {
            RelatedSourcesSheet(comic: comic)
        }
        .navigationDestination(item: $readerTarget) { target in
            readerView(for: target)
        }
        .task {
            if details == nil {
                await load()
            }
            refreshDuplicateChapterState()
        }
    }

    @ViewBuilder
    private func detailsContent(_ details: ComicDetails) -> some View {
        List {
            Section {
                headerSection(details)
            }

            if !details.tags.isEmpty {
                Section("Tags".tl) {
                    tagSection(details)
                }
            }

            if let chapters = details.chapters, !chapters.isEmpty {
                Section {
                    chapterSection(chapters)
                } header: {
                    HStack {
                        Text("Chapters".tl)
                        Text("\(chapters.ids.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Spacer()
                        if !duplicateChapterIndices.isEmpty {
                            // 仅在本作确实存在重复时提供开关（对齐原版：
                            // 无重复的列表给出一个可见无效的开关没有意义）。
                            Button {
                                let next = !hideDuplicateChapters
                                ChapterDuplicatePrefs.setHidden(next, comicId: comic.id, sourceKey: comic.sourceKey)
                                hideDuplicateChapters = next
                                AppServices.shared.showMessage(
                                    next
                                        ? "Hid @count duplicate chapters".tl.replacingOccurrences(of: "@count", with: "\(duplicateChapterIndices.count)")
                                        : "Showing all chapters".tl
                                )
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: hideDuplicateChapters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                    Text(hideDuplicateChapters ? "Show duplicate chapters".tl : "Hide duplicate chapters".tl)
                                }
                                .font(.caption)
                                .foregroundStyle(hideDuplicateChapters ? Color.accentColor : Color.secondary)
                            }
                            .accessibilityLabel(hideDuplicateChapters ? "Show duplicate chapters".tl : "Hide duplicate chapters".tl)
                        }
                        Button {
                            isChapterReversed.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isChapterReversed ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                                Text(isChapterReversed ? "Descending".tl : "Ascending".tl)
                            }
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if !details.recommend.isEmpty {
                Section("Related Comics".tl) {
                    relatedSection(details.recommend)
                }
            }

            if let count = details.commentCount {
                Section {
                    NavigationLink(value: ComicTarget.comments(details)) {
                        Label {
                            Text("Comments".tl)
                        } icon: {
                            Image(systemName: "bubble.right")
                        }
                    }
                } footer: {
                    Text(verbatim: "\(count)")
                }
            }
        }
    }

    private func headerSection(_ details: ComicDetails) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ComicCover(url: details.cover)
                .frame(width: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: details.title)
                    .font(.headline)
                if !details.subtitle.isEmpty {
                    Text(verbatim: details.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let uploader = details.uploader {
                    Text(verbatim: uploader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let updateTime = details.updateTime {
                    Text(verbatim: updateTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(verbatim: source?.name ?? comic.sourceKey)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tagSection(_ details: ComicDetails) -> some View {
        ForEach(details.tags.sorted(by: { $0.key < $1.key }), id: \.key) { namespace, values in
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: namespace)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayoutCompat(items: values) { tag in
                    NavigationLink(value: ComicTarget.search(comic.sourceKey, tag)) {
                        Text(verbatim: tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func chapterSection(_ chapters: ComicChapters) -> some View {
        if chapters.isGrouped && chapters.groupNames.count > 1 {
            Picker("Group".tl, selection: $selectedGroup) {
                ForEach(chapters.groupNames, id: \.self) { group in
                    Text(verbatim: group).tag(Optional(group))
                }
            }
            .pickerStyle(.menu)
        }
        let entriesInGroup = currentChapters(chapters)
        // 隐藏开关只移除条目本身——平铺索引保持原值，跳转/下载/历史
        // 仍以平铺索引寻址（对齐原版 _computeVisible 语义）。
        let hidden = hideDuplicateChapters ? duplicateChapterIndices : Set<Int>()
        let idToIndex = flatIndexMap(of: chapters)
        let visibleEntries = entriesInGroup.filter { entry in
            guard let idx = idToIndex[entry.id] else { return true }
            return !hidden.contains(idx)
        }
        let displayOrder = isChapterReversed ? Array(visibleEntries.reversed()) : visibleEntries
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 98, maximum: 140), spacing: 6, alignment: .top)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(Array(displayOrder.enumerated()), id: \.offset) { _, entry in
                let absIdx = absoluteChapterIndex(chapters, entryID: entry.id)
                let isDownloaded = LocalManager.shared.isDownloaded(id: comic.id, type: comicType, ep: absIdx + 1, chapters: chapters)
                let isRead = isChapterRead(chapters, entryID: entry.id)
                Button {
                    readerTarget = ReaderTarget(
                        comic: comic,
                        epIndex: absIdx,
                        chapters: chapters
                    )
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: entry.title)
                            .font(.footnote.weight(.regular))
                            .foregroundStyle(isRead ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isDownloaded || isRead {
                            HStack(spacing: 2) {
                                if isDownloaded {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                if isRead {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(isRead ? 0.2 : 0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func readerView(for target: ReaderTarget) -> some View {
        if target.comic.sourceKey == "local" || ComicCollectionStore.isCollectionSourceKey(target.comic.sourceKey) {
            ReaderView(comic: target.comic, source: nil, epIndex: target.epIndex, chapters: target.chapters)
        } else if let source = AppServices.shared.sources.first(where: { $0.key == target.comic.sourceKey }) {
            ReaderView(comic: target.comic, source: source, epIndex: target.epIndex, chapters: target.chapters)
        } else {
            ContentUnavailableView("Source not found".tl, systemImage: "exclamationmark.triangle")
        }
    }

    private func currentChapters(_ chapters: ComicChapters) -> [ComicChapters.Entry] {
        chapters.entries(inGroup: selectedGroup)
    }

    /// id → 平铺索引（firstIndex 语义：重复 id 取首次出现）。
    private func flatIndexMap(of chapters: ComicChapters) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, id) in chapters.ids.enumerated() where map[id] == nil {
            map[id] = i
        }
        return map
    }

    private func absoluteChapterIndex(_ chapters: ComicChapters, entryID: String) -> Int {
        chapters.ids.firstIndex(of: entryID) ?? 0
    }

    private func isChapterRead(_ chapters: ComicChapters, entryID: String) -> Bool {
        guard let history = HistoryManager.shared.findHistory(id: comic.id, type: comicType) else {
            return false
        }
        let absolute = absoluteChapterIndex(chapters, entryID: entryID)
        return history.readEpisode.contains(String(absolute + 1))
    }

    private func relatedSection(_ comics: [Comic]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(200))], spacing: 12) {
                ForEach(Array(comics.enumerated()), id: \.offset) { _, comic in
                    NavigationLink(value: ComicTarget.details(comic)) {
                        VStack(alignment: .leading, spacing: 4) {
                            ComicCover(url: comic.cover)
                                .frame(width: 100)
                            Text(verbatim: comic.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard details == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if ComicCollectionStore.isCollectionSourceKey(comic.sourceKey) {
                if let collection = ComicCollectionStore.shared.findBySourceKey(comic.sourceKey) {
                    var allChapters: [ComicChapters.Entry] = []
                    var groups: [ComicChapters.Group] = []
                    for (mIdx, member) in collection.members.enumerated() {
                        let memberTitle = member.label
                        let memberId = member.comicId
                        let entry = ComicChapters.Entry(id: "\(mIdx)_\(memberId)", title: memberTitle)
                        allChapters.append(entry)
                        groups.append(ComicChapters.Group(name: memberTitle, chapters: [entry]))
                    }
                    let chapters = collection.displayMode == .tabs ? ComicChapters(groupEntries: groups) : ComicChapters(flatEntries: allChapters)
                    details = ComicDetails(
                        id: collection.id,
                        title: collection.displayName,
                        subtitle: "\(collection.members.count) comics".tl,
                        cover: collection.displayCover,
                        description: "",
                        tags: ["Type": ["Collection".tl]],
                        chapters: chapters,
                        sourceKey: collection.sourceKey
                    )
                    selectedGroup = details?.chapters?.groupNames.first
                }
                return
            }
            if comic.sourceKey == "local" {
                if let local = LocalManager.shared.find(id: comic.id, type: ComicID.local) {
                    var tagsMap: [String: [String]] = [:]
                    for t in local.tags {
                        let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            tagsMap[parts[0], default: []].append(parts[1])
                        } else {
                            tagsMap["Tags", default: []].append(t)
                        }
                    }
                    details = ComicDetails(
                        id: local.id,
                        title: local.title,
                        subtitle: local.subtitle,
                        cover: local.coverURL,
                        description: local.description,
                        tags: tagsMap,
                        chapters: local.chapters,
                        sourceKey: "local"
                    )
                    selectedGroup = details?.chapters?.groupNames.first
                }
                return
            }
            guard let source else {
                error = "Source not found: \(comic.sourceKey)"
                return
            }
            details = try await source.loadComicInfo(id: comic.id)
            selectedGroup = details?.chapters?.groupNames.first
        } catch {
            // Keep an already loaded detail page visible if a lifecycle-triggered
            // reload fails (for example, a transient source quota/403 response).
            if details == nil {
                self.error = error.localizedDescription
            } else {
                Log.warning("ComicDetails", "Refresh failed; keeping loaded details: \(error)")
            }
        }
    }
}

/// 章节选择下载弹窗：支持全选、未读全选、反选与一键加入下载队列。
struct ChapterDownloadPickerSheet: View {
    let comic: Comic
    let details: ComicDetails
    let chapters: ComicChapters

    @Environment(\.dismiss) private var dismiss
    @State private var selectedChapterIds: Set<String> = []

    private var comicType: Int { ComicID.forSource(comic.sourceKey) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("Select All".tl) {
                            selectedChapterIds = Set(chapters.ids)
                        }
                        Spacer()
                        Button("Select Unread".tl) {
                            selectUnread()
                        }
                        Spacer()
                        Button("Invert".tl) {
                            invertSelection()
                        }
                        Spacer()
                        Button("Clear".tl) {
                            selectedChapterIds.removeAll()
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }

                Section("Chapters".tl) {
                    ForEach(chapters.ids, id: \.self) { chId in
                        let title = chapters.titles[chapters.ids.firstIndex(of: chId) ?? 0]
                        let absIdx = (chapters.ids.firstIndex(of: chId) ?? 0) + 1
                        let isDownloaded = LocalManager.shared.isDownloaded(id: comic.id, type: comicType, ep: absIdx, chapters: chapters)

                        HStack {
                            Text(verbatim: title)
                            Spacer()
                            if isDownloaded {
                                Text("Downloaded".tl)
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: selectedChapterIds.contains(chId) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedChapterIds.contains(chId) ? .blue : .secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isDownloaded {
                                if selectedChapterIds.contains(chId) {
                                    selectedChapterIds.remove(chId)
                                } else {
                                    selectedChapterIds.insert(chId)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Download Chapters".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download (\(selectedChapterIds.count))".tl) {
                        startDownload()
                        dismiss()
                    }
                    .disabled(selectedChapterIds.isEmpty)
                }
            }
            .onAppear {
                selectUnread()
            }
        }
    }

    private func selectUnread() {
        var unread: Set<String> = []
        let history = HistoryManager.shared.findHistory(id: comic.id, type: comicType)
        for (idx, chId) in chapters.ids.enumerated() {
            let absEp = idx + 1
            let isDownloaded = LocalManager.shared.isDownloaded(id: comic.id, type: comicType, ep: absEp, chapters: chapters)
            let isRead = history?.readEpisode.contains(String(absEp)) ?? false
            if !isDownloaded && !isRead {
                unread.insert(chId)
            }
        }
        selectedChapterIds = unread
    }

    private func invertSelection() {
        var inverted: Set<String> = []
        for chId in chapters.ids {
            if !selectedChapterIds.contains(chId) {
                inverted.insert(chId)
            }
        }
        selectedChapterIds = inverted
    }

    private func startDownload() {
        let task = ImagesDownloadTask(
            sourceKey: comic.sourceKey,
            comicId: comic.id,
            comic: details,
            chapters: Array(selectedChapterIds),
            comicTitle: comic.title,
            comicCover: comic.cover
        )
        DownloadManager.shared.addTask(task)
        AppServices.shared.showMessage("Download started".tl)
    }
}

/// 阅读器导航目标（章节 id 展平序号）。
struct ReaderTarget: Hashable, Identifiable {
    let comic: Comic
    let epIndex: Int
    let chapters: ComicChapters?

    var id: String { "\(comic.sourceKey):\(comic.id):\(epIndex)" }
}

/// 简单流式布局（iOS 16+ Layout 协议实现）。
struct FlowLayoutCompat<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayoutEngine {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

struct FlowLayoutEngine: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        height = currentY + lineHeight
        return CGSize(width: width, height: max(height, 28))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
