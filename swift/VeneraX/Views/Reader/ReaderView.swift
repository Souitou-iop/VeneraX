import SwiftUI
import VeneraKit

/// 阅读器：画廊（TabView 翻页）与连续（滚动）两种引擎，缩放经
/// ZoomableImageView（UIScrollView），支持 CoreImage/Metal 画质增强滤镜，
/// 夜间模式为反色滤镜，含工具栏、章节抽屉、页码浮层、预载、历史与阅读时长统计。
struct ReaderView: View {
    @State private var model: ReaderModel
    @State private var showChapters = false
    @State private var chapterTransition: String?
    @State private var isCurrentPageFavorited = false
    @State private var isSavingFavorite = false
    @State private var isAutoPageTurning = false
    @State private var showChapterComments = false
    @State private var isOnChapterCommentsPage = false
    @State private var showPageJumpDialog = false
    @State private var pageJumpInput = ""
    @Environment(\.dismiss) private var dismiss

    private var timeTracker: ReadingTimeTracker

    init(comic: Comic, source: ComicSource?, epIndex: Int = 0, chapters: ComicChapters?) {
        let model = ReaderModel(comic: comic, source: source, epIndex: epIndex)
        model.setChapters(chapters)
        _model = State(initialValue: model)
        timeTracker = ReadingTimeTracker(
            id: comic.id,
            type: ComicID.forSource(comic.sourceKey),
            title: comic.title,
            subtitle: comic.subtitle,
            cover: comic.cover
        )
    }

