import SwiftUI
import VeneraKit

#if canImport(UIKit)
import UIKit
#endif

/// 翻页编排：点区/滑块的翻页入口。对齐原版 toNextPage → toNextChapter
/// 链条与 Mihon 的 pageTransitions / chapter transition 行为：
/// - 页内翻页：按 enablePageAnimation 以滑动动画过渡 + 轻触觉反馈
/// - 页末：自动切下一话（章节过渡屏 + 中触觉反馈），首页同理切上一话末页
/// - 无相邻章节：到底提示
enum ReaderPageTurning {
    /// 是否启用翻页动画（原版设置键 enablePageAnimation）。
    static var animationEnabled: Bool {
        AppData.shared.settings["enablePageAnimation"].boolValue ?? true
    }

    /// 页内翻页（带动画与触觉）。
    @MainActor
    static func turn(_ model: ReaderModel, to index: Int) {
        guard model.pages.indices.contains(index) else { return }
        let animated = animationEnabled
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                model.setIndex(index)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.setIndex(index)
            }
        }
        haptic(.light)
        Task { await model.afterIndexChange(index) }
    }

    /// 下一页（含页末切下一话）。返回是否成功。
    @MainActor
    static func goNext(_ model: ReaderModel, chapterTransition: Binding<String?>) async -> Bool {
        if model.currentIndex < model.pages.count - 1 {
            turn(model, to: model.currentIndex + 1)
            return true
        }
        return await switchChapter(model, delta: +1, toEnd: false, chapterTransition: chapterTransition)
    }

    /// 上一页（含首页切上一话末页）。
    @MainActor
    static func goPrevious(_ model: ReaderModel, chapterTransition: Binding<String?>) async -> Bool {
        if model.currentIndex > 0 {
            turn(model, to: model.currentIndex - 1)
            return true
        }
        return await switchChapter(model, delta: -1, toEnd: true, chapterTransition: chapterTransition)
    }

    /// 相对切换章节：展示章节过渡屏（Mihon chapter transition 模式）。
    @MainActor
    private static func switchChapter(
        _ model: ReaderModel,
        delta: Int,
        toEnd: Bool,
        chapterTransition: Binding<String?>
    ) async -> Bool {
        guard model.hasChapter(offset: delta) else {
            chapterTransition.wrappedValue = delta > 0 ? "已是最后一话".tl : "已是第一话".tl
            haptic(.warning)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                chapterTransition.wrappedValue = nil
            }
            return false
        }
        let target = model.currentEpIndex + delta
        let title = model.chapterTitle(at: target) ?? String(target + 1)
        let label = (delta > 0 ? "下一话".tl : "上一话".tl) + " · " + title
        chapterTransition.wrappedValue = label
        haptic(.medium)
        await model.switchChapter(to: target)
        if toEnd {
            model.setIndex(max(model.pages.count - 1, 0))
        }
        Task { await model.afterIndexChange(model.currentIndex) }
        try? await Task.sleep(for: .milliseconds(550))
        withAnimation(.easeOut(duration: 0.25)) {
            chapterTransition.wrappedValue = nil
        }
        return true
    }

    // MARK: - 触觉反馈

    enum HapticIntensity {
        case light, medium, warning
    }

    @MainActor
    static func haptic(_ intensity: HapticIntensity) {
        #if canImport(UIKit)
        switch intensity {
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        #endif
    }
}

/// 章节过渡屏（淡入淡出，展示「下一话 · 标题」）。
struct ChapterTransitionOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 10) {
                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                ProgressView()
                    .tint(.white)
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
