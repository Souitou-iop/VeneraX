import XCTest
@testable import VeneraKit

/// 验证聚合搜索的源筛选/键序语义（对齐原版 aggregated_search_page.dart）
/// 与默认搜索项（search.options defaultValue）的解析与传递。
final class AggregatedSearchTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraAggregatedSearchTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        runtime = JSRuntime()
        ComicSourceManager.shared.resetForTesting()
        let dispatcher = JSDispatcher()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.install(to: runtime)

        runtime.queue.sync {
            _ = try? runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
        }
        AppData.shared.settings["searchSources"] = .null
    }

    override func tearDown() {
        AppData.shared.settings["searchSources"] = .null
        ComicSourceManager.shared.resetForTesting()
        runtime = nil
        AppPaths.overrideDataPath = nil
        if let dataPath = dataPath {
            try? FileManager.default.removeItem(atPath: dataPath)
        }
        super.tearDown()
    }

    /// 生成 mock 源脚本。searchable=false 时不带 search 块；searchOptions 为 JS 搜索项定义；
    /// echoOptions=true 时 load 把收到的 options 序列化进标题，便于断言默认值传递。
    private func createSourceScript(
        key: String,
        name: String,
        searchable: Bool = true,
        searchOptions: String? = nil,
        echoOptions: Bool = false
    ) -> String {
        var searchBlock = ""
        if searchable {
            let optionsBlock = searchOptions.map { "options: \($0),\n            " } ?? ""
            let title = echoOptions ? #"keyword + "|" + JSON.stringify(options)"# : "keyword + \" by \(name)\""
            searchBlock = """
                search = {
                    \(optionsBlock)load: async (keyword, page, options) => {
                        return {
                            comics: [
                                { id: "\(key)_1", title: \(title), cover: "https://img.com/\(key)_1.jpg" }
                            ],
                            maxPage: 1
                        };
                    }
                }
            """
        }
        return """
        class \(key.capitalized)Source extends ComicSource {
            name = "\(name)"
            key = "\(key)"
            version = "1.0.0"
            minAppVersion = "1.0.0"
            url = "https://\(key).example.com"

            explore = [
                {
                    title: "\(name) Explore",
                    type: "singlePageWithMultiPart",
                    load: async () => [{ title: "Part 1", comics: [] }]
                }
            ]

            \(searchBlock)
        }
        """
    }

    @discardableResult
    private func registerSources(
        keys: [String],
        searchable: Bool = true,
        searchOptions: String? = nil,
        echoOptions: Bool = false
    ) throws -> [ComicSource] {
        let parser = ComicSourceParser()
        return try runtime.queue.sync {
            var sources: [ComicSource] = []
            for key in keys {
                let script = createSourceScript(
                    key: key,
                    name: "Source \(key.uppercased())",
                    searchable: searchable,
                    searchOptions: searchOptions,
                    echoOptions: echoOptions
                )
                let path = "\(dataPath!)/\(key).js"
                let source = try parser.parse(script, filePath: path, runtime: runtime)
                ComicSourceManager.shared.registerForTesting(source)
                sources.append(source)
            }
            return sources
        }
    }

    // MARK: - aggregatedSearchSources

    func testAggregatedSearchSourcesFollowsSettingOrderAndSkipsUnknownKeys() throws {
        try registerSources(keys: ["aa", "bb", "cc"])
        AppData.shared.settings["searchSources"] =
            .array([.string("cc"), .string("aa"), .string("ghost"), .string("cc")])

        XCTAssertEqual(
            ComicSourceManager.shared.aggregatedSearchSources().map(\.key),
            ["cc", "aa"],
            "应按设置键序返回，跳过未安装的键并去重"
        )
    }

    func testAggregatedSearchSourcesSkipsNonSearchableSources() throws {
        try registerSources(keys: ["aa"])
        try registerSources(keys: ["quiet"], searchable: false)
        XCTAssertFalse(ComicSourceManager.shared.find("quiet")!.searchAvailable)

        AppData.shared.settings["searchSources"] = .array([.string("quiet"), .string("aa")])
        XCTAssertEqual(
            ComicSourceManager.shared.aggregatedSearchSources().map(\.key),
            ["aa"],
            "不支持搜索的源应被过滤"
        )
    }

    func testAggregatedSearchSourcesEmptySettingMeansNoSources() throws {
        try registerSources(keys: ["aa", "bb"])

        AppData.shared.settings["searchSources"] = .array([])
        XCTAssertTrue(
            ComicSourceManager.shared.aggregatedSearchSources().isEmpty,
            "空列表 = 空态，不应回退为全源搜索"
        )

        AppData.shared.settings["searchSources"] = .null
        XCTAssertTrue(ComicSourceManager.shared.aggregatedSearchSources().isEmpty)
    }

    // MARK: - defaultSearchOptions

    func testDefaultSearchOptionsFromScript() throws {
        let source = try registerSources(
            keys: ["opts"],
            searchOptions: """
            [
                { key: "order", label: "Order", default: "latest", options: { latest: "Latest", oldest: "Oldest" } },
                { key: "genre", label: "Genre", defaultValue: "all", options: [ { value: "all", text: "All" } ] }
            ]
            """
        )[0]

        XCTAssertEqual(source.defaultSearchOptions(), ["order": "latest", "genre": "all"])
    }

    func testDefaultSearchOptionsEmptyWithoutOptions() throws {
        let source = try registerSources(keys: ["plain"])[0]
        XCTAssertTrue(source.searchAvailable)
        XCTAssertEqual(source.defaultSearchOptions(), [:])
    }

    func testSearchReceivesDefaultOptions() async throws {
        let source = try registerSources(
            keys: ["echo"],
            searchOptions: """
            [ { key: "order", label: "Order", default: "latest", options: { latest: "Latest" } } ]
            """,
            echoOptions: true
        )[0]

        let page = try await source.search(keyword: "Naruto", page: 1, options: source.defaultSearchOptions())
        XCTAssertEqual(page.comics.count, 1)
        XCTAssertTrue(
            page.comics[0].title.contains(#""order":"latest""#),
            "search.load 应收到默认搜索项，实际标题: \(page.comics[0].title)"
        )
    }
}
