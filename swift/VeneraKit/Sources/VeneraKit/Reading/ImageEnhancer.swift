import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreImage)
import CoreImage
import Metal
#endif

/// 基于 CoreImage / Metal 硬件加速的漫画画质增强滤镜管线（对齐原版 image_enhance_shader.dart）。
/// 支持自适应锐化、清晰度、对比度拉伸与色彩鲜艳度增强。
public final class ImageEnhancer: @unchecked Sendable {
    public static let shared = ImageEnhancer()

    /// Immutable snapshot used by background image decoding. Reading settings is
    /// kept on the caller's actor; Core Image work can then run off the UI actor.
    public struct Parameters: Sendable {
        public let enabled: Bool
        public let strength: Double
        public let clarity: Double
        public let contrast: Double
        public let vibrance: Double

        public init(enabled: Bool, strength: Double, clarity: Double, contrast: Double, vibrance: Double) {
            self.enabled = enabled
            self.strength = strength
            self.clarity = clarity
            self.contrast = contrast
            self.vibrance = vibrance
        }
    }

    #if canImport(CoreImage)
    private let context: CIContext
    #endif

    private init() {
        #if canImport(CoreImage)
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: metalDevice)
        } else {
            self.context = CIContext()
        }
        #endif
    }

    #if canImport(UIKit) && canImport(CoreImage)
    /// 读取一次设置并返回不可变快照，避免后台图像任务反复触碰共享设置。
    public func currentParameters() -> Parameters {
        Parameters(
            enabled: AppData.shared.settings["enableReaderImageEnhance"].boolValue ?? false,
            strength: AppData.shared.settings["readerImageEnhanceStrength"].doubleValue ?? 0.5,
            clarity: AppData.shared.settings["readerImageEnhanceClarity"].doubleValue ?? 0.0,
            contrast: AppData.shared.settings["readerImageEnhanceContrast"].doubleValue ?? 0.0,
            vibrance: AppData.shared.settings["readerImageEnhanceVibrance"].doubleValue ?? 0.0
        )
    }

    /// 对漫画单页应用画质增强滤镜。设置只在调用方 actor 上读取一次。
    public func enhance(_ image: UIImage) -> UIImage {
        enhance(image, parameters: currentParameters())
    }

    /// 使用不可变参数执行滤镜；适合在 detached task 中调用。
    public func enhance(_ image: UIImage, parameters: Parameters) -> UIImage {
        guard parameters.enabled else { return image }
        let strength = parameters.strength
        let clarity = parameters.clarity
        let contrast = parameters.contrast
        let vibrance = parameters.vibrance
        guard strength > 0 || clarity > 0 || contrast > 0 || vibrance > 0 else { return image }
        guard let cgImage = image.cgImage else { return image }

        var ciImage = CIImage(cgImage: cgImage)

        // 1. 锐化 (CISharpenLuminance)
        if strength > 0 {
            if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
                sharpenFilter.setValue(ciImage, forKey: kCIInputImageKey)
                sharpenFilter.setValue(min(strength * 0.4, 2.0), forKey: "inputSharpness")
                if let output = sharpenFilter.outputImage {
                    ciImage = output
                }
            }
        }

        // 2. 清晰度 (CIUnsharpMask)
        if clarity > 0 {
            if let unsharpFilter = CIFilter(name: "CIUnsharpMask") {
                unsharpFilter.setValue(ciImage, forKey: kCIInputImageKey)
                unsharpFilter.setValue(2.5, forKey: "inputRadius")
                unsharpFilter.setValue(clarity * 0.8, forKey: "inputIntensity")
                if let output = unsharpFilter.outputImage {
                    ciImage = output
                }
            }
        }

        // 3. 对比度与色彩鲜艳度 (CIColorControls)
        if contrast > 0 || vibrance > 0 {
            if let colorFilter = CIFilter(name: "CIColorControls") {
                colorFilter.setValue(ciImage, forKey: kCIInputImageKey)
                if contrast > 0 {
                    colorFilter.setValue(1.0 + contrast * 0.35, forKey: kCIInputContrastKey)
                }
                if vibrance > 0 {
                    colorFilter.setValue(1.0 + vibrance * 0.4, forKey: kCIInputSaturationKey)
                }
                if let output = colorFilter.outputImage {
                    ciImage = output
                }
            }
        }

        guard let outputCGImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return image
        }
        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
    #endif
}
