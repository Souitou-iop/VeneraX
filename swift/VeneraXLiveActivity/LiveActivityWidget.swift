import ActivityKit
import SwiftUI
import WidgetKit
import UIKit

@main
struct VeneraXLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        VeneraTaskLiveActivity()
    }
}

struct VeneraTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VeneraTaskActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.055, green: 0.055, blue: 0.075))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "venera://tasks"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CoverView(state: context.state, kind: context.attributes.kind, size: .init(width: 38, height: 50))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ProgressRing(state: context.state, kind: context.attributes.kind, isStale: context.isStale, diameter: 42, lineWidth: 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.activityTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(accent(context.attributes.kind))
                        Text(context.state.title)
                            .privacySensitive()
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 7) {
                        ProgressView(value: context.state.isIndeterminate ? nil : context.state.clampedProgress)
                            .tint(accent(context.attributes.kind))
                        HStack(spacing: 8) {
                            Text(phaseText(context.state, isStale: context.isStale))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(progressText(context.state))
                                .monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                CompactProgressMark(state: context.state, kind: context.attributes.kind, isStale: context.isStale)
            } compactTrailing: {
                Text(compactText(context.state, isStale: context.isStale))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(accent(context.attributes.kind))
            } minimal: {
                CompactProgressMark(state: context.state, kind: context.attributes.kind, isStale: context.isStale)
            }
            .widgetURL(URL(string: "venera://tasks"))
            .keylineTint(accent(context.attributes.kind))
        }
    }
}

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<VeneraTaskActivityAttributes>

    var body: some View {
        HStack(spacing: 13) {
            CoverView(state: context.state, kind: context.attributes.kind, size: .init(width: 48, height: 64))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: context.attributes.kind.symbol)
                    Text(context.state.activityTitle)
                    if context.state.queueCount > 1 {
                        Text("+\(context.state.queueCount - 1)")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent(context.attributes.kind))

                Text(context.state.title)
                            .privacySensitive()
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(phaseText(context.state, isStale: context.isStale))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)

                ProgressView(value: context.state.isIndeterminate ? nil : context.state.clampedProgress)
                    .tint(accent(context.attributes.kind))
            }

            ProgressRing(state: context.state, kind: context.attributes.kind, isStale: context.isStale, diameter: 48, lineWidth: 5)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(context.state.activityTitle), \(context.state.title), \(phaseText(context.state, isStale: context.isStale)), \(progressText(context.state))")
    }
}

private struct CoverView: View {
    let state: VeneraTaskActivityAttributes.ContentState
    let kind: VeneraTaskActivityAttributes.Kind
    let size: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent(kind).opacity(0.88), accent(kind).opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let url = VeneraTaskActivityAttributes.coverFile(state.coverURL),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().privacySensitive()
            } else {
                fallback
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
    }

    private var fallback: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: min(size.width, size.height) * 0.35, weight: .semibold))
            .foregroundStyle(.white)
    }
}

private struct ProgressRing: View {
    let state: VeneraTaskActivityAttributes.ContentState
    let kind: VeneraTaskActivityAttributes.Kind
    let isStale: Bool
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: state.clampedProgress)
                .stroke(accent(kind), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isStale || state.statusSymbol != nil {
                Image(systemName: isStale ? "clock.badge.exclamationmark" : state.statusSymbol!)
                    .font(.system(size: diameter * 0.3, weight: .bold))
                    .foregroundStyle(isStale || state.status == .failed ? .orange : .white)
            } else {
                Text(state.isIndeterminate ? "…" : "\(state.percent)")
                    .font(.system(size: diameter * 0.27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct CompactProgressMark: View {
    let state: VeneraTaskActivityAttributes.ContentState
    let kind: VeneraTaskActivityAttributes.Kind
    let isStale: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: state.clampedProgress)
                .stroke(accent(kind), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: isStale ? "clock.badge.exclamationmark" : (state.statusSymbol ?? kind.symbol))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(accent(kind))
        }
        .frame(width: 20, height: 20)
    }
}

private func accent(_ kind: VeneraTaskActivityAttributes.Kind) -> Color {
    switch kind {
    case .preTranslation: Color(red: 0.67, green: 0.48, blue: 1.0)
    case .download: Color(red: 0.25, green: 0.72, blue: 1.0)
    }
}

private func progressText(_ state: VeneraTaskActivityAttributes.ContentState) -> String {
    guard state.total > 0 else { return NSLocalizedString("Preparing", comment: "") }
    return "\(state.current)/\(state.total) · \(state.percent)%"
}

private func compactText(_ state: VeneraTaskActivityAttributes.ContentState, isStale: Bool) -> String {
    if isStale { return "!" }
    switch state.status {
    case .paused: return "Ⅱ"
    case .failed: return "!"
    case .completed: return "✓"
    case .cancelled: return "×"
    case .running: return state.isIndeterminate ? "…" : "\(state.percent)%"
    }
}

private func phaseText(_ state: VeneraTaskActivityAttributes.ContentState, isStale: Bool) -> String {
    if isStale { return NSLocalizedString("Progress not updated. Open app to check.", comment: "") }
    if let failed = state.failedCount, failed > 0 {
        return "\(state.phase) · \(failed) \(NSLocalizedString("pages failed", comment: ""))"
    }
    return state.phase.isEmpty ? state.subtitle : state.phase
}
