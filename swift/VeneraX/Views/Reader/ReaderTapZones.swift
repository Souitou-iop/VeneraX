import SwiftUI
import VeneraKit

/// 点区手势（对齐原版 enableTapToTurnPages + Mihon 默认方案）：
/// 画廊模式——左/右三分之一翻页（方向感知，可反转），中间呼出工具栏；
/// 连续模式——任意单击切换工具栏（避免长条滚动时误触翻页）。
/// 页末自动切相邻章节（ReaderPageTurning 编排）。
struct ReaderTapZones: ViewModifier {
    @Bindable var model: ReaderModel
    @Binding var chapterTransition: String?
    let onTapToolbar: () -> Void
    var isEnabled: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if model.mode.isContinuous {
            content
                .onTapGesture { onTapToolbar() }
        } else {
            // 画廊模式的点击由 ZoomableScrollView 的 UIKit 手势转发
            // （见 ReaderPageView），此处仅连续模式处理单击。
            content
        }
    }

    /// UIKit 层点击入口：xRatio 为归一化横向位置。
    func handleTap(xRatio: CGFloat) {
        let enableTapTurn = AppData.shared.settings["enableTapToTurnPages"].boolValue ?? true
        if !enableTapTurn {
            onTapToolbar()
            return
        }
        var turnNext: Bool
        if xRatio < 1 / 3 {
            turnNext = model.mode.isRightToLeft
        } else if xRatio > 2 / 3 {
            turnNext = !model.mode.isRightToLeft
        } else {
            onTapToolbar()
            return
        }
        if AppData.shared.settings["reverseTapToTurnPages"].boolValue ?? false {
            turnNext.toggle()
        }
        Task { @MainActor in
            if turnNext {
                await ReaderPageTurning.goNext(model, chapterTransition: $chapterTransition)
            } else {
                await ReaderPageTurning.goPrevious(model, chapterTransition: $chapterTransition)
            }
        }
    }
}
