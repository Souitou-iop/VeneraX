import XCTest
@testable import VeneraKit

/// M1 验收用例：Komiic 源（komiicconfig.md v1.1.5）端到端。
/// http 处理器替换为 mock，验证 JS→Swift→JS 全链路与 GraphQL 解析。
final class KomiicSourceTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!
    private var source: ComicSource!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraKomiicTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        runtime = JSRuntime()
        // 测试进程共享静态管理器；先清理上次注册的 Komiic
        try? ComicSourceManager.shared.remove("Komiic")
        let dispatcher = JSDispatcher()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.install(to: runtime)

        // mock http：按 operationName 返回 canned GraphQL 响应
        runtime.setHandler("http") { message, completion in
            let dataValue = message["data"]
            let body: String
            if let text = dataValue as? String {
                body = text
            } else if let json = JSON(any: dataValue ?? NSNull()).objectValue {
                body = (try? JSON(any: dataValue ?? NSNull()).encodedString()) ?? "{}"
            } else {
                body = "{}"
            }
            let operationName = Self.extractOperationName(body)
            FileHandle(forWritingAtPath: "/tmp/mock_debug.txt")?.seekToEndOfFile()
            let line = "MOCK op=\(operationName) status-pending body=\(body.prefix(80))\n"
            FileHandle(forWritingAtPath: "/tmp/mock_debug.txt")?.write(line.data(using: .utf8)!)
            let payload: [String: Any]
            switch operationName {
            case "recentUpdate", "comicByCategories", "hotComics":
                payload = [
                    "data": [
                        operationName: [Self.comicJSON(id: "30055", title: "葬送的芙莉蓮"), Self.comicJSON(id: "29851", title: "鏈鋸人")],
                    ],
                ]
            case "searchComicAndAuthorQuery":
                // 真实 API：data.searchComicsAndAuthors.{comics, authors}
                payload = [
                    "data": [
                        "searchComicsAndAuthors": [
                            "comics": [Self.comicJSON(id: "30055", title: "葬送的芙莉蓮"), Self.comicJSON(id: "29851", title: "鏈鋸人")],
                            "authors": [],
                        ],
                    ],
                ]
            case "recommendComicById":
                payload = ["data": ["recommendComicById": ["100", "200"]]]
            case "comicByIds":
                payload = [
                    "data": [
                        "comicByIds": [
                            Self.detailJSON(id: "100", title: "相關作品一"),
                            Self.detailJSON(id: "200", title: "相關作品二"),
                            Self.detailJSON(id: "30055", title: "葬送的芙莉蓮"),
                        ],
                    ],
                ]
            case "chapterByComicId":
                payload = [
                    "data": [
                        "chaptersByComicId": [
                            ["id": "vol1", "serial": "1", "type": "book", "dateUpdated": "2024-01-01"],
                            ["id": "ch1", "serial": "1", "type": "chapter", "dateUpdated": "2024-01-02"],
                            ["id": "ch2", "serial": "2", "type": "chapter", "dateUpdated": "2024-01-03"],
                        ],
                    ],
                ]
            case "imageTicketsByChapterId":
                payload = [
                    "data": [
                        "imageTicketsByChapterId": [
                            ["url": "https://img.komiic.com/001.jpg", "ticket": "t1", "kid": "k1", "width": 800, "height": 1200],
                            ["url": "https://img.komiic.com/002.jpg", "ticket": "t2", "kid": "k2", "width": 800, "height": 1200],
                        ],
                    ],
                ]
            default:
                let line3 = "MOCK 404 op=\(operationName)\n"
                FileHandle(forWritingAtPath: "/tmp/mock_debug.txt")?.write(line3.data(using: .utf8)!)
                completion(.success([
                    "status": 404,
                    "headers": [String: String](),
                    "body": "{}",
                    "error": NSNull(),
                ]))
                return nil
            }
            let bodyText = (try? JSON(any: payload).encodedString()) ?? "{}"
            let line2 = "MOCK complete op=\(operationName) respLen=\(bodyText.count)\n"
            FileHandle(forWritingAtPath: "/tmp/mock_debug.txt")?.write(line2.data(using: .utf8)!)
            completion(.success([
                "status": 200,
                "headers": [String: String](),
                "body": bodyText,
                "error": NSNull(),
            ]))
            return nil
        }

        // 加载 init.js 与源脚本
        runtime.queue.sync {
            do {
                try runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
                let parser = ComicSourceParser()
                let js = try String(contentsOfFile: Self.komiicScriptPath(), encoding: .utf8)
                source = try parser.parse(js, filePath: "\(dataPath)/komiic.js", runtime: runtime)
                ComicSourceManager.shared.attach(runtime: runtime)
                // load_setting 桥接需要源在管理器注册表中
                _ = ComicSourceManager.shared.registerForTesting(source)
            } catch {
                XCTFail("Failed to parse Komiic source: \(error)")
            }
        }
    }

    override func tearDown() {
        // 释放 JSContext 与源引用，否则 XCTest MemoryChecker 会等待
        // 这些跨测试存活的宿主对象而超时卡死。
        ComicSourceManager.shared.resetForTesting()
        runtime = nil
        source = nil
        AppPaths.overrideDataPath = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    static func komiicScriptPath() -> String {
        // Tests/KomeriKitTests/xxx.swift → 仓库根
        let url = URL(fileURLWithPath: #filePath)
        let repoRoot = url
            .deletingLastPathComponent() // 本文件所在目录 VeneraKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // VeneraKit
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // 仓库根
        return repoRoot.appendingPathComponent("komiicconfig.md").path
    }

    static func extractOperationName(_ body: String) -> String {
        guard let json = JSON.decode(body) else { return "" }
        return json["operationName"].stringValue ?? ""
    }

    static func comicJSON(id: String, title: String) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "imageUrl": "https://public.komiic.com/bd/\(id).jpg",
            "authors": [["id": "a1", "name": "山田鐘人"]],
            "categories": [["id": "c1", "name": "奇幻"], ["id": "c2", "name": "冒險"]],
            "dateUpdated": "2024-06-01T10:00:00.000Z",
            "status": "ongoing",
        ]
    }

    static func detailJSON(id: String, title: String) -> [String: Any] {
        comicJSON(id: id, title: title)
    }

    // MARK: - 测试

    func testSourceParsed() {
        XCTAssertEqual(source?.name, "Komiic")
        XCTAssertEqual(source?.key, "Komiic")
        XCTAssertEqual(source?.version, "1.1.5")
        // 设置表单（domain 下拉）
        XCTAssertNotNil(source?.settings["domain"])
        XCTAssertEqual(source?.settings["domain"]?.type, .select)
        // 探索页（recentUpdate）
        XCTAssertEqual(source?.explorePages.first?.title, "Komiic")
        XCTAssertEqual(source?.explorePages.first?.type, .multiPageComicList)
        // 能力
        XCTAssertTrue(source?.searchAvailable ?? false)
        XCTAssertTrue(source?.favoriteDataAvailable ?? false)
        XCTAssertTrue(source?.multiFolder ?? false)
        // int key 已登记
        XCTAssertNotNil(SourcePlatformResolver.shared.resolve(ComicID.forSource("Komiic")))
    }

    func testExplorePageLoadsComics() async throws {
        let result = try await source.loadExplorePage(0, page: 1)
        XCTAssertEqual(result.comics.count, 2)
        let comic = try XCTUnwrap(result.comics.first)
        XCTAssertEqual(comic.id, "30055")
        XCTAssertEqual(comic.title, "葬送的芙莉蓮")
        XCTAssertEqual(comic.sourceKey, "Komiic")
        XCTAssertEqual(comic.tags, ["奇幻", "冒險"])
        XCTAssertEqual(comic.subtitle, "山田鐘人")
        // 封面域名修复 public.komiic.com → public.komiic.cc
        XCTAssertTrue(comic.cover.contains("komiic.cc"))
    }

    func testSearchLoadsComics() async throws {
        let result = try await source.search(keyword: "芙莉蓮", page: 1, options: [:])
        XCTAssertEqual(result.comics.count, 2)
        XCTAssertEqual(result.comics[0].title, "葬送的芙莉蓮")
    }

    func testLoadInfoWithGroupedChapters() async throws {
        let details = try await source.loadComicInfo(id: "30055")
        XCTAssertEqual(details.title, "葬送的芙莉蓮")
        XCTAssertEqual(details.tags["作者"], ["山田鐘人"])
        XCTAssertEqual(details.tags["标签"], ["奇幻", "冒險"])
        let chapters = try XCTUnwrap(details.chapters)
        XCTAssertFalse(chapters.isEmpty)
        // 分组章节：卷 + 章
        let ids = chapters.ids
        XCTAssertTrue(ids.contains("vol1"))
        XCTAssertTrue(ids.contains("ch1"))
        XCTAssertTrue(ids.contains("ch2"))
    }

    func testChapterOrderPreserved() async throws {
        // 回归：Swift 字典不保序曾致章节列表乱序（且每次启动随机）。
        // 章节顺序必须 = 源构造序（JS Map 插入序：vol1 → ch1 → ch2）。
        let details = try await source.loadComicInfo(id: "30055")
        let chapters = try XCTUnwrap(details.chapters)
        XCTAssertEqual(chapters.ids, ["vol1", "ch1", "ch2"])
        XCTAssertEqual(chapters.titles, ["卷1", "1", "2"])
    }

    func testComicChaptersFromEntriesMixed() {
        // 混合结构：平铺项包装进「默认」组（追加在尾，对齐原版 fromJson）。
        let entries: JSON = .array([
            .array([.string("extra1"), .string("番外一")]),
            .array([.string("main"), .array([
                .array([.string("ch1"), .string("第一话")]),
                .array([.string("ch2"), .string("第二话")]),
            ])]),
        ])
        guard let chapters = ComicChapters.fromEntries(entries) else {
            XCTFail("fromEntries returned nil")
            return
        }
        XCTAssertTrue(chapters.isGrouped)
        XCTAssertEqual(chapters.groupNames, ["main", "默认"])
        XCTAssertEqual(chapters.ids, ["ch1", "ch2", "extra1"])
        XCTAssertEqual(chapters.entries(inGroup: "main").map(\.title), ["第一话", "第二话"])
        XCTAssertEqual(chapters.titleAt(1), "第一话")
    }

    func testLoadEpAndImageConfigWithTicket() async throws {
        // 先加载章节图片（建立内存态 ticket）
        let pages = try await source.loadComicPages(id: "30055", ep: "ch1")
        XCTAssertEqual(pages, ["https://img.komiic.com/001.jpg", "https://img.komiic.com/002.jpg"])

        // onImageLoad 应带上内存态 X-Image-Ticket
        let config = try await source.getImageLoadingConfig(imageKey: "https://img.komiic.com/001.jpg", cid: "30055", eid: "ch1")
        let headers = config?["headers"]
        XCTAssertEqual(headers?["X-Image-Ticket"].stringValue, "t1")
        XCTAssertEqual(headers?["referer"].stringValue?.contains("komiic"), true)
    }

    func testDataPersistenceRoundTrip() {
        XCTAssertFalse(source.isLogged)
        source.saveData("token", .string("jwt-token-value"))
        XCTAssertEqual(source.loadData("token").stringValue, "jwt-token-value")
        source.saveData("account", .array([.string("user"), .string("pass")]))
        XCTAssertTrue(source.isLogged)
        // 新实例从磁盘恢复
        let reloaded = ComicSource(
            name: "Komiic", key: "Komiic", version: "1", url: "", filePath: "", runtime: runtime
        )
        reloaded.restoreData()
        XCTAssertEqual(reloaded.loadData("token").stringValue, "jwt-token-value")
        XCTAssertFalse(reloaded.loadData("nonexistent-key").boolValue == true)
        source.deleteData("account")
        XCTAssertFalse(source.isLogged)
    }
}
