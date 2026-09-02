import Foundation
import ImageIO
import Vision

/// A translated text block in Vision's normalized image coordinates.
/// Coordinates use a bottom-left origin, matching Vision; readers convert them
/// to the top-left coordinate system used by SwiftUI.
public struct ImageTranslationRegion: Codable, Hashable, Sendable {
    public let text: String
    public let translation: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(text: String, translation: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.translation = translation
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ImageTranslationResult: Codable, Hashable, Sendable {
    public let regions: [ImageTranslationRegion]
    public let imageWidth: Int
    public let imageHeight: Int

    public init(regions: [ImageTranslationRegion], imageWidth: Int, imageHeight: Int) {
        self.regions = regions
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

/// Minimal native image-translation pipeline: Vision OCR, a configured
/// OpenAI-compatible provider when present, otherwise Google's public
/// translate endpoint, then a disk-cached overlay result.
public actor ImageTranslationService {
    public static let shared = ImageTranslationService()

    public enum ServiceError: LocalizedError {
        case invalidImage
        case noText
        case translationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidImage: return "Unable to read image"
            case .noText: return "No text detected"
            case .translationFailed: return "Translation provider failed"
            }
        }
    }

    private struct OCRBlock: Sendable {
        let text: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private let cachePrefix = "swiftImageTranslation@1@"

    public func translate(imageData: Data, cacheKey: String, sourceLanguage: String = "auto", targetLanguage: String = "zh") async throws -> ImageTranslationResult {
        let key = cachePrefix + cacheKey + "@" + targetLanguage
        if let cached = CacheManager.shared.getData(key),
           let result = try? JSONDecoder().decode(ImageTranslationResult.self, from: cached) {
            return result
        }

        let (blocks, width, height) = try await Self.recognize(imageData: imageData, sourceLanguage: sourceLanguage)
        guard !blocks.isEmpty else { throw ServiceError.noText }
        let texts = blocks.map(\.text)
        let translations = try await translateTexts(texts, targetLanguage: targetLanguage)
        guard translations.count == blocks.count else { throw ServiceError.translationFailed }
        let regions = zip(blocks, translations).map { block, translation in
            ImageTranslationRegion(
                text: block.text,
                translation: translation,
                x: block.x,
                y: block.y,
                width: block.width,
                height: block.height
            )
        }
        let result = ImageTranslationResult(regions: regions, imageWidth: width, imageHeight: height)
        if let data = try? JSONEncoder().encode(result) {
            CacheManager.shared.set(key, data, type: "image-translation")
        }
        return result
    }

    private func translateTexts(_ texts: [String], targetLanguage: String) async throws -> [String] {
        let endpoint = (AppData.shared.settings["imageTranslationLlmUrl"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty {
            return try await Self.translateWithOpenAI(
                texts,
                endpoint: endpoint,
                apiKey: AppData.shared.settings["imageTranslationLlmKey"].stringValue ?? "",
                model: AppData.shared.settings["imageTranslationLlmModel"].stringValue ?? "",
                targetLanguage: targetLanguage
            )
        }
        return try await Self.translateWithGoogle(texts, targetLanguage: targetLanguage)
    }

    private static func recognize(imageData: Data, sourceLanguage: String) async throws -> ([OCRBlock], Int, Int) {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ServiceError.invalidImage
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.012
            request.recognitionLanguages = recognitionLanguages(for: sourceLanguage)
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            let blocks = observations.compactMap { observation -> OCRBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 1, text.count <= 160 else { return nil }
                let box = observation.boundingBox
                return OCRBlock(text: text, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
            return (blocks, image.width, image.height)
        }.value
    }

    private static func recognitionLanguages(for sourceLanguage: String) -> [String] {
        switch sourceLanguage {
        case "ja": return ["ja-JP"]
        case "zh": return ["zh-Hans", "zh-Hant"]
        case "en": return ["en-US"]
        case "ko": return ["ko-KR"]
        default: return ["ja-JP", "zh-Hans", "zh-Hant", "en-US", "ko-KR"]
        }
    }

    private static func translateWithGoogle(_ texts: [String], targetLanguage: String) async throws -> [String] {
        let target = targetLanguage == "zh-TW" ? "zh-TW" : (targetLanguage == "zh" ? "zh-CN" : targetLanguage)
        var results: [String] = []
        for text in texts {
            var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
            components.queryItems = [
                URLQueryItem(name: "client", value: "gtx"),
                URLQueryItem(name: "sl", value: "auto"),
                URLQueryItem(name: "tl", value: target),
                URLQueryItem(name: "dt", value: "t"),
                URLQueryItem(name: "q", value: text)
            ]
            guard let url = components.url?.absoluteString else { throw ServiceError.translationFailed }
            let response = await HTTPClient.shared.request(method: "GET", url: url)
            guard let status = response.status, (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: response.body) as? [Any],
                  let segments = json.first as? [[Any]] else {
                throw ServiceError.translationFailed
            }
            let translated = segments.compactMap { $0.first as? String }.joined()
            guard !translated.isEmpty else { throw ServiceError.translationFailed }
            results.append(translated)
        }
        return results
    }

    private static func translateWithOpenAI(_ texts: [String], endpoint: String, apiKey: String, model: String, targetLanguage: String) async throws -> [String] {
        let prompt = "Translate each line into \(targetLanguage). Return only a JSON array of strings in the same order, with no markdown.\n" + texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let payload: [String: Any] = [
            "model": model.isEmpty ? "gpt-4o-mini" : model,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { throw ServiceError.translationFailed }
        var headers = ["Content-Type": "application/json"]
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let response = await HTTPClient.shared.request(method: "POST", url: endpoint, headers: headers, body: body)
        guard let status = response.status, (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw ServiceError.translationFailed }
        let cleaned = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let values = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String], values.count == texts.count else {
            throw ServiceError.translationFailed
        }
        return values
    }
}
