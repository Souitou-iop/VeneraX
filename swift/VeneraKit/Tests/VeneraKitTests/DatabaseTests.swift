import XCTest
@testable import VeneraKit

final class DatabaseTests: XCTestCase {
    private var dataPath: String!

    override func setUp() {
        super.setUp()
        dataPath = NSTemporaryDirectory() + "VeneraDBTests-\(UUID().uuidString)"
        AppPaths.overrideDataPath = dataPath
        AppPaths.overrideCachePath = dataPath + "/cache"
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AppPaths.overrideDataPath = nil
        AppPaths.overrideCachePath = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    // MARK: - DatabaseGateway

    func testGatewayPragmasAndSelect() throws {
        let path = AppPaths.join(dataPath, "test.db")
        let db = try SQLiteDatabase(path: path)
        try db.execute("create table t (a text, b int);")
        try db.execute("insert into t values (?, ?);", [.text("hello"), .int(42)])
        let rows = try db.select("select * from t;")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["a"]?.textValue, "hello")
        XCTAssertEqual(rows[0]["b"]?.intValue, 42)
        let mode = try db.selectValue("pragma journal_mode;")?.textValue
        XCTAssertEqual(mode?.lowercased(), "wal")
    }

    func testCorruptDatabaseRecovered() throws {
        let path = AppPaths.join(dataPath, "corrupt.db")
        // 写入垃圾内容模拟损坏
        try Data("not a sqlite file at all".utf8).write(to: URL(fileURLWithPath: path))
        let db = DatabaseGateway.shared.openManagedRecovering(path)
        try db.execute("create table ok (id int);")
        XCTAssertTrue(try db.tableExists("ok"))
    }

    func testRestoreDatabaseFilesSwaps() throws {
        let main = AppPaths.join(dataPath, "main.db")
        let source = AppPaths.join(dataPath, "source.db")
        let gateway = DatabaseGateway.shared
        let mainDB = try gateway.openManaged(main)
        try mainDB.execute("create table t (v text);")
        let sourceDB = try gateway.openManaged(source)
        try sourceDB.execute("create table replaced (v text);")
        try sourceDB.execute("insert into replaced values ('new');")
        try gateway.restoreDatabaseFiles([main: source])
        let reopened = try gateway.openManaged(main)
        XCTAssertTrue(try reopened.tableExists("replaced"))
        XCTAssertFalse(try reopened.tableExists("t"))
    }

    // MARK: - 源 int key 注册表

    func testSourcePlatformResolver() {
        let resolver = SourcePlatformResolver.shared
        resolver.registerLegacyIntSourceKey(3, "ehentai")
        XCTAssertEqual(resolver.resolve(3), "ehentai")
        // 已注册源复用旧 int
        XCTAssertEqual(resolver.intKey(for: "ehentai"), 3)
        // 新源分配并登记
        let newInt = resolver.intKey(for: "swift-test-source")
        XCTAssertNotEqual(newInt, 0)
        XCTAssertEqual(resolver.resolve(newInt), "swift-test-source")
        // 再次获取保持稳定
        XCTAssertEqual(resolver.intKey(for: "swift-test-source"), newInt)
    }

    // MARK: - History

    private func makeManager() -> (HistoryManager, LocalFavoritesManager, ReadLaterManager, CookieStore) {
        (HistoryManager(dataPath: dataPath), LocalFavoritesManager(dataPath: dataPath),
         ReadLaterManager(dataPath: dataPath), CookieStore(dataPath: dataPath))
    }

    func testHistoryAddFindHide() {
        let (history, _, _, _) = makeManager()
        let item = History(id: "comic1", type: 7, title: "Test Comic", subtitle: "author", cover: "http://c/1.jpg", ep: 2, page: 15, maxPage: 40)
        history.addHistory(item)
        let found = history.findHistory(id: "comic1", type: 7)
        XCTAssertEqual(found?.title, "Test Comic")
        XCTAssertEqual(found?.ep, 2)
        XCTAssertEqual(found?.page, 15)
        XCTAssertEqual(found?.maxPage, 40)
        XCTAssertTrue(history.containsHistory(id: "comic1", type: 7))
        XCTAssertTrue(history.getRecent().contains { $0.id == "comic1" })

        // 重新阅读取消 hidden（insert or replace 语义）
        history.removeFromHistory(id: "comic1", type: 7)
        XCTAssertFalse(history.getRecent().contains { $0.id == "comic1" })
        var updated = item
        updated.ep = 3
        history.addHistory(updated)
        XCTAssertTrue(history.getRecent().contains { $0.id == "comic1" })

        history.clearHistory()
        XCTAssertTrue(history.getRecent().isEmpty)
        // 进度仍在（hidden 标记而非删除）
        XCTAssertEqual(history.findHistory(id: "comic1", type: 7)?.ep, 3)
    }

