import SwiftUI
import VeneraKit

/// Continuous reader. Keeping this as a Lazy stack is important for long
/// chapters: only visible pages create translation tasks and image views.
struct ContinuousPager: View {
    @Bindable var model: ReaderModel
    var chapterTransition: Binding<String?> = .constant(nil)
    var onTapToolbar: () -> Void = {}

    var body: some View {
        // 视口尺寸取自 GeometryReader 而非 UIScreen.main.bounds（对齐原版
        // #252 的 MediaQuery.sizeOf 修复）：UIScreen.main 已废弃，iPad 分屏/
        // Stage Manager 下窗口 ≠ 屏幕尺寸，且旋转期间其 bounds 更新不保证
        // 触发重排，页面帧会停留在旧布局尺寸。GeometryReader 随容器实时变化。
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Group {
                    if model.mode == .continuousTopToBottom {
                        ScrollView(.vertical) { items(viewport: geometry.size) }
                    } else {
                        ScrollView(.horizontal) { items(viewport: geometry.size) }
                            .environment(\.layoutDirection, model.mode.isRightToLeft ? .rightToLeft : .leftToRight)
                    }
                }
                .onChange(of: model.continuousAnchorToRestoreID) { _, anchorID in
                    guard let anchorID else { return }
                    let anchor: UnitPoint = model.mode == .continuousTopToBottom ? .top : .leading
                    withTransaction(Transaction()) {
                        proxy.scrollTo(anchorID, anchor: anchor)
                    }
                    _ = model.consumeContinuousAnchorToRestoreID()
                }
                // 显式跳页（滑杆/跳页对话框）：滚到目标条目并对齐前缘
                // （对齐上游 v2.3.0：跳转必须精确落在页面上，而非仅改计数器）。
                .onChange(of: model.continuousJumpTargetItemID) { _, targetID in
                    guard let targetID else { return }
                    let anchor: UnitPoint = model.mode == .continuousTopToBottom ? .top : .leading
                    withTransaction(Transaction()) {
                        proxy.scrollTo(targetID, anchor: anchor)
                    }
                    _ = model.consumeContinuousJumpTargetItemID()
                }
            }
        }
    }

    @ViewBuilder
    private func items(viewport: CGSize) -> some View {
        // 页面间距（readerPageSpacing，0–50；对齐上游连续模式页间距设置）。
        let spacing = ReaderModel.continuousPageSpacing(model.setting("readerPageSpacing").doubleValue)
        if model.mode == .continuousTopToBottom {
            LazyVStack(spacing: spacing) { pageItems(viewport: viewport) }
        } else {
            LazyHStack(spacing: spacing) { pageItems(viewport: viewport) }
        }
    }

    @ViewBuilder
    private func pageItems(viewport: CGSize) -> some View {
        ForEach(model.continuousItems) { item in
            if item.isChapterHeader {
                Text(verbatim: item.chapterTitle ?? "")
                    .font(.headline)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .id(item.id)
                    .onAppear { model.onContinuousItemVisible(item) }
            } else {
                TranslatedReaderPageView(
                    cacheKey: model.translationCacheKey(for: item),
                    imageData: { await model.continuousImageData(for: item) },
                    scope: model.settingScope
                ) {
                    ContinuousPageView(model: model, item: item, onTapToolbar: onTapToolbar)
                }
                .frame(width: viewport.width, height: viewport.height)
                .onAppear { model.onContinuousItemVisible(item) }
            }
        }
        if model.isLoadingNextChapter {
            ProgressView("Loading next chapter...".tl)
                .padding(20)
        }
    }
}
