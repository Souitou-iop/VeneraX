import Foundation
import JavaScriptCore

/// 漫画源实例。字段路径与回调签名逐一对齐 parser.dart；所有回调都是
/// async throws（JS 异常与网络错误统一抛出），返回原始 JSON，由
/// 类型化包装方法转换为 Comic/ComicDetails 等模型。
public final class ComicSource: @unchecked Sendable {
    public let name: String
    public let key: String
    public let version: String
    public let url: String
    public let filePath: String
    public let runtime: JSRuntime

    /// 持久化数据（{dataPath}/comic_source/{key}.data）。
    public private(set) var data: JSON
    private let dataLock = NSLock()

    /// 源设置声明（settings 表单）。
    public private(set) var settings: [String: SourceSetting] = [:]
    /// 源内翻译表。
    public private(set) var translations: JSON = .null
    /// 探索页声明。
    public struct ExplorePage: Sendable {
        public enum PageType: String, Sendable {
            case multiPageComicList
            case singlePageWithMultiPart
            case mixed
        }

        public var title: String
        public var type: PageType
        public var index: Int
    }

    public private(set) var explorePages: [ExplorePage] = []
    public private(set) var account: AccountConfig?
    public private(set) var searchAvailable = false
    public private(set) var favoriteDataAvailable = false
    /// 网络收藏页键（favorites.key，用于可见页列表）。
    public private(set) var favoriteDataKey: String?
    public private(set) var multiFolder = false
    public private(set) var idMatchPattern: String?
    /// 分类页数据（category 声明）。
    public private(set) var categoryData: SourceCategoryData?
    public private(set) var categoryComicsAvailable = false
    public private(set) var rankingAvailable = false

    init(name: String, key: String, version: String, url: String, filePath: String, runtime: JSRuntime) {
        self.name = name
        self.key = key
        self.version = version
        self.url = url
        self.filePath = filePath
        self.runtime = runtime
        self.data = .object([:])
    }

    // MARK: - 基础调用

