import XCTest
import JavaScriptCore
@testable import VeneraKit

/// 高强度鲁棒性与极端并发压力测试。
/// 验证数据库多线程高频读写重入安全、JS 引擎高压并发、数据损坏自愈与本地导入容错。
final class RobustnessStressTests: XCTestCase {
    private var dataPath: String!
    private var runtime: JSRuntime!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraStressTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)

        HistoryManager.shared.ensureSchema()
        ReadLaterManager.shared.ensureSchema()
        LocalFavoritesManager.shared.ensureSchema()

        runtime = JSRuntime()
        ComicSourceManager.shared.resetForTesting()
        let dispatcher = JSDispatcher()
        dispatcher.storageDelegate = ComicSourceManager.shared
        dispatcher.install(to: runtime)

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

    /// 1. 数据库 50 线程高并发读写压力测试：验证 WAL 模式与锁重入机制抗死锁能力。
    func testDatabaseHighConcurrencyStress() async throws {
        let iterations = 50
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let comicId = "comic_stress_\(i)"
                    let type = 100 + (i % 5)

                    // 写入历史
                    let hist = History(
                        id: comicId,
                        type: type,
                        title: "Stress Comic \(i)",
                        subtitle: "Author \(i)",
                        cover: "https://example.com/\(i).jpg",
                        ep: 1,
                        page: i + 1,
                        time: Date(),
                        maxPage: 20,
                        readEpisode: ["1"],
                        hideTime: nil
                    )
                    HistoryManager.shared.addHistory(hist)

                    // 写入稍后读
                    ReadLaterManager.shared.add(
                        id: comicId,
                        title: "Stress Comic \(i)",
                        subtitle: "Subtitle",
                        cover: "https://example.com/\(i).jpg",
                        type: type,
                        tags: ["Action", "Tag\(i)"]
                    )

                    // 写入本地收藏
                    let favItem = FavoriteItem(
                        id: comicId,
                        name: "Stress Comic \(i)",
                        coverPath: "https://example.com/\(i).jpg",
                        author: "Author",
                        type: type,
                        tags: ["TagA", "TagB"]
                    )
                    LocalFavoritesManager.shared.addFavorite("Folder_\(i % 3)", favItem)

                    // 读取并校验
                    let history = HistoryManager.shared.findHistory(id: comicId, type: type)
                    XCTAssertNotNil(history)
                    XCTAssertEqual(history?.page, i + 1)

                    let hasReadLater = ReadLaterManager.shared.contains(id: comicId, type: type)
                    XCTAssertTrue(hasReadLater)

                    let count = LocalFavoritesManager.shared.count("Folder_\(i % 3)")
                    XCTAssertGreaterThan(count, 0)
                }
            }
        }

        // 汇总校验
        let allHistory = HistoryManager.shared.getRecent(100)
        XCTAssertEqual(allHistory.count, iterations)
        let allReadLater = ReadLaterManager.shared.getAll()
        XCTAssertEqual(allReadLater.count, iterations)
    }

    /// 2. JS 引擎 100 任务高频并发调度与异步冲刷测试。
    func testJSRuntimeHighFrequencyAsyncStress() async throws {
        let total = 100
        var successes = 0
        guard let rt = runtime else {
            XCTFail("Runtime not initialized")
            return
        }

        await withTaskGroup(of: Int?.self) { group in
            for i in 0..<total {
                group.addTask {
                    let expr = """
                    (async () => {
                        let a = \(i);
                        let b = \(i * 2);
                        return a + b;
                    })()
                    """
                    let result: Int? = await withCheckedContinuation { cont in
                        rt.evaluateAsync(expr) { res in
                            switch res {
                            case .success(let val):
                                if let jsVal = val as? JSValue {
                                    cont.resume(returning: Int(jsVal.toInt32()))
                                } else if let num = val as? NSNumber {
                                    cont.resume(returning: num.intValue)
                                } else if let intVal = val as? Int {
                                    cont.resume(returning: intVal)
                                } else {
                                    cont.resume(returning: nil)
                                }
                            case .failure:
                                cont.resume(returning: nil)
                            }
                        }
                    }
                    return result
                }
            }

            for await res in group {
                if res != nil {
                    successes += 1
                }
            }
        }

        XCTAssertEqual(successes, total)
    }


    /// 4. 阅读器解码字节缓存同时受邻近窗口和总字节预算约束，避免长图把内存推高。
    @MainActor
    func testReaderDecodedImageCacheHasByteBudget() {
        let comic = Comic(
            id: "reader-cache-budget",
            title: "Reader Cache Budget",
            cover: "",
            subtitle: "",
            sourceKey: "local"
        )
        let reader = ReaderModel(comic: comic, source: nil)
        reader.pages = Array(repeating: "/tmp/page.jpg", count: 20)
        let pageData = Data(repeating: 7, count: 8 * 1024 * 1024)
        reader.loadedImages = Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, pageData) })

        reader.setIndex(10)

        let retainedBytes = reader.loadedImages.values.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(retainedBytes, 96 * 1024 * 1024)
        XCTAssertNotNil(reader.loadedImages[10])
    }

    /// 3. 本地漫画导入器面对非法/损坏 ZIP 文件的容错性。
    func testLocalComicImporterCorruptFileGracefulHandling() async throws {
        let corruptData = "This is definitely not a zip file".data(using: .utf8)!
        let corruptZipPath = "\(dataPath!)/corrupt.cbz"
        let corruptZipURL = URL(fileURLWithPath: corruptZipPath)
        try corruptData.write(to: corruptZipURL)

        do {
            _ = try LocalComicImporter.importArchive(corruptZipURL)
            XCTFail("Should fail for corrupt zip")
        } catch {
            // 预期捕获异常，应用绝不崩溃
            XCTAssertTrue(error is SyncError)
        }
    }
}
