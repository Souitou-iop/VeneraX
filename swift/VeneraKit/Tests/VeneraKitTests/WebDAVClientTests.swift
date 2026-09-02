import XCTest
@testable import VeneraKit

final class WebDAVClientTests: XCTestCase {
    func testWebDAVPathPreservesNestedBasePathAndUnicodeSegments() throws {
        let client = try WebDAVClient(
            url: "https://example.com/webdav/venerax/",
            username: "u",
            password: "p"
        )
        let url = try client.url(for: "/漫画 集合/50% OFF/#1.jpg")
        XCTAssertEqual(url.absoluteString, "https://example.com/webdav/venerax/%E6%BC%AB%E7%94%BB%20%E9%9B%86%E5%90%88/50%25%20OFF/%231.jpg")
        XCTAssertEqual(WebDAVPath.join("/webdav/", "/venerax/", "漫画 集合"), "webdav/venerax/漫画 集合")
        XCTAssertEqual(WebDAVPath.normalizedDirectory("/webdav/venerax"), "/webdav/venerax/")
    }

    func testWebDAVPathRejectsTraversalForRequests() throws {
        let client = try WebDAVClient(url: "https://example.com/webdav/", username: "u", password: "p")
        XCTAssertThrowsError(try client.url(for: "venerax/../other"))
        XCTAssertThrowsError(try client.url(for: "./comic"))
    }

    func testWebDAVPathDoesNotTreatArchiveAsCollectionByNameAlone() {
        let archive = WebDAVResource(name: "Comic.cbz", href: "/Comic.cbz", isCollection: false)
        let folder = WebDAVResource(name: "Comic.cbz", href: "/Comic.cbz/", isCollection: true)
        XCTAssertFalse(archive.isCollection)
        XCTAssertTrue(folder.isCollection)
    }

    func testRejectsNonHTTPWebDAVURLs() {
        XCTAssertThrowsError(try WebDAVClient(url: "file:///tmp/", username: "u", password: "p"))
        XCTAssertThrowsError(try WebDAVClient(url: "not a url", username: "u", password: "p"))
    }

    func testNormalizesValidWebDAVURL() throws {
        let client = try WebDAVClient(url: "https://example.com/dav", username: "u", password: "p")
        XCTAssertEqual(client.baseURL.absoluteString, "https://example.com/dav/")
    }
}

private final class MockWebDAVURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.resourceUnavailable) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension WebDAVClientTests {
    func testPropfindParserReturnsNamesAndCollectionKinds() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebDAVURLProtocol.self]
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/webdav/venerax/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/webdav/venerax/漫画%20A/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/webdav/venerax/漫画%20A.cbz</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """
        MockWebDAVURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/webdav/venerax/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dTpw")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!,
                Data(xml.utf8)
            )
        }
        defer { MockWebDAVURLProtocol.handler = nil }

        let client = try WebDAVClient(
            url: "https://example.com/webdav/venerax",
            username: "u",
            password: "p",
            session: URLSession(configuration: configuration)
        )
        let resources = try await client.listResources("/")
        XCTAssertEqual(resources, [
            WebDAVResource(name: "漫画 A", href: "/webdav/venerax/漫画%20A/", isCollection: true),
            WebDAVResource(name: "漫画 A.cbz", href: "/webdav/venerax/漫画%20A.cbz", isCollection: false),
        ])
        let names = try await client.list("/")
        XCTAssertEqual(names, ["漫画 A", "漫画 A.cbz"])
    }

    func testRetryHandlesTransientServerFailureThenSucceeds() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebDAVURLProtocol.self]
        var attempts = 0
        MockWebDAVURLProtocol.handler = { request in
            attempts += 1
            let status = attempts == 1 ? 503 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data("ok".utf8))
        }
        defer { MockWebDAVURLProtocol.handler = nil }
        let client = try WebDAVClient(
            url: "https://example.com/dav",
            username: "u",
            password: "p",
            session: URLSession(configuration: configuration)
        )
        let body = try await client.get("漫画 A/page 1.jpg")
        XCTAssertEqual(body, Data("ok".utf8))
        XCTAssertEqual(attempts, 2)
    }
}

extension WebDAVClientTests {
    func testMkcolAndPutUseBasePathAuthAndAcceptWebDAVSuccessCodes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebDAVURLProtocol.self]
        var requests: [(String, String, String?)] = []
        MockWebDAVURLProtocol.handler = { request in
            requests.append((request.httpMethod ?? "", request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "Authorization")))
            let status = request.httpMethod == "MKCOL" ? 405 : 201
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockWebDAVURLProtocol.handler = nil }
        let client = try WebDAVClient(
            url: "https://example.com/webdav/venerax",
            username: "alice",
            password: "secret",
            session: URLSession(configuration: configuration)
        )
        try await client.makeDirectory("漫画 A/第 1 话")
        try await client.put("漫画 A/第 1 话/001.jpg", Data([1, 2, 3]))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].0, "MKCOL")
        XCTAssertEqual(requests[0].1, "https://example.com/webdav/venerax/%E6%BC%AB%E7%94%BB%20A/%E7%AC%AC%201%20%E8%AF%9D")
        XCTAssertEqual(requests[1].0, "PUT")
        XCTAssertEqual(requests[1].1, "https://example.com/webdav/venerax/%E6%BC%AB%E7%94%BB%20A/%E7%AC%AC%201%20%E8%AF%9D/001.jpg")
        XCTAssertEqual(requests[0].2, "Basic YWxpY2U6c2VjcmV0")
    }
}
