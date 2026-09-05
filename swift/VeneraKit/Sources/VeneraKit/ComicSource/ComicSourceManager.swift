import Foundation

/// 解析 JS 源脚本 → ComicSource。对齐 parser.dart：
/// 提取 class 行 → 实例化挂载到 ComicSource.sources.<key> → 读取字段 →
/// 修补 isAppVersionAfter bug → 恢复持久化数据 → 异步调 init()。
public struct ComicSourceParseException: Error, CustomStringConvertible {
    public let message: String
    public let isRecoverable: Bool

    public init(message: String, isRecoverable: Bool = false) {
        self.message = message
        self.isRecoverable = isRecoverable
    }

    public var description: String { message }
}

public struct ComicSourceParser {
    public init() {}

    public func parse(_ js: String, filePath: String, runtime: JSRuntime) throws -> ComicSource {
        let normalized = js.replacingOccurrences(of: "\r\n", with: "\n")
        let classLine = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("class ") }
        guard var classLineText = classLine?.trimmingCharacters(in: .whitespaces),
              classLineText.hasPrefix("class "),
              classLineText.contains("extends ComicSource")
        else {
            throw ComicSourceParseException(message: "Invalid Content", isRecoverable: true)
        }
        var className = classLineText
            .components(separatedBy: "class").dropFirst().first ?? ""
        className = className
            .components(separatedBy: "extends ComicSource").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !className.isEmpty, className.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw ComicSourceParseException(message: "Invalid class name", isRecoverable: true)
        }

        // 实例化并挂载 temp
        let instantiate = """
        (() => { \(normalized)
            globalThis['temp'] = new \(className)()
        }).call()
        """
        _ = try? runtime.evaluate(instantiate, name: className)

        guard let name = readStringField(runtime, "temp.name") else {
            throw ComicSourceParseException(message: "name is required")
        }
        guard let key = readStringField(runtime, "temp.key") else {
            throw ComicSourceParseException(message: "key is required")
        }
        let version = readStringField(runtime, "temp.version") ?? "1.0.0"
        let minAppVersion = readStringField(runtime, "temp.minAppVersion")
        let url = readStringField(runtime, "temp.url") ?? ""

        if let minAppVersion, compareSemVer(minAppVersion, JSRuntime.appVersion) {
            throw ComicSourceParseException(message: "minAppVersion \(minAppVersion) is required")
        }
        guard key.contains("^") == false,
              key.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil
        else {
            throw ComicSourceParseException(message: "key \(key) is invalid")
        }
        if ComicSourceManager.shared.find(key) != nil {
            throw ComicSourceParseException(message: "key(\(key)) already exists", isRecoverable: true)
        }

        _ = try? runtime.evaluate("ComicSource.sources.\(key) = globalThis['temp'];")

        // 修补源脚本 isAppVersionAfter 的比较 bug（与原版一致）。
        _ = try? runtime.evaluate("""
        (function() {
            var src = ComicSource.sources.\(key);
            if (src && src.isAppVersionAfter) {
                src.isAppVersionAfter = function(target) {
                    var current = APP.version;
                    var targetArr = target.split('.');
                    var currentArr = current.split('.');
                    for (var i = 0; i < 3; i++) {
                        var c = parseInt(currentArr[i]) || 0;
                        var t = parseInt(targetArr[i]) || 0;
                        if (c > t) return true;
                        if (c < t) return false;
                    }
                    return true;
                };
            }
        })();
        """)

        let source = ComicSource(
            name: name,
            key: key,
            version: version,
            url: url,
            filePath: filePath,
            runtime: runtime
        )
        source.parseMetadata()
        source.restoreData()

        // 注册 int key（历史数据兼容）
        SourcePlatformResolver.shared.intKey(for: key)

        if source.checkExists("init") {
            runtime.queue.asyncAfter(deadline: .now() + 0.05) { [weak runtime] in
                guard let runtime else { return }
                runtime.evaluateAsync("ComicSource.sources.\(key).init()") { result in
                    if case .failure(let error) = result {
                        Log.warning("Comic Source Init", "Init failed for \(key): \(error)")
                    }
                }
            }
        }
        return source
    }

    private func readStringField(_ runtime: JSRuntime, _ expression: String) -> String? {
        runtime.performOnQueue {
            guard let value = try? runtime.evaluate(expression) else { return nil }
            if value.isNull || value.isUndefined { return nil }
            return value.toString()
        }
    }

    /// 返回 true 表示 required 版本高于当前（对齐 compareSemVer 语义）。
    func compareSemVer(_ required: String, _ current: String) -> Bool {
        let requiredParts = required.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: "-").first.map {
            $0.split(separator: ".").map { Int($0) ?? 0 }
        } ?? []
        for index in 0..<3 {
            let r = index < requiredParts.count ? requiredParts[index] : 0
            let c = index < currentParts.count ? currentParts[index] : 0
            if c < r { return true }
        }
        return false
    }
}

