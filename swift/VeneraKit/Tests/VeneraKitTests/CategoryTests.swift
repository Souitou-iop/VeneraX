import XCTest
@testable import VeneraKit

/// 分类功能测试：复现 loadCategoryComics 的 JS 错误。
final class CategoryTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!
    private var source: ComicSource!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraCatTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        runtime = JSRuntime()
        try? ComicSourceManager.shared.remove("Komiic")
        let dispatcher = JSDispatcher()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.install(to: runtime)

        runtime.setHandler("http") { message, completion in
            let dataValue = message["data"]
            let body = dataValue as? String ?? ((try? JSON(any: dataValue ?? NSNull()).encodedString()) ?? "{}")
            let op = Self.extractOperationName(body)
            let payload: [String: Any]
            switch op {
            case "comicByCategories":
                payload = ["data": [op: [Self.comic(id: "1", title: "冒險漫畫一"), Self.comic(id: "2", title: "冒險漫畫二")]]]
            case "hotComics":
                payload = ["data": [op: [Self.comic(id: "3", title: "熱門漫畫")]]]
            default:
                completion(.success(["status": 404, "headers": [String: String](), "body": "{}", "error": NSNull()]))
                return nil
            }
            completion(.success([
                "status": 200,
                "headers": [String: String](),
                "body": (try? JSON(any: payload).encodedString()) ?? "{}",
                "error": NSNull(),
            ]))
            return nil
        }

        runtime.queue.sync {
            do {
                try runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
                let js = try String(contentsOfFile: Self.komiicScriptPath(), encoding: .utf8)
                let parser = ComicSourceParser()
                source = try parser.parse(js, filePath: "\(dataPath)/komiic.js", runtime: runtime)
                ComicSourceManager.shared.attach(runtime: runtime)
                ComicSourceManager.shared.registerForTesting(source)
            } catch {
                XCTFail("parse failed: \(error)")
            }
        }
    }

    override func tearDown() {
        ComicSourceManager.shared.resetForTesting()
        AppPaths.overrideDataPath = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    static func komiicScriptPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("komiicconfig.md").path
    }

    static func extractOperationName(_ body: String) -> String {
        JSON.decode(body)?["operationName"].stringValue ?? ""
    }

    static func comic(id: String, title: String) -> [String: Any] {
        [
            "id": id, "title": title,
            "imageUrl": "https://public.komiic.com/bd/\(id).jpg",
            "authors": [], "categories": [],
            "dateUpdated": "2024-06-01T10:00:00.000Z",
        ]
    }

    func testCategoryDataParsed() {
        let data = source.categoryData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.parts.first?.categories.count, 38)
        XCTAssertEqual(data?.parts.first?.param(at: 7), "8") // 冒險
        XCTAssertTrue(source.rankingAvailable)
    }

    func testCategoryComicsDefaults() {
        let defaults = source.categoryComicsOptionDefaults()
        XCTAssertEqual(defaults, ["DATE_UPDATED", ""])
    }

    func testLoadCategoryComics() async throws {
        let defaults = source.categoryComicsOptionDefaults()
        let result = try await source.loadCategoryComics(category: "冒險", param: "8", options: defaults, page: 1)
        XCTAssertEqual(result.comics.count, 2)
        XCTAssertEqual(result.comics.first?.title, "冒險漫畫一")
    }

    func testLoadRanking() async throws {
        let result = try await source.loadRanking(option: "MONTH_VIEWS-月", page: 1)
        XCTAssertEqual(result.comics.count, 1)
        XCTAssertEqual(result.comics.first?.title, "熱門漫畫")
    }
}
