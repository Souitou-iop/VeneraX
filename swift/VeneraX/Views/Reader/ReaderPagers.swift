import SwiftUI
import VeneraKit

/// 画廊翻页引擎（gallery LTR/RTL/TTB）：TabView(.page) + 单页/双页并排缩放容器。
struct GalleryPager: View {
    @Bindable var model: ReaderModel
    var chapterTransition: Binding<String?> = .constant(nil)
    var onTapToolbar: () -> Void = {}
    var chapterCommentsPage: AnyView? = nil
    var isShowingChapterCommentsPage: Binding<Bool> = .constant(false)
    @State private var selectedPage = 0
    @State private var selectedSpread = 0

    private var isTwoPage: Bool {
        AppData.shared.settings["readerTwoPageMode"].boolValue ?? false
    }

    var body: some View {
        if isTwoPage {
            twoPageGallery
        } else {
            singlePageGallery
        }
    }

    private var singlePageGallery: some View {
        TabView(selection: $selectedPage) {
            ForEach(model.pages.indices, id: \.self) { index in
                ReaderPageView(
                    model: model, index: index,
                    chapterTransition: chapterTransition,
                    onTapToolbar: onTapToolbar
                )
                .tag(index)
            }
            if let chapterCommentsPage {
                chapterCommentsPage
                    .tag(commentsPageIndex)
                    .background(Color(uiColor: .systemBackground))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, model.mode.isRightToLeft ? .rightToLeft : .leftToRight)
        .onAppear {
            selectedPage = model.currentIndex
        }
        .onChange(of: selectedPage) { _, newValue in
            if newValue == commentsPageIndex, chapterCommentsPage != nil {
                isShowingChapterCommentsPage.wrappedValue = true
            } else {
                isShowingChapterCommentsPage.wrappedValue = false
                if model.pages.indices.contains(newValue), model.currentIndex != newValue {
                    ReaderPageTurning.turn(model, to: newValue)
                }
            }
        }
        .onChange(of: model.currentIndex) { _, newValue in
            guard !isShowingChapterCommentsPage.wrappedValue else { return }
            if selectedPage != newValue { selectedPage = newValue }
        }
        .onChange(of: model.pages.count) { _, _ in
            if !isShowingChapterCommentsPage.wrappedValue {
                selectedPage = min(model.currentIndex, max(model.pages.count - 1, 0))
            }
        }
    }

    private var commentsPageIndex: Int {
        model.pages.count
    }

    private var twoPageGallery: some View {
        let spreads = Array(stride(from: 0, to: model.pages.count, by: 2))
        let commentsIndex = model.pages.count
        return TabView(selection: $selectedSpread) {
            ForEach(spreads, id: \.self) { spreadIndex in
                HStack(spacing: 4) {
                    if model.mode.isRightToLeft {
                        if spreadIndex + 1 < model.pages.count {
                            ReaderPageView(
                                model: model, index: spreadIndex + 1,
                                chapterTransition: chapterTransition,
                                onTapToolbar: onTapToolbar
                            )
                        }
                        ReaderPageView(
                            model: model, index: spreadIndex,
                            chapterTransition: chapterTransition,
                            onTapToolbar: onTapToolbar
                        )
                    } else {
                        ReaderPageView(
                            model: model, index: spreadIndex,
                            chapterTransition: chapterTransition,
                            onTapToolbar: onTapToolbar
                        )
                        if spreadIndex + 1 < model.pages.count {
                            ReaderPageView(
                                model: model, index: spreadIndex + 1,
                                chapterTransition: chapterTransition,
                                onTapToolbar: onTapToolbar
                            )
                        }
                    }
                }
                .tag(spreadIndex)
            }
            if let chapterCommentsPage {
                chapterCommentsPage
                    .tag(commentsIndex)
                    .background(Color(uiColor: .systemBackground))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onAppear {
            selectedSpread = model.currentIndex / 2 * 2
        }
        .onChange(of: selectedSpread) { _, newValue in
            if newValue == commentsIndex, chapterCommentsPage != nil {
                isShowingChapterCommentsPage.wrappedValue = true
            } else {
                isShowingChapterCommentsPage.wrappedValue = false
                if model.pages.indices.contains(newValue), model.currentIndex != newValue {
                    ReaderPageTurning.turn(model, to: newValue)
                }
            }
        }
        .onChange(of: model.currentIndex) { _, newValue in
            guard !isShowingChapterCommentsPage.wrappedValue else { return }
            let spread = newValue / 2 * 2
            if selectedSpread != spread { selectedSpread = spread }
        }
        .onChange(of: model.pages.count) { _, _ in
            guard !isShowingChapterCommentsPage.wrappedValue else { return }
            selectedSpread = model.currentIndex / 2 * 2
        }
    }
}

/// 连续滚动引擎（continuous TTB/LTR/RTL），支持跨章节平滑追加与章节分隔标头。
struct ContinuousPager: View {
    @Bindable var model: ReaderModel
    var chapterTransition: Binding<String?> = .constant(nil)
    var onTapToolbar: () -> Void = {}

    var body: some View {
        if model.mode == .continuousTopToBottom {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    continuousItemViews
                }
            }
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    continuousItemViews
                }
            }
            .environment(\.layoutDirection, model.mode.isRightToLeft ? .rightToLeft : .leftToRight)
        }
    }

    @ViewBuilder
    private var continuousItemViews: some View {
        ForEach(model.continuousItems) { item in
            if item.isChapterHeader {
                chapterDividerView(title: item.chapterTitle ?? "")
                    .onAppear {
                        model.onContinuousItemVisible(item)
                    }
            } else {
                ContinuousPageView(
                    model: model,
                    item: item,
                    onTapToolbar: onTapToolbar
                )
                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                .onAppear {
                    model.onContinuousItemVisible(item)
                }
            }
        }

        if model.isLoadingNextChapter {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading next chapter...".tl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func chapterDividerView(title: String) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
            Text(verbatim: title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// 连续模式单页视图：自动加载指定条目并应用画质增强滤镜。
struct ContinuousPageView: View {
    @Bindable var model: ReaderModel
    let item: ReaderModel.ContinuousPageItem
    var onTapToolbar: () -> Void = {}

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTapToolbar()
        }
        .task(id: item.id) {
            image = nil
            guard let data = await model.continuousImageData(for: item), !Task.isCancelled else { return }
            let parameters = ImageEnhancer.shared.currentParameters()
            let rendered = await Task.detached(priority: .userInitiated) {
                guard let raw = UIImage(data: data) else { return nil as UIImage? }
                return ImageEnhancer.shared.enhance(raw, parameters: parameters)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

/// 单页：缩放（UIScrollView 内核）+ 画质增强 + 加载状态；单击经 UIKit 手势转发。
struct ReaderPageView: UIViewRepresentable {
    @Bindable var model: ReaderModel
    let index: Int
    var continuous: Bool = false
    var chapterTransition: Binding<String?> = .constant(nil)
    var onTapToolbar: () -> Void = {}

    func makeUIView(context: Context) -> ZoomableScrollView {
        let view = ZoomableScrollView()
        view.onTapRatio = { [weak view] ratio in
            Task { @MainActor in
                guard let view, view.window != nil else { return }
                if continuous {
                    onTapToolbar()
                    return
                }
                let zones = ReaderTapZones(
                    model: model,
                    chapterTransition: chapterTransition,
                    onTapToolbar: onTapToolbar
                )
                zones.handleTap(xRatio: ratio)
            }
        }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: ZoomableScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.view = uiView

        // SwiftUI may call updateUIView repeatedly while a page is on screen.
        // Cancel the previous load instead of creating an unbounded collection
        // of duplicate requests and stale image-update tasks.
        if coordinator.loadedIndex != index {
            coordinator.loadTask?.cancel()
            coordinator.renderTask?.cancel()
            coordinator.loadTask = nil
            coordinator.renderTask = nil
            coordinator.loadedIndex = index
            coordinator.loadedData = nil
            uiView.setImage(nil)
        }
        guard coordinator.loadTask == nil, coordinator.renderTask == nil, coordinator.loadedData == nil else { return }

        coordinator.loadTask = Task { @MainActor [weak coordinator, weak uiView, weak model] in
            guard let coordinator, let uiView, let model else { return }
            let data = await model.imageData(at: index)
            guard !Task.isCancelled else { return }
            coordinator.loadTask = nil
            coordinator.loadedData = data
            guard let data else {
                uiView.setImage(nil)
                return
            }
            let parameters = ImageEnhancer.shared.currentParameters()
            coordinator.renderTask = Task { @MainActor [weak coordinator, weak uiView] in
                let rendered = await Task.detached(priority: .userInitiated) {
                    guard let raw = UIImage(data: data) else { return nil as UIImage? }
                    return ImageEnhancer.shared.enhance(raw, parameters: parameters)
                }.value
                guard !Task.isCancelled,
                      let coordinator,
                      let uiView,
                      coordinator.loadedIndex == index else { return }
                coordinator.renderTask = nil
                uiView.setImage(rendered)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: ZoomableScrollView?
        var loadedIndex: Int?
        var loadedData: Data?
        var loadTask: Task<Void, Never>?
        var renderTask: Task<Void, Never>?

        deinit {
            loadTask?.cancel()
            renderTask?.cancel()
        }
    }
}

/// 缩放容器：初始 contain 适配，双击放大，单指点区翻页经 UIKit 手势转发。
final class ZoomableScrollView: UIView {
    var onTapRatio: ((CGFloat) -> Void)?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 10
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        singleTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(singleTap)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let location = gesture.location(in: self)
        onTapRatio?(bounds.width > 0 ? location.x / bounds.width : 0.5)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let fitScale = min(widthScale, heightScale)
        let size = CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale)
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = max(widthScale / fitScale, heightScale / fitScale, 4)
        scrollView.zoomScale = 1
        imageView.bounds = CGRect(origin: .zero, size: size)
        centerImageView()
    }

    private func centerImageView() {
        let horizontal = max((scrollView.bounds.width - imageView.frame.width) / 2, 0)
        let vertical = max((scrollView.bounds.height - imageView.frame.height) / 2, 0)
        imageView.frame.origin = CGPoint(x: horizontal, y: vertical)
        scrollView.contentSize = imageView.frame.size
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            centerImageView()
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(scrollView.maximumZoomScale, 2.5)
            scrollView.setZoomScale(scale, animated: true)
            let rect = CGRect(
                x: point.x * (scale / scrollView.zoomScale) - scrollView.bounds.width / 2,
                y: point.y * (scale / scrollView.zoomScale) - scrollView.bounds.height / 2,
                width: scrollView.bounds.width,
                height: scrollView.bounds.height
            )
            scrollView.zoom(to: rect, animated: false)
        }
    }
}

extension ZoomableScrollView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }
}