/// 漫画源管理器。安装/删除/加载目录下全部源；同时实现
/// JSDispatcher.SourceStorageDelegate（load_data 等桥接）。
public final class ComicSourceManager: @unchecked Sendable {
    public static let shared = ComicSourceManager()

    public let onChange = CallbackRegistry<Void>()

    private let lock = NSLock()
    private var sources: [String: ComicSource] = [:]
    private var runtime: JSRuntime?

    /// 调试工具（JS 求值器）用的只读访问。
    public var debugRuntime: JSRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }

    private init() {}

    public func attach(runtime: JSRuntime) {
        lock.lock()
        self.runtime = runtime
        lock.unlock()
    }

    public func find(_ key: String) -> ComicSource? {
        lock.lock()
        defer { lock.unlock() }
        return sources[key]
    }

    public func all() -> [ComicSource] {
        lock.lock()
        defer { lock.unlock() }
        // 按设置中的排序返回
        let order = (AppData.shared.settings["comicSourceOrder"].arrayValue ?? [])
            .compactMap { $0.stringValue }
        let unordered = sources.values.sorted { $0.key < $1.key }
        var ordered: [ComicSource] = []
        for key in order {
            if let source = sources[key] {
                ordered.append(source)
            }
        }
        for source in unordered {
            if !ordered.contains(where: { $0.key == source.key }) {
                ordered.append(source)
            }
        }
        return ordered
    }

    /// 扫描 comic_source 目录加载全部源。
    public func loadFromDirectory() async {
        guard let runtime = runtime else {
            Log.error("ComicSource", "Runtime not attached")
            return
        }
        let directory = AppPaths.comicSourcePath
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        let parser = ComicSourceParser()
        for file in files.sorted() where file.hasSuffix(".js") {
            let path = AppPaths.join(directory, file)
            guard let js = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            do {
                let source = try parser.parse(js, filePath: path, runtime: runtime)
                add(source)
            } catch let error as ComicSourceParseException {
                if error.isRecoverable {
                    Log.warning("ComicSource", "Skipped \(file): \(error.message)")
                } else {
                    Log.error("ComicSource", "Failed to parse \(file): \(error.message)")
                }
            } catch {
                Log.error("ComicSource", "Failed to parse \(file): \(error)")
            }
        }
        Log.info("ComicSource", "Loaded \(count()) sources")
        backfillVisiblePageListsIfNeeded()
    }

    /// 兼容本钩子加入前安装的源：可见列表完全为空且已有源声明页面时，
    /// 回填全部页面（避免升级后探索/分类页变空）。列表非空时不做任何事，
    /// 不会复活用户手动移除的页面。
    private func backfillVisiblePageListsIfNeeded() {
        let settings = AppData.shared.settings
        func isEmptyList(_ key: String) -> Bool {
            let list = settings[key].arrayValue?.compactMap { $0.stringValue } ?? []
            return list.isEmpty
        }
        guard isEmptyList("explore_pages"), isEmptyList("categories"), isEmptyList("searchSources") else { return }
        for source in all() {
            addSourcePagesToVisibleLists(source)
        }
    }

    /// 安装源（URL 下载或本地文件内容）。
    public func install(js: String, fileName: String) async throws -> ComicSource {
        guard let runtime = runtime else {
            throw JSRuntimeException(message: "Runtime not attached")
        }
        let filePath = AppPaths.join(AppPaths.comicSourcePath, fileName)
        let parser = ComicSourceParser()
        let source: ComicSource
        do {
            source = try parser.parse(js, filePath: filePath, runtime: runtime)
        } catch {
            throw error
        }
        try js.write(toFile: filePath, atomically: true, encoding: .utf8)
        add(source)
        saveOrder()
        // 安装即把该源的全部页面加入可见列表（对齐 _addAllPagesWithComicSource）。
        addSourcePagesToVisibleLists(source)
        return source
    }

    /// 新源安装后把探索页/分类页/网络收藏页/搜索源加入设置中的可见键列表
    /// （对齐原版 comic_source_page.dart `_addAllPagesWithComicSource`）。
    public func addSourcePagesToVisibleLists(_ source: ComicSource) {
        let settings = AppData.shared.settings
        func append(_ key: String, _ value: String) {
            var list = settings[key].arrayValue?.compactMap { $0.stringValue } ?? []
            guard !list.contains(value) else { return }
            list.append(value)
            settings[key] = .array(list.map { .string($0) })
        }
        for page in source.explorePages {
            append("explore_pages", page.title)
        }
        if let categoryKey = source.categoryData?.key {
            append("categories", categoryKey)
        }
        if source.favoriteDataAvailable, let favoriteKey = source.favoriteDataKey {
            append("favorites", favoriteKey)
        }
        if source.searchAvailable {
            append("searchSources", source.key)
        }
        AppData.shared.saveData()
    }

    /// 聚合搜索的源列表（对齐原版 aggregated_search_page.dart）：
    /// 按设置 searchSources 的键序返回已安装且支持搜索的源，未列入或无效的键跳过；
    /// 设置为空列表时不搜索任何源（与探索页等可见列表「空=空态」语义一致）。
    public func aggregatedSearchSources() -> [ComicSource] {
        let keys = AppData.shared.settings["searchSources"].arrayValue?.compactMap { $0.stringValue } ?? []
        var byKey: [String: ComicSource] = [:]
        for source in all() where source.searchAvailable {
            byKey[source.key] = source
        }
        var seen = Set<String>()
        return keys.compactMap { key in
            guard !seen.contains(key), let source = byKey[key] else { return nil }
            seen.insert(key)
            return source
        }
    }

    /// 移除失效页键（对齐 `_validatePages`：源被删后清理残留键）。
    public func validateVisiblePageLists() {
        let settings = AppData.shared.settings
        let allExploreKeys = Set(all().flatMap { $0.explorePages.map(\.title) })
        let allCategoryKeys = Set(all().compactMap { $0.categoryData?.key })
        let allSourceKeys = Set(all().map(\.key))
        func filter(_ key: String, valid: Set<String>) {
            let list = settings[key].arrayValue?.compactMap { $0.stringValue } ?? []
            let filtered = list.filter { valid.contains($0) }
            if filtered.count != list.count {
                settings[key] = .array(filtered.map { .string($0) })
            }
        }
        filter("explore_pages", valid: allExploreKeys)
        filter("categories", valid: allCategoryKeys)
        filter("searchSources", valid: allSourceKeys)
    }

    public func remove(_ key: String) throws {
        lock.lock()
        let source = sources.removeValue(forKey: key)
        lock.unlock()
        if let source {
            try? FileManager.default.removeItem(atPath: source.filePath)
            let dataPath = AppPaths.join(AppPaths.comicSourcePath, "\(key).data")
            FileIO.deleteIgnoringErrors(dataPath)
            validateVisiblePageLists()
            onChange.emit(())
        }
    }

    /// 测试/内部注册（不经文件安装流程）。
    public func registerForTesting(_ source: ComicSource) {
        add(source)
    }

    /// 测试重置：清空全部源并脱离运行时，让 JSContext 可释放。
    public func resetForTesting() {
        lock.lock()
        sources = [:]
        runtime = nil
        lock.unlock()
    }

    /// 迁移/导入后重载全部源（清空内存注册表后重扫目录）。
    public func reloadSources() async {
        clearSources()
        await loadFromDirectory()
    }

    private func clearSources() {
        lock.lock()
        sources = [:]
        lock.unlock()
    }

    private func add(_ source: ComicSource) {
        lock.lock()
        sources[source.key] = source
        lock.unlock()
        onChange.emit(())
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    /// 持久化排序（comicSourceOrder）。
    public func saveOrder() {
        let keys = all().map { $0.key }
        AppData.shared.settings["comicSourceOrder"] = .array(keys.map { .string($0) })
    }

    /// 源排序读取（loadFromDirectory 后按设置排序重建）。
    public func applyOrder() {
        onChange.emit(())
    }
}

extension ComicSourceManager: JSDispatcher.SourceStorageDelegate {
    public func loadData(sourceKey: String, dataKey: String) -> JSON {
        find(sourceKey)?.loadData(dataKey) ?? .null
    }

    public func saveData(sourceKey: String, dataKey: String, data: JSON) {
        find(sourceKey)?.saveData(dataKey, data)
    }

    public func deleteData(sourceKey: String, dataKey: String) {
        find(sourceKey)?.deleteData(dataKey)
    }

    public func loadSetting(sourceKey: String, settingKey: String) throws -> JSON {
        guard let source = find(sourceKey) else {
            throw JSRuntimeException(message: "Source not found: \(sourceKey)")
        }
        return try source.loadSetting(settingKey)
    }

    public func isLogged(sourceKey: String) -> Bool {
        find(sourceKey)?.isLogged ?? false
    }
}