    /// 调用 JS 表达式并等待落定，返回转换后的 JSON。
    public func invoke(_ expression: String) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            runtime.evaluateAsync(expression) { result in
                switch result {
                case .success(let value):
                    // 回调发生在运行时队列（then 微任务冲刷中），可安全转换。
                    let converted = (value as Any) as? JSValue
                    let json = JSON(any: converted?.deepConverted() ?? NSNull())
                    continuation.resume(returning: json)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func invokeObject(_ expression: String) async throws -> JSON {
        let result = try await invoke(expression)
        guard result.objectValue != nil else {
            throw JSRuntimeException(message: "Expected object from \(expression), got \(result)")
        }
        return result
    }

    public func checkExists(_ index: String) -> Bool {
        var exists = false
        let keyLiteral = Self.encodeArg(key)
        let path = index.replacingOccurrences(of: "?.", with: ".").split(separator: ".").map(String.init)
        let pathLiteral = (try? JSON.array(path.map(JSON.string)).encodedString()) ?? "[]"
        let expression = """
        (() => {
            let parts = \(pathLiteral);
            let root = ComicSource.sources[\(keyLiteral)];
            let value = root;
            for (let i = 0; i < parts.length; i++) {
                if (value === null || value === undefined) return false;
                value = value[parts[i]];
            }
            return value !== null && value !== undefined;
        })()
        """
        runtime.performOnQueue {
            do {
                exists = try runtime.evaluate(expression).toBool()
            } catch {
                // Existence checks are capability probes; a malformed plugin must
                // not emit an exception for every optional API during parsing.
                exists = false
            }
        }
        return exists
    }

    // MARK: - 数据持久化（由 JSDispatcher 调用）

    public func loadData(_ dataKey: String) -> JSON {
        dataLock.lock()
        defer { dataLock.unlock() }
        return data[dataKey]
    }

    public func saveData(_ dataKey: String, _ value: JSON) {
        dataLock.lock()
        data[dataKey] = value
        let snapshot = data
        dataLock.unlock()
        persist(snapshot)
    }

    public func deleteData(_ dataKey: String) {
        dataLock.lock()
        var copy = data
        copy[dataKey] = .null
        data = copy
        let snapshot = copy
        dataLock.unlock()
        persist(snapshot)
    }

    public func loadSetting(_ settingKey: String) throws -> JSON {
        dataLock.lock()
        let saved = data["settings"][settingKey]
        dataLock.unlock()
        if !saved.isNull {
            return saved
        }
        guard let defaultValue = settings[settingKey]?.defaultValue, !defaultValue.isNull else {
            throw JSRuntimeException(message: "Setting not found: \(settingKey)")
        }
        return defaultValue
    }

    public var isLogged: Bool {
        !loadData("account").isNull
    }

    private func persist(_ snapshot: JSON) {
        let path = AppPaths.join(AppPaths.comicSourcePath, "\(key).data")
        do {
            try FileIO.writeStringAtomic(path, try snapshot.encodedString())
        } catch {
            Log.error("ComicSource", "Failed to save data for \(key): \(error)")
        }
    }

    func restoreData() {
        let path = AppPaths.join(AppPaths.comicSourcePath, "\(key).data")
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let json = JSON.decode(text), case .object = json
        {
            dataLock.lock()
            data = json
            dataLock.unlock()
        }
    }

    // MARK: - 解析补充字段（parser 调用）

    public var linkHandlerDomains: [String]? {
        guard checkExists("comic.link") else { return nil }
        return readJSON("comic.link.domains")?.arrayValue?.compactMap { $0.stringValue }
    }

    public func linkToId(_ url: String) async throws -> String? {
        guard checkExists("comic.link.linkToId") else { return nil }
        let expr = "ComicSource.sources.\(key).comic.link.linkToId(\(Self.encodeArg(url)))"
        return try await invoke(expr).stringValue
    }

    func parseMetadata() {
        if checkExists("settings"), case .object(let raw)? = readJSON("settings") {
            var parsed: [String: SourceSetting] = [:]
            for (key, value) in raw {
                if let setting = SourceSetting.parse(from: value, key: key) {
                    parsed[key] = setting
                }
            }
            settings = parsed
        }
        translations = readJSON("translation") ?? .null
        if checkExists("explore") {
            let raw = readJSON("explore") ?? .array([])
            let count = raw.arrayValue?.count ?? 0
            for index in 0..<count {
                let item = raw[index]
                guard let title = item["title"].stringValue,
                      let typeString = item["type"].stringValue
                else { continue }
                let type: ExplorePage.PageType
                switch typeString {
                case "multiPageComicList": type = .multiPageComicList
                case "singlePageWithMultiPart", "multiPartPage": type = .singlePageWithMultiPart
                case "mixed": type = .mixed
                default: continue
                }
                explorePages.append(ExplorePage(title: title, type: type, index: index))
            }
        }
        if checkExists("account") {
            let loginWithWebview = readJSON("account.loginWithWebview") ?? .null
            // 其余字段读取使用可选链，避免缺失子对象时抛 JS TypeError
            let cookieFields = (readJSON("account.loginWithCookies?.fields") ?? .array([]))
                .arrayValue?.compactMap { $0.stringValue } ?? []
            account = AccountConfig(
                source: self,
                hasLogin: checkExists("account.login"),
                loginWithWebviewURL: loginWithWebview["url"].stringValue,
                registerWebsite: readJSON("account.registerWebsite")?.stringValue,
                cookieFields: cookieFields
            )
        }
        searchAvailable = checkExists("search.load") || checkExists("search.loadNext")
        favoriteDataAvailable = checkExists("favorites")
        multiFolder = checkExists("favorites") && (readJSON("favorites.multiFolder")?.boolValue ?? false)
        favoriteDataKey = readJSON("favorites.key")?.stringValue
        if checkExists("comic.idMatch") {
            idMatchPattern = readJSON("comic.idMatch")?.stringValue
        }
        if checkExists("category"), let raw = readJSON("category") {
            categoryData = SourceCategoryData.parse(raw)
        }
        categoryComicsAvailable = checkExists("categoryComics.load")
        rankingAvailable = checkExists("categoryComics.ranking.load")
    }

    /// 供 UI 层读取任意字段（如 ranking.options）。
    public func readJSONPublic(_ index: String) -> JSON?? {
        readJSON(index)
    }

    private func readJSON(_ index: String) -> JSON? {
        let keyLiteral = Self.encodeArg(key)
        let path = index.replacingOccurrences(of: "?.", with: ".").split(separator: ".").map(String.init)
        let pathLiteral = (try? JSON.array(path.map(JSON.string)).encodedString()) ?? "[]"
        let expression = """
        (() => {
            let parts = \(pathLiteral);
            var value = ComicSource.sources[\(keyLiteral)];
            for (let i = 0; i < parts.length; i++) {
                if (value === null || value === undefined) return null;
                value = value[parts[i]];
            }
            return value === undefined ? null : value;
        })()
        """
        return runtime.performOnQueue {
            do {
                let value = try runtime.evaluate(expression)
                let converted = value.deepConverted()
                if converted is NSNull { return nil }
                return JSON(any: converted)
            } catch {
                return nil
            }
        }
    }

    // MARK: - 类型化 API（UI 层使用）

    public func loadComicInfo(id: String) async throws -> ComicDetails {
        // 章节顺序 = 源构造顺序（原版依赖 Dart Map 保插入序）。Swift 字典
        // 不保序，先在 JS 侧转成保序 entries 数组再解析。Map 用 forEach
        // 迭代（严格插入序，整数样键不被重排）；普通对象用 Object.keys。
        let expression = """
        (async function(){
            const toEntries = (obj) => {
                if (obj instanceof Map) {
                    const out = [];
                    obj.forEach((v, k) => out.push([
                        String(k),
                        (v !== null && typeof v === 'object') ? toEntries(v) : String(v),
                    ]));
                    return out;
                }
                return Object.keys(obj).map((k) => {
                    const v = obj[k];
                    return [k, (v !== null && typeof v === 'object') ? toEntries(v) : String(v)];
                });
            };
            const info = await ComicSource.sources.\(key).comic.loadInfo(\(Self.encodeArg(id)));
            const chapters = info && info.chapters;
            if (chapters && !Array.isArray(chapters) && (chapters instanceof Map || typeof chapters === 'object')) {
                return Object.assign({}, info, { chapters: toEntries(chapters), __chaptersAreEntries: true });
            }
            return info;
        })()
        """
        let json = try await invokeObject(expression)
        var details = ComicDetails.fromJSON(json, id: id, sourceKey: key)
        if json["__chaptersAreEntries"].boolValue == true {
            details.chapters = ComicChapters.fromEntries(json["chapters"])
        }
        return details
    }

    public func loadComicPages(id: String, ep: String?) async throws -> [String] {
        let epArg = ep.map { Self.encodeArg($0) } ?? "null"
        let expression = "ComicSource.sources.\(key).comic.loadEp(\(Self.encodeArg(id)), \(epArg))"
        let json = try await invoke(expression)
        // 原版语义：res["images"]
        if let images = json["images"].arrayValue {
            return images.compactMap { $0.stringValue }
        }
        return json.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    public func loadThumbnails(id: String, next: String?) async throws -> (thumbnails: [String], next: String?) {
        let nextArg = next.map { Self.encodeArg($0) } ?? "null"
        let json = try await invokeObject("ComicSource.sources.\(key).comic.loadThumbnails(\(Self.encodeArg(id)), \(nextArg))")
        let thumbnails = json["thumbnails"].arrayValue?.compactMap { $0.stringValue } ?? []
        return (thumbnails, json["next"].stringValue)
    }

    /// 多页探索页。
    public func loadExplorePage(_ index: Int, page: Int) async throws -> (comics: [Comic], maxPage: Int?) {
        let json = try await invokeObject("ComicSource.sources.\(key).explore[\(index)].load(\(page))")
        let comics = json["comics"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
        return (comics, json["maxPage"].intValue)
    }

    /// 分段单页探索页（singlePageWithMultiPart）。
    public func loadExploreMultiPart(_ index: Int) async throws -> [(title: String, comics: [Comic])] {
        let json = try await invokeObject("ComicSource.sources.\(key).explore[\(index)].load()")
        var parts: [(title: String, comics: [Comic])] = []
        if let array = json.arrayValue {
            for item in array {
                let title = item["title"].stringValue ?? ""
                let comics = item["comics"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
                parts.append((title: title, comics: comics))
            }
        } else if let object = json.objectValue {
            for (title, comicsJSON) in object {
                let comics = comicsJSON.arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
                parts.append((title: title, comics: comics))
            }
        }
        return parts
    }

    /// 搜索。返回结果与最大页码（maxPage null = loadNext 分页模式）。
    public func search(keyword: String, page: Int, options: [String: String]) async throws -> (comics: [Comic], maxPage: Int?) {
        var optionObject = "{"
        let encodedOptions = options.map { key, value in
            "\(Self.encodeArg(key)): \(Self.encodeArg(value))"
        }.joined(separator: ", ")
        optionObject += encodedOptions + "}"
        let expression = "ComicSource.sources.\(key).search.load(\(Self.encodeArg(keyword)), \(page), \(optionObject))"
        let json = try await invokeObject(expression)
        let comics = json["comics"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
        return (comics, json["maxPage"].intValue)
    }


    /// 搜索选项列表（供高级搜索筛选弹窗使用）。
    public func loadSearchOptions() -> [(key: String, label: String, defaultValue: String, options: [(value: String, text: String)])] {
        guard let raw = readJSON("search.options") ?? readJSON("search.optionList") else { return [] }
        guard let array = raw.arrayValue else { return [] }
        var result: [(key: String, label: String, defaultValue: String, options: [(value: String, text: String)])] = []
        for item in array {
            let label = item["label"].stringValue ?? item["title"].stringValue ?? ""
            let key = item["key"].stringValue ?? label
            let defaultValue = item["default"].stringValue ?? item["defaultValue"].stringValue ?? ""
            var opts: [(value: String, text: String)] = []
            if let optionsDict = item["options"].objectValue {
                for (v, t) in optionsDict {
                    opts.append((v, t.stringValue ?? v))
                }
            } else if let optionsArray = item["options"].arrayValue {
                for opt in optionsArray {
                    if let optObj = opt.objectValue {
                        let v = optObj["value"]?.stringValue ?? ""
                        let t = optObj["text"]?.stringValue ?? optObj["title"]?.stringValue ?? v
                        opts.append((v, t))
                    } else if let optStr = opt.stringValue {
                        opts.append((optStr, optStr))
                    }
                }
            }
            result.append((key: key, label: label, defaultValue: defaultValue, options: opts))
        }
        return result
    }

    /// 各搜索项的默认值组合（对齐原版聚合搜索/搜索结果页把每个 option 的 defaultValue 传给 load）。
    public func defaultSearchOptions() -> [String: String] {
        var result: [String: String] = [:]
        for option in loadSearchOptions() {
            result[option.key] = option.defaultValue
        }
        return result
    }

    /// 网络收藏夹列表（多文件夹源）。
    public func loadFavoriteFolders() async throws -> [(id: String, title: String)] {
        let json = try await invoke("ComicSource.sources.\(key).favorites.loadFolders()")
        guard let array = json.arrayValue else { return [] }
        return array.compactMap { item in
            guard let id = item["id"].stringValue ?? item["id"].intValue.map(String.init) else { return nil }
            return (id, item["title"].stringValue ?? "")
        }
    }

    /// 网络收藏漫画列表。
    public func loadFavoriteComics(folderId: String?, page: Int?) async throws -> (comics: [Comic], maxPage: Int?) {
        let folderArg = folderId.map { Self.encodeArg($0) } ?? "null"
        let pageArg = page.map { String($0) } ?? "null"
        let json = try await invokeObject("ComicSource.sources.\(key).favorites.loadComics(\(folderArg), \(pageArg))")
        let comics = json["comics"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
        return (comics, json["maxPage"].intValue)
    }

    /// 添加/取消网络收藏。
    public func addOrDelFavorite(comicId: String, folderId: String, isAdding: Bool) async throws {
        _ = try await invoke("ComicSource.sources.\(key).favorites.addOrDelFavorite(\(Self.encodeArg(comicId)), \(Self.encodeArg(folderId)), \(isAdding))")
    }

    /// 当前源是否提供章节评论 API（对齐 comic.loadChapterComments）。
    public var chapterCommentsAvailable: Bool {
        checkExists("comic.loadChapterComments")
    }

    /// 加载指定章节评论。
    public func loadChapterComments(comicId: String, epId: String, page: Int, replyTo: String?) async throws -> (comments: [Comment], maxPage: Int?) {
        let replyArg = replyTo.map { Self.encodeArg($0) } ?? "null"
        let json = try await invokeObject("ComicSource.sources.\(key).comic.loadChapterComments(\(Self.encodeArg(comicId)), \(Self.encodeArg(epId)), \(page), \(replyArg))")
        let comments = json["comments"].arrayValue?.map(Comment.fromJSON) ?? []
        return (comments, json["maxPage"].intValue)
    }

    /// 发送指定章节评论。
    public func sendChapterComment(comicId: String, epId: String, content: String, replyTo: String?) async throws {
        let replyArg = replyTo.map { Self.encodeArg($0) } ?? "null"
        _ = try await invoke("ComicSource.sources.\(key).comic.sendChapterComment(\(Self.encodeArg(comicId)), \(Self.encodeArg(epId)), \(Self.encodeArg(content)), \(replyArg))")
    }

    /// 加载评论。
    public func loadComments(subId: String, page: Int?, replyTo: String?) async throws -> (comments: [Comment], maxPage: Int?) {
        let pageArg = page.map { String($0) } ?? "null"
        let replyArg = replyTo.map { Self.encodeArg($0) } ?? "null"
        let json = try await invokeObject("ComicSource.sources.\(key).comic.loadComments(\(Self.encodeArg(subId)), \(pageArg), \(replyArg))")
        let comments = json["comments"].arrayValue?.map(Comment.fromJSON) ?? []
        return (comments, json["maxPage"].intValue)
    }

    /// 发送评论。
    public func sendComment(subId: String, content: String, replyTo: String?) async throws {
        let replyArg = replyTo.map { Self.encodeArg($0) } ?? "null"
        _ = try await invoke("ComicSource.sources.\(key).comic.sendComment(\(Self.encodeArg(subId)), \(Self.encodeArg(content)), \(replyArg))")
    }

    /// 图片加载配置（headers 通道；onResponse/modifyImage 在阅读器里程碑接入）。
    public func getImageLoadingConfig(imageKey: String, cid: String?, eid: String?) async throws -> JSON? {
        guard checkExists("comic.onImageLoad") else { return nil }
        let cidArg = cid.map { Self.encodeArg($0) } ?? "null"
        let eidArg = eid.map { Self.encodeArg($0) } ?? "null"
        let json = try await invoke("ComicSource.sources.\(key).comic.onImageLoad(\(Self.encodeArg(imageKey)), \(cidArg), \(eidArg))")
        return json.isNull ? nil : json
    }

    /// 分类选项默认值：optionList 每组第一项的「值部分」（`-` 前段），
    /// 对齐原版 UI（key = 值，text = 展示名，load 只接收值）。
    public func categoryComicsOptionDefaults() -> [String] {
        guard let groups = readJSONPublic("categoryComics.optionList")??.arrayValue else { return [] }
        var defaults: [String] = []
        for group in groups {
            if let first = group["options"].arrayValue?.first?.stringValue {
                let value = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
                defaults.append(String(value ?? ""))
            }
        }
        return defaults
    }

    /// 分类漫画列表（categoryComics.load(category, param, options, page)）。
    public func loadCategoryComics(category: String, param: String, options: [String], page: Int) async throws -> (comics: [Comic], maxPage: Int?) {
        let optionsJSON = (try? JSON.array(options.map { .string($0) }).encodedString()) ?? "[]"
        let expression = "ComicSource.sources.\(key).categoryComics.load(\(Self.encodeArg(category)), \(Self.encodeArg(param)), \(optionsJSON), \(page))"
        let json = try await invokeObject(expression)
        let comics = json["comics"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
        return (comics, json["maxPage"].intValue)
    }

    /// 排行榜（categoryComics.ranking.load(option, page)）。
    public func loadRanking(option: String, page: Int) async throws -> (comics: [Comic], maxPage: Int?) {
        let json = try await invokeObject("ComicSource.sources.\(key).categoryComics.ranking.load(\(Self.encodeArg(option)), \(page))")
        let comics = json["comics"].arrayValue?.compactMap { Comic.fromJSON($0, sourceKey: key) } ?? []
        return (comics, json["maxPage"].intValue)
    }

    /// 账号登录。
    public func login(account: String, password: String) async throws {
        _ = try await invoke("ComicSource.sources.\(key).account.login(\(Self.encodeArg(account)), \(Self.encodeArg(password)))")
        setAccount(.array([.string(account), .string(password)]))
    }

    func setAccount(_ value: JSON) {
        dataLock.lock()
        data["account"] = value
        let snapshot = data
        dataLock.unlock()
        persist(snapshot)
    }

    public func logout() {
        deleteData("account")
    }

    static func encodeArg(_ string: String) -> String {
        (try? JSON.string(string).encodedString()) ?? "\"\""
    }
}

/// 账号配置（三种登录方式的数据面）。
public struct AccountConfig: @unchecked Sendable {
    public let source: ComicSource
    public let hasLogin: Bool
    public let loginWithWebviewURL: String?
    public let registerWebsite: String?
    public let cookieFields: [String]

    public var isLogged: Bool { source.isLogged }
}
