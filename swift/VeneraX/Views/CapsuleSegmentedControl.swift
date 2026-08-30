import SwiftUI

/// 原生胶囊长条滑块组件（Capsule Segmented Slider）。
/// 外层为浅灰圆角轨道（tertiarySystemFill），内层选定项为浮起白色胶囊滑块（带微阴影与 spring 平滑流动动画）。
struct CapsuleSegmentedControl<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let isSelected = selection == item
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(uiColor: .systemBackground))
                                    .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "CapsulePill", in: animation)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// 支持横向滚动的胶囊长条滑块（用于多源/多分区的发现页）。
struct ScrollableCapsuleSegmentedControl<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T.ID
    let title: (T) -> String
    var badge: ((T) -> String?)? = nil
    @Namespace private var animation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        let isSelected = selection == item.id
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                selection = item.id
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if let badgeText = badge?(item) {
                                    Text(badgeText)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                                            in: Capsule()
                                        )
                                }
                                Text(title(item))
                                    .font(.subheadline)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(Color(uiColor: .systemBackground))
                                        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                                        )
                                        .matchedGeometryEffect(id: "ScrollablePill", in: animation)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(3)
            }
        }
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}
