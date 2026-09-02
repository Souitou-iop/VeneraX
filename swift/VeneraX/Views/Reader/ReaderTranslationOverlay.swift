import SwiftUI
import UIKit
import VeneraKit

/// Native OCR translation presentation for one reader page. The source image is
/// intentionally kept intact in this MVP; translated text is placed over the
/// detected Vision rectangles so enabling the setting has an observable result.
struct TranslatedReaderPageView<Content: View>: View {
    let cacheKey: String
    let imageData: () async -> Data?
    @ViewBuilder let content: () -> Content

    @State private var result: ImageTranslationResult?
    @State private var failed = false

    init(cacheKey: String, imageData: @escaping () async -> Data?, @ViewBuilder content: @escaping () -> Content) {
        self.cacheKey = cacheKey
        self.imageData = imageData
        self.content = content
    }

    var body: some View {
        ZStack {
            content()
            if let result, !result.regions.isEmpty {
                GeometryReader { proxy in
                    let imageRect = aspectFitRect(
                        imageWidth: CGFloat(result.imageWidth),
                        imageHeight: CGFloat(result.imageHeight),
                        in: proxy.size
                    )
                    ForEach(Array(result.regions.enumerated()), id: \.offset) { _, region in
                        let rect = CGRect(
                            x: imageRect.minX + region.x * imageRect.width,
                            y: imageRect.minY + (1 - region.y - region.height) * imageRect.height,
                            width: max(24, region.width * imageRect.width),
                            height: max(20, region.height * imageRect.height)
                        )
                        Text(verbatim: region.translation)
                            .font(.system(size: max(11, min(22, rect.height * 0.72)), weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .minimumScaleFactor(0.55)
                            .padding(3)
                            .frame(width: rect.width, height: rect.height)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .allowsHitTesting(false)
            }
            if failed {
                Label("Image translation unavailable".tl, systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .task(id: cacheKey) {
            guard AppData.shared.settings["enableImageTranslation"].boolValue ?? false else {
                result = nil
                failed = false
                return
            }
            guard let data = await imageData(), !Task.isCancelled else { return }
            do {
                result = try await ImageTranslationService.shared.translate(
                    imageData: data,
                    cacheKey: cacheKey,
                    sourceLanguage: AppData.shared.settings["imageTranslationSource"].stringValue ?? "auto",
                    targetLanguage: AppData.shared.settings["imageTranslationTarget"].stringValue ?? "zh"
                )
                failed = false
            } catch {
                result = nil
                failed = true
            }
        }
    }

    private func aspectFitRect(imageWidth: CGFloat, imageHeight: CGFloat, in size: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / imageWidth, size.height / imageHeight)
        let fitted = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
