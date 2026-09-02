import SwiftUI
import VeneraKit

/// Continuous reader. Keeping this as a Lazy stack is important for long
/// chapters: only visible pages create translation tasks and image views.
struct ContinuousPager: View {
    @Bindable var model: ReaderModel
    var chapterTransition: Binding<String?> = .constant(nil)
    var onTapToolbar: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.mode == .continuousTopToBottom {
                    ScrollView(.vertical) { items }
                } else {
                    ScrollView(.horizontal) { items }
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
        }
    }

    @ViewBuilder
    private var items: some View {
        if model.mode == .continuousTopToBottom {
            LazyVStack(spacing: 0) { pageItems }
        } else {
            LazyHStack(spacing: 0) { pageItems }
        }
    }

    @ViewBuilder
    private var pageItems: some View {
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
                    imageData: { await model.continuousImageData(for: item) }
                ) {
                    ContinuousPageView(model: model, item: item, onTapToolbar: onTapToolbar)
                }
                .frame(
                    width: model.mode == .continuousTopToBottom ? UIScreen.main.bounds.width : UIScreen.main.bounds.width,
                    height: UIScreen.main.bounds.height
                )
                .onAppear { model.onContinuousItemVisible(item) }
            }
        }
        if model.isLoadingNextChapter {
            ProgressView("Loading next chapter...".tl)
                .padding(20)
        }
    }
}
