import XCTest
@testable import VeneraKit

/// 验证多源同时存在时的生命周期、并发搜索、存储隔离与排序机制。
final class MultiSourceConcurrencyTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraMultiSourceTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        runtime = JSRuntime()
        ComicSourceManager.shared.resetForTesting()
        let dispatcher = JSDispatcher()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.install(to: runtime)

        // 初始化环境
        runtime.queue.sync {
            _ = try? runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
        }
    }

    override func tearDown() {
        ComicSourceManager.shared.resetForTesting()
        runtime = nil
        AppPaths.overrideDataPath = nil
        if let dataPath = dataPath {
            try? FileManager.default.removeItem(atPath: dataPath)
        }
        super.tearDown()
    }

    private func createMockSourceScript(key: String, name: String, version: String = "1.0.0") -> String {
        """
        class \(key.capitalized)Source extends ComicSource {
            name = "\(name)"
            key = "\(key)"
            version = "\(version)"
            minAppVersion = "1.0.0"
            url = "https://\(key).example.com"

            explore = [
                {
                    title: "\(name) Explore 1",
                    type: "singlePageWithMultiPart",
                    load: async () => [{ title: "Comic 1", comics: [{ id: "c1", title: "\(name) C1", cover: "https://img.com/1.jpg" }] }]
                }
            ]

            category = {
                title: "\(name) Category",
                parts: [
                    {
                        name: "Genre",
                        type: "fixed",
                        categories: ["Action", "Romance"],
                        itemType: "category"
                    }
                ]
            }

            search = {
                load: async (keyword, page, options) => {
                    if ("\(key)" === "error_source") {
                        throw new Error("Search failed for " + "\(key)");
                    }
                    return {
                        comics: [
                            { id: "\(key)_1", title: keyword + " by \(name)", cover: "https://img.com/\(key)_1.jpg" },
                            { id: "\(key)_2", title: keyword + " volume 2 on \(name)", cover: "https://img.com/\(key)_2.jpg" }
                        ],
                        maxPage: 1
                    };
                }
            }
        }
        """
    }

    func testMultipleSourcesParsingAndStorageIsolation() throws {
        let parser = ComicSourceParser()

        let keys = ["alpha", "beta", "gamma"]
        var sources: [ComicSource] = []

        try runtime.queue.sync {
            for key in keys {
                let script = createMockSourceScript(key: key, name: "Source \(key.uppercased())")
                let path = "\(dataPath!)/\(key).js"
                let source = try parser.parse(script, filePath: path, runtime: runtime)
                ComicSourceManager.shared.registerForTesting(source)
                sources.append(source)
            }
        }

        XCTAssertEqual(ComicSourceManager.shared.count(), 3)
        XCTAssertNotNil(ComicSourceManager.shared.find("alpha"))
        XCTAssertNotNil(ComicSourceManager.shared.find("beta"))
        XCTAssertNotNil(ComicSourceManager.shared.find("gamma"))

        // 测试存储隔离：各源分别存储各自的数据
        sources[0].saveData("user_token", .string("token_alpha_123"))
        sources[1].saveData("user_token", .string("token_beta_456"))
        sources[2].saveData("user_token", .string("token_gamma_789"))

        XCTAssertEqual(sources[0].loadData("user_token").stringValue, "token_alpha_123")
        XCTAssertEqual(sources[1].loadData("user_token").stringValue, "token_beta_456")
        XCTAssertEqual(sources[2].loadData("user_token").stringValue, "token_gamma_789")
    }

    func testConcurrentAggregatedSearchAcrossMultipleSources() async throws {
        let parser = ComicSourceParser()
        let keys = ["srcA", "srcB", "srcC", "srcD", "srcE"]

        try runtime.queue.sync {
            for key in keys {
                let script = createMockSourceScript(key: key, name: "Source \(key)")
                let path = "\(dataPath!)/\(key).js"
                let source = try parser.parse(script, filePath: path, runtime: runtime)
                ComicSourceManager.shared.registerForTesting(source)
            }
        }

        let sources = ComicSourceManager.shared.all()
        XCTAssertEqual(sources.count, 5)

        // 模拟 AggregatedSearchView 的并发搜索 TaskGroup
        let keyword = "Naruto"
        var results: [String: [Comic]] = [:]
        var errors: [String: String] = [:]

        await withTaskGroup(of: (String, [Comic]?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let page = try await source.search(keyword: keyword, page: 1, options: [:])
                        return (source.key, page.comics, nil)
                    } catch {
                        return (source.key, nil, error.localizedDescription)
                    }
                }
            }

            for await (key, comics, error) in group {
                if let comics = comics {
                    results[key] = comics
                }
                if let error = error {
                    errors[key] = error
                }
            }
        }

        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(errors.count, 0)
        for key in keys {
            XCTAssertEqual(results[key]?.count, 2)
            XCTAssertTrue(results[key]?.first?.title.contains(keyword) ?? false)
        }
    }

    func testAggregatedSearchPartialFailureResilience() async throws {
        let parser = ComicSourceParser()
        let keys = ["ok1", "error_source", "ok2"]

        try runtime.queue.sync {
            for key in keys {
                let script = createMockSourceScript(key: key, name: "Source \(key)")
                let path = "\(dataPath!)/\(key).js"
                let source = try parser.parse(script, filePath: path, runtime: runtime)
                ComicSourceManager.shared.registerForTesting(source)
            }
        }

        let sources = ComicSourceManager.shared.all()
        var results: [String: [Comic]] = [:]
        var errors: [String: String] = [:]

        await withTaskGroup(of: (String, [Comic]?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let page = try await source.search(keyword: "Naruto", page: 1, options: [:])
                        return (source.key, page.comics, nil)
                    } catch {
                        return (source.key, nil, error.localizedDescription)
                    }
                }
            }

            for await (key, comics, error) in group {
                if let comics = comics {
                    results[key] = comics
                }
                if let error = error {
                    errors[key] = error
                }
            }
        }

        // key="error_source" 的源抛出异常，其他两个源正常返回
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(errors.count, 1)
        XCTAssertNotNil(errors["error_source"])
        XCTAssertEqual(results["ok1"]?.count, 2)
        XCTAssertEqual(results["ok2"]?.count, 2)
    }

    func testSourceOrderingPersistence() throws {
        let parser = ComicSourceParser()
        let keys = ["s1", "s2", "s3"]

        try runtime.queue.sync {
            for key in keys {
                let script = createMockSourceScript(key: key, name: "Source \(key)")
                let path = "\(dataPath!)/\(key).js"
                let source = try parser.parse(script, filePath: path, runtime: runtime)
                ComicSourceManager.shared.registerForTesting(source)
            }
        }

        // 默认字母序
        XCTAssertEqual(ComicSourceManager.shared.all().map(\.key), ["s1", "s2", "s3"])

        // 设置自定义排序：s3 -> s1 -> s2
        AppData.shared.settings["comicSourceOrder"] = .array([.string("s3"), .string("s1"), .string("s2")])
        XCTAssertEqual(ComicSourceManager.shared.all().map(\.key), ["s3", "s1", "s2"])
    }
}

extension MultiSourceConcurrencyTests {
    func testParseSimulatorSources() throws {
        let parser = ComicSourceParser()
        for file in ["mangadex.js", "copymanga.js"] {
            let path = "/Users/ebato/Library/Developer/CoreSimulator/Devices/B37FC62C-8F44-42B7-A003-7B2779255ED3/data/Containers/Data/Application/37B73BBF-2749-4D5C-B8FF-D711FD985074/Library/Application Support/comic_source/\(file)"
            if let js = try? String(contentsOfFile: path, encoding: .utf8) {
                let source = try parser.parse(js, filePath: path, runtime: runtime!)
                XCTAssertFalse(source.name.isEmpty)
                XCTAssertFalse(source.key.isEmpty)
                print("Parsed simulator source: \(source.name) (\(source.key))")
            }
        }
    }
}
