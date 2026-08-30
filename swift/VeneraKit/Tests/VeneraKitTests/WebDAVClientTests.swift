import XCTest
@testable import VeneraKit

final class WebDAVClientTests: XCTestCase {
    func testRejectsNonHTTPWebDAVURLs() {
        XCTAssertThrowsError(try WebDAVClient(url: "file:///tmp/", username: "u", password: "p"))
        XCTAssertThrowsError(try WebDAVClient(url: "not a url", username: "u", password: "p"))
    }

    func testNormalizesValidWebDAVURL() throws {
        let client = try WebDAVClient(url: "https://example.com/dav", username: "u", password: "p")
        XCTAssertEqual(client.baseURL.absoluteString, "https://example.com/dav/")
    }
}