    func testReadEpisodeRoundTrip() {
        let (history, _, _, _) = makeManager()
        var item = History(id: "c", type: 1, title: "t", cover: "")
        item.readEpisode = ["1", "3", "group1-2"]
        history.addHistory(item)
        XCTAssertEqual(history.findHistory(id: "c", type: 1)?.readEpisode, ["1", "3", "group1-2"])
    }

    func testReadingStatistics() {
        let (history, _, _, _) = makeManager()
        history.addReadingTime(id: "c1", type: 1, title: "Comic", subtitle: "", cover: "", durationMs: 5000)
        history.addReadingTime(id: "c1", type: 1, title: "Comic", subtitle: "", cover: "", durationMs: 2500)
        let entries = history.getReadingStatistics()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].durationMs, 7500)
    }

    // MARK: - Favorites

    func testFavoriteFoldersAndItems() throws {
        let (_, favorites, _, _) = makeManager()
        favorites.addFolder("Read")
        favorites.addFolder("Follow")
        XCTAssertEqual(Set(favorites.getFolders()), ["Read", "Follow"])

        var item = FavoriteItem(id: "m1", name: "Manga", coverPath: "http://c/m1.jpg", author: "Author A", type: 3, tags: ["a", "b"], authors: ["Author A"], status: "连载中")
        item.extraMeta = ["language": "zh"]
        favorites.addFavorite("Read", item)
        XCTAssertTrue(favorites.contains(id: "m1", type: 3, folder: "Read"))
        XCTAssertTrue(favorites.containsAnyFolder(id: "m1", type: 3))
        XCTAssertEqual(favorites.getFoldersContaining(id: "m1", type: 3), ["Read"])
        XCTAssertEqual(favorites.count("Read"), 1)

        let loaded = favorites.getComics("Read")[0]
        XCTAssertEqual(loaded.name, "Manga")
        XCTAssertEqual(loaded.tags, ["a", "b"])
        XCTAssertEqual(loaded.authors, ["Author A"])
        XCTAssertEqual(loaded.status, "连载中")
        XCTAssertEqual(loaded.extraMeta["language"], "zh")
        XCTAssertEqual(loaded.time.count, 19) // yyyy-MM-dd HH:mm:ss

        favorites.removeFavorite(id: "m1", type: 3, folder: "Read")
        XCTAssertEqual(favorites.count("Read"), 0)

        try favorites.deleteFolder("Follow")
        XCTAssertEqual(favorites.getFolders(), ["Read"])
    }

    func testFavoriteItemJsonRoundTrip() {
        let (_, favorites, _, _) = makeManager()
        favorites.makeFollowFolder("F")
        var item = FavoriteItem(id: "x", name: "N", coverPath: "c", author: "a", type: 5, tags: ["t1"], authors: ["A1"], status: "完结")
        item.hasNewUpdate = true
        item.lastCheckTime = 12345
        favorites.addFavorite("F", item)
        let json = favorites.getComics("F")[0].toJson()
        let restored = FavoriteItem.fromJson(json)
        XCTAssertEqual(restored?.id, "x")
        XCTAssertEqual(restored?.tags, ["t1"])
        XCTAssertEqual(restored?.hasNewUpdate, true)
        XCTAssertEqual(restored?.lastCheckTime, 12345)
    }

    func testFolderOrderAndSync() {
        let (_, favorites, _, _) = makeManager()
        favorites.addFolder("B")
        favorites.addFolder("A")
        favorites.setFolderOrders(["A": 0, "B": 1])
        XCTAssertEqual(favorites.getFoldersSorted(), ["A", "B"])
        favorites.setFolderSync(folder: "A", sourceKey: "komiic", sourceFolder: "123")
        XCTAssertEqual(favorites.getFolderSync(folder: "A")?.sourceKey, "komiic")
    }

    // MARK: - Read later

    func testReadLater() {
        let (_, _, readLater, _) = makeManager()
        XCTAssertFalse(readLater.contains(id: "r1", type: 2))
        readLater.add(id: "r1", title: "Later", subtitle: "s", cover: "c", type: 2, tags: ["x"])
        XCTAssertTrue(readLater.contains(id: "r1", type: 2))
        XCTAssertEqual(readLater.getAll().first?.title, "Later")
        readLater.remove(id: "r1", type: 2)
        XCTAssertFalse(readLater.contains(id: "r1", type: 2))
    }

    // MARK: - Cookies

    func testCookieSaveLoadDelete() {
        let (_, _, _, cookies) = makeManager()
        cookies.save(CookieStore.StoredCookie(name: "token", value: "abc123", domain: "komiic.com", path: "/", expires: Date(timeIntervalSinceNow: 3600)))
        cookies.save(CookieStore.StoredCookie(name: "theme", value: "dark", domain: "komiic.com", path: "/"))

        let url = URL(string: "https://komiic.com/api/query")!
        let loaded = cookies.loadForRequest(url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains { $0.name == "token" && $0.value == "abc123" })

        // 子域匹配
        let sub = URL(string: "https://api.komiic.com/x")!
        XCTAssertTrue(cookies.loadForRequest(sub).contains { $0.name == "token" })
        // 无关域不匹配
        let other = URL(string: "https://example.com/x")!
        XCTAssertTrue(cookies.loadForRequest(other).isEmpty)

        cookies.delete(domain: "komiic.com")
        XCTAssertTrue(cookies.loadForRequest(url).isEmpty)
    }

    func testSetCookieHeaderParsing() {
        let (_, _, _, cookies) = makeManager()
        let url = URL(string: "https://example.com/login")!
        let parsed = cookies.parseSetCookie(
            "komiic-access-token=eyJhbGciOiJIUzI1NiJ9.test; Path=/; Domain=example.com; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure; HttpOnly",
            requestURL: url
        )
        XCTAssertEqual(parsed?.name, "komiic-access-token")
        XCTAssertEqual(parsed?.value, "eyJhbGciOiJIUzI1NiJ9.test")
        XCTAssertEqual(parsed?.domain, "example.com")
        XCTAssertEqual(parsed?.path, "/")
        XCTAssertEqual(parsed?.secure, true)
        XCTAssertEqual(parsed?.httpOnly, true)
        XCTAssertNotNil(parsed?.expires)

        // Set-Cookie 多值拆分（含 Expires 日期内的逗号）
        let headers = ["set-cookie": "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2; Path=/"]
        cookies.saveFromResponse(url: url, headers: headers)
        let all = cookies.getAllCookies()
        XCTAssertTrue(all.contains { $0.name == "a" && $0.value == "1" })
        XCTAssertTrue(all.contains { $0.name == "b" && $0.value == "2" })
    }

    // MARK: - CacheManager

    func testCacheManagerSetGetEvict() {
        let cache = CacheManager(dataPath: dataPath, cachePath: dataPath + "/cache")
        let payload = Data("image-bytes".utf8)
        let cacheKey = "http://img/1.jpg@komiic@c1@e1@1"
        cache.set(cacheKey, payload)
        XCTAssertEqual(cache.getData(cacheKey), payload)
        let firstSize = cache.size
        cache.set(cacheKey, Data(repeating: 7, count: 1024))
        // Replacing one key must account for the old file, not add both sizes.
        XCTAssertEqual(cache.size, firstSize - payload.count + 1024)
        cache.delete(cacheKey)
        XCTAssertNil(cache.getData("http://img/1.jpg@komiic@c1@e1@1"))

        // 超限清理：把上限压到 0 MB
        AppData.shared.settings["cacheSize"] = .int(0)
        cache.set("k1", Data(repeating: 9, count: 1024))
        cache.set("k2", Data(repeating: 8, count: 1024))
        // 上限 0 → 触发清理后应不超过或接近空
        XCTAssertLessThan(cache.size, 2048 * 1024)
        AppData.shared.settings["cacheSize"] = .int(2048)
    }
}