    var body: some View {
        Group {
            if model.isLoadingPages {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(readerBackground)
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Network Error".tl, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Retry".tl) {
                        Task { await model.loadPages() }
                    }
                }
            } else if model.pages.isEmpty {
                ContentUnavailableView("No pages".tl, systemImage: "photo.on.rectangle.angled")
            } else {
                readerContent
            }
        }
        .background(readerBackground)
        .statusBarHidden(model.isToolbarHidden)
        .persistentSystemOverlays(model.isToolbarHidden ? .hidden : .visible)
        // 阅读器为沉浸式全屏媒体视图（HIG 允许对全屏媒体隐藏 Tab 栏）
        .toolbar(.hidden, for: .tabBar)
        .toolbar(model.isToolbarHidden ? .hidden : .visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await model.loadPages()
            model.recordHistory()
            refreshFavoriteState()
            timeTracker.start()
        }
        .task(id: isAutoPageTurning) {
            guard isAutoPageTurning else { return }
            let seconds = max(1, AppData.shared.settings["autoPageTurningInterval"].intValue ?? 5)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                guard !model.isLoadingPages, model.errorMessage == nil else { continue }
                let advanced = await ReaderPageTurning.goNext(model, chapterTransition: $chapterTransition)
                if !advanced {
                    isAutoPageTurning = false
                    return
                }
            }
        }
        .onDisappear {
            isAutoPageTurning = false
            timeTracker.stop()
        }
        .onChange(of: model.currentIndex) { _, _ in
            refreshFavoriteState()
        }
        .onChange(of: model.currentEpIndex) { _, _ in
            refreshFavoriteState()
        }
        .sheet(isPresented: $showChapters) {
            chapterDrawer
        }
        .sheet(isPresented: $showChapterComments) {
            if let source = model.source, model.chapterIds.indices.contains(model.currentEpIndex) {
                NavigationStack {
                    ChapterCommentsView(
                        comicID: model.comic.id,
                        epID: model.chapterIds[model.currentEpIndex],
                        comicTitle: model.comic.title,
                        chapterTitle: model.chapterTitle(at: model.currentEpIndex) ?? "Chapter \(model.currentEpIndex + 1)",
                        source: source
                    )
                }
            }
        }
        // 跳页对话框（对齐上游 v2.3.0：显示总页数，输入自动钳制到有效范围）。
        .alert("Jump to page".tl, isPresented: $showPageJumpDialog) {
            TextField("Page number".tl, text: $pageJumpInput)
                .keyboardType(.numberPad)
            Button("Cancel".tl, role: .cancel) {}
            Button("Jump".tl) {
                guard let page = Int(pageJumpInput.trimmingCharacters(in: .whitespaces)) else { return }
                Task { await model.jumpToPage(page) }
            }
        } message: {
            Text(verbatim: "\("Total pages".tl): \(model.totalPages) (1-\(model.totalPages))")
        }
    }

    /// Flutter 版在画廊末尾插入章节评论页；仅在源、设置和章节 ID 都可用时加入。
    /// 双页模式也作为独立的末尾页插入，而不是伪装成一个双页 spread。
    private var chapterCommentsPage: AnyView? {
        guard !model.mode.isContinuous,
              AppData.shared.settings["showChapterComments"].boolValue ?? false,
              AppData.shared.settings["showChapterCommentsAtEnd"].boolValue ?? false,
              let source = model.source,
              source.chapterCommentsAvailable,
              model.chapterIds.indices.contains(model.currentEpIndex) else { return nil }
        return AnyView(
            ChapterCommentsView(
                comicID: model.comic.id,
                epID: model.chapterIds[model.currentEpIndex],
                comicTitle: model.comic.title,
                chapterTitle: model.chapterTitle(at: model.currentEpIndex) ?? "Chapter \(model.currentEpIndex + 1)",
                source: source
            )
        )
    }

    private var readerBackground: Color {
        if model.isNightMode { return .black }
        switch AppData.shared.settings["readerBackgroundColor"].stringValue ?? "system" {
        case "white": return .white
        case "gray": return Color(white: 0.85)
        case "black": return .black
        case "sepia": return Color(red: 0.98, green: 0.94, blue: 0.87)
        case "green": return Color(red: 0.85, green: 0.93, blue: 0.85)
        default: return Color(uiColor: .systemBackground)
        }
    }

    private var backgroundColor: Color {
        readerBackground
    }

    @ViewBuilder
    private var readerContent: some View {
        ZStack {
            if model.mode.isContinuous {
                ContinuousPager(
                    model: model,
                    chapterTransition: $chapterTransition,
                    onTapToolbar: { toggleToolbar() }
                )
            } else {
                GalleryPager(
                    model: model,
                    chapterTransition: $chapterTransition,
                    onTapToolbar: { toggleToolbar() },
                    chapterCommentsPage: chapterCommentsPage,
                    isShowingChapterCommentsPage: $isOnChapterCommentsPage
                )
            }
            if !isOnChapterCommentsPage {
                if model.isNightMode {
                    NightModeOverlay()
                        .allowsHitTesting(false)
                }
                pageNumberOverlay
                if let transition = chapterTransition {
                    ChapterTransitionOverlay(title: transition)
                }
            }
        }
        // Reserve space for the controls while keeping the control surface floating.
        // safeAreaInset prevents the last page/webtoon cell from being hidden behind it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isOnChapterCommentsPage, !model.isToolbarHidden {
                toolbar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .modifier(ReaderTapZones(
            model: model,
            chapterTransition: $chapterTransition,
            onTapToolbar: toggleToolbar,
            isEnabled: !isOnChapterCommentsPage
        ))
    }

    private var pageNumberOverlay: some View {
        VStack {
            Spacer()
            HStack {
                if AppData.shared.settings["showPageNumberInReader"].boolValue ?? true {
                    Text(verbatim: "\(model.currentPageNumber)/\(model.totalPages)")
                        .font(.caption.monospacedDigit())
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, model.isToolbarHidden ? 12 : 64)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
        .allowsHitTesting(false)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            readerToolbarButton("Chapters".tl, systemImage: "list.bullet") {
                showChapters = true
            }

            Slider(
                value: Binding(
                    get: { Double(model.currentIndex) },
                    set: { value in
                        let index = Int(value)
                        if index != model.currentIndex { model.setIndex(index) }
                    }
                ),
                in: 0...Double(max(model.totalPages - 1, 0)),
                onEditingChanged: { editing in
                    if !editing {
                        let index = model.currentIndex
                        Task { await model.afterIndexChange(index) }
                    }
                }
            )
            .tint(.accentColor)
            .frame(minWidth: 90)
            .padding(.horizontal, 10)

            // 页码指示可点开跳页对话框（对齐上游 v2.3.0）。
            Button {
                pageJumpInput = "\(model.currentPageNumber)"
                showPageJumpDialog = true
            } label: {
                Text(verbatim: "\(model.currentPageNumber)/\(model.totalPages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .frame(minWidth: 46)
            .accessibilityLabel("Page progress".tl)

            if let source = model.source, source.chapterCommentsAvailable,
               model.chapterIds.indices.contains(model.currentEpIndex) {
                readerToolbarButton("Chapter Comments".tl, systemImage: "bubble.left.and.bubble.right") {
                    showChapterComments = true
                }
            }

            readerToolbarButton(
                isAutoPageTurning ? "Stop auto page turning".tl : "Start auto page turning".tl,
                systemImage: isAutoPageTurning ? "timer" : "timer.square"
            ) {
                isAutoPageTurning.toggle()
            }

            Button {
                guard !isSavingFavorite else { return }
                isSavingFavorite = true
                Task {
                    let result = await model.toggleCurrentPageFavorite()
                    await MainActor.run {
                        isSavingFavorite = false
                        if let result {
                            isCurrentPageFavorited = result
                            AppServices.shared.showMessage(
                                (result ? "Added to image favorites" : "Removed from image favorites").tl
                            )
                        } else {
                            AppServices.shared.showMessage("Image is still loading".tl)
                        }
                    }
                }
            } label: {
                Image(systemName: isCurrentPageFavorited ? "star.fill" : "star")
                    .frame(minWidth: 36, minHeight: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCurrentPageFavorited ? .yellow : .accentColor)
            .disabled(isSavingFavorite)
            .accessibilityLabel((isCurrentPageFavorited ? "Remove image favorite" : "Add image favorite").tl)

            Menu {
                Picker("Mode".tl, selection: Binding(
                    get: { model.mode },
                    set: { model.mode = $0 }
                )) {
                    ForEach(ReaderModel.Mode.allCases, id: \.self) { mode in
                        Text(verbatim: modeName(mode)).tag(mode)
                    }
                }
                Button(model.isNightMode ? "Day Mode".tl : "Night Mode".tl) {
                    model.isNightMode.toggle()
                    AppData.shared.settings["readerNightMode"] = .bool(model.isNightMode)
                }
                Button {
                    model.retryPage(model.currentIndex)
                } label: {
                    Label("Reload".tl, systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 36, minHeight: 36)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Reader options".tl)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(Color.accentColor)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.isToolbarHidden)
    }

    private func readerToolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 36, minHeight: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var chapterDrawer: some View {
        NavigationStack {
            List {
                ForEach(Array(model.chapterIds.enumerated()), id: \.offset) { index, _ in
                    Button {
                        showChapters = false
                        Task { await model.switchChapter(to: index) }
                    } label: {
                        HStack {
                            Text(verbatim: model.chapterTitle(at: index) ?? "\(index + 1)")
                                .foregroundStyle(index == model.currentEpIndex ? Color.accentColor : .primary)
                            Spacer()
                            if model.isChapterReadMark(index) {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chapters".tl)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func modeName(_ mode: ReaderModel.Mode) -> String {
        switch mode {
        case .galleryLeftToRight: return "Gallery ←→".tl
        case .galleryRightToLeft: return "Manga →←".tl
        case .galleryTopToBottom: return "Vertical ↑↓".tl
        case .continuousTopToBottom: return "Webtoon ↓".tl
        case .continuousLeftToRight: return "Continuous ←→".tl
        case .continuousRightToLeft: return "Continuous →←".tl
        }
    }

    private func refreshFavoriteState() {
        isCurrentPageFavorited = model.isCurrentPageFavorited()
    }

    private func toggleToolbar() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            model.isToolbarHidden.toggle()
        }
    }
}

/// 夜间模式：反色 + 变暗（对齐原版 readerNightMode 的暖色遮罩语义）。
struct NightModeOverlay: View {
    private var tint: Color {
        let colorName = AppData.shared.settings["readerNightModeColor"].stringValue ?? "warm"
        switch colorName {
        case "black": return .black
        case "red": return Color(red: 0.4, green: 0.1, blue: 0.05)
        default: return Color(red: 1.0, green: 0.55, blue: 0.18)
        }
    }

    var body: some View {
        let intensity = AppData.shared.settings["readerNightModeIntensity"].doubleValue ?? 0.45
        tint.opacity(max(intensity, 0.1) * 0.85)
            .ignoresSafeArea()
            .blendMode(.multiply)
    }
}
