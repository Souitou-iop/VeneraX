import Foundation
import Testing
@testable import VeneraKit

struct ImageTranslationTests {
    @Test func translationRegionsRoundTripThroughCacheFormat() throws {
        let original = ImageTranslationResult(
            regions: [ImageTranslationRegion(text: "こんにちは", translation: "你好", x: 0.1, y: 0.2, width: 0.3, height: 0.1)],
            imageWidth: 1000,
            imageHeight: 1500
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageTranslationResult.self, from: data)
        #expect(decoded == original)
    }
}
