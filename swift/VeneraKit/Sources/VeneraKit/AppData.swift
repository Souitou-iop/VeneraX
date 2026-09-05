import Foundation

/// 应用数据：设置 + 搜索历史 + implicitData。
///
/// 与 Flutter 版 `lib/foundation/appdata.dart` 键级兼容：
/// - `appdata.json` = { settings, searchHistory }
/// - `syncdata.json` = appdata 剔除 `syncDisabledFields` 后的副本（供 WebDAV 同步打包）
/// - `implicitData.json` = 设备本地 KV（源类型注册表、任务历史等）
///
/// 全部写入走原子替换；文件写入在专用串行队列上执行。
public final class AppData: @unchecked Sendable {
    public static let shared = AppData()

    struct State {
        var settings: [String: JSON]
        var searchHistory: [String]
        var implicitData: [String: JSON]
    }

    private let lock = NSLock()
    private var state: State
    private let ioQueue = DispatchQueue(label: "venera.appdata.io")

    /// 设置变更回调（任意线程触发，观察者自行跳主线程）。
    /// 对应原版 Settings 的 notifyListeners。
    public let onSettingsChanged = CallbackRegistry<String>()

    public init(initialSettings: [String: JSON] = [:]) {
        var defaults = Settings.defaults
        for (key, value) in initialSettings where !value.isNull {
            defaults[key] = value
        }
        state = State(settings: defaults, searchHistory: [], implicitData: [:])
    }

    // MARK: - Settings 访问

    public var settings: SettingsProxy { SettingsProxy(appData: self) }

    public struct SettingsProxy {
        fileprivate let appData: AppData

        public subscript(key: String) -> JSON {
            get { appData.withState { $0.settings[key] ?? .null } }
            nonmutating set { appData.setSetting(key, newValue) }
        }

        public func rawDictionary() -> [String: JSON] {
            appData.withState { $0.settings }
        }

        /// 每部漫画/设备独立阅读设置的生效链：漫画级 → 设备级 → 全局（对齐上游 appdata.dart）。
        public func getReaderSetting(comicId: String, sourceKey: String, key: String) -> JSON {
            let composite = "\(comicId)@\(sourceKey)"
            let comicSettings = self["comicSpecificSettings"][composite]
            if comicSettings["enabled"].boolValue == true {
                let value = comicSettings[key]
                if !value.isNull {
                    return value
                }
            }
            return getDeviceReaderSetting(key: key)
        }

        /// 写入漫画级设置值（只写值；enabled 开关由 UI 经 setComicSpecificSettingsEnabled 控制，对齐上游）。
        public func setReaderSetting(comicId: String, sourceKey: String, key: String, value: JSON) {
            let composite = "\(comicId)@\(sourceKey)"
            var comicSettings = self["comicSpecificSettings"][composite].objectValue ?? [:]
            comicSettings[key] = value
            var all = self["comicSpecificSettings"].objectValue ?? [:]
            all[composite] = .object(comicSettings)
            self["comicSpecificSettings"] = .object(all)
        }

        public func isComicSpecificSettingsEnabled(comicId: String, sourceKey: String) -> Bool {
            self["comicSpecificSettings"]["\(comicId)@\(sourceKey)"]["enabled"].boolValue == true
        }

        public func setComicSpecificSettingsEnabled(comicId: String, sourceKey: String, enabled: Bool) {
            let composite = "\(comicId)@\(sourceKey)"
            var comicSettings = self["comicSpecificSettings"][composite].objectValue ?? [:]
            comicSettings["enabled"] = .bool(enabled)
            var all = self["comicSpecificSettings"].objectValue ?? [:]
            all[composite] = .object(comicSettings)
            self["comicSpecificSettings"] = .object(all)
        }

        /// 清除某部漫画的全部独立设置（对齐上游 resetComicReaderSettings）。
        public func resetComicReaderSettings(comicId: String, sourceKey: String) {
            var all = self["comicSpecificSettings"].objectValue ?? [:]
            all.removeValue(forKey: "\(comicId)@\(sourceKey)")
            self["comicSpecificSettings"] = .object(all)
        }

        public func isDeviceSpecificSettingsEnabled() -> Bool {
            let deviceId = self["deviceId"].stringValue ?? ""
            guard !deviceId.isEmpty else { return false }
            return self["deviceSpecificSettings"][deviceId]["enabled"].boolValue == true
        }

        public func getDeviceReaderSetting(key: String) -> JSON {
            guard isDeviceSpecificSettingsEnabled() else { return self[key] }
            let deviceId = self["deviceId"].stringValue ?? ""
            let value = self["deviceSpecificSettings"][deviceId][key]
            return value.isNull ? self[key] : value
        }

        /// 写入设备级设置值（只写值并懒创建 deviceId；enabled 开关由 UI 控制，对齐上游）。
        public func setDeviceReaderSetting(key: String, value: JSON) {
            let deviceId = getOrCreateDeviceId()
            var all = self["deviceSpecificSettings"].objectValue ?? [:]
            var deviceSettings = all[deviceId]?.objectValue ?? [:]
            deviceSettings[key] = value
            all[deviceId] = .object(deviceSettings)
            self["deviceSpecificSettings"] = .object(all)
        }

        /// 清除本设备的独立阅读设置（保留 deviceId 本身，对齐上游 resetDeviceReaderSettings）。
        public func resetDeviceReaderSettings() {
            let deviceId = self["deviceId"].stringValue ?? ""
            guard !deviceId.isEmpty else { return }
            var all = self["deviceSpecificSettings"].objectValue ?? [:]
            all.removeValue(forKey: deviceId)
            self["deviceSpecificSettings"] = .object(all)
        }

        private func getOrCreateDeviceId() -> String {
            let existing = self["deviceId"].stringValue ?? ""
            if !existing.isEmpty {
                return existing
            }
            let id = UUID().uuidString
            self["deviceId"] = .string(id)
            return id
        }
    }

    private func setSetting(_ key: String, _ value: JSON) {
        var changed = false
        lock.lock()
        if state.settings[key] != value {
            state.settings[key] = value
            changed = true
        }
        lock.unlock()
        if changed, key != "dataVersion" {
            onSettingsChanged.emit(key)
        }
    }

    func withState<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    // MARK: - 搜索历史（对齐原版：去重置顶，上限 50）

    public var searchHistory: [String] {
        withState { $0.searchHistory }
    }

    public func addSearchHistory(_ keyword: String) {
        lock.lock()
        var history = state.searchHistory
        history.removeAll { $0 == keyword }
        history.insert(keyword, at: 0)
        if history.count > 50 {
            history.removeLast(history.count - 50)
        }
        state.searchHistory = history
        lock.unlock()
        saveData()
    }

    public func removeSearchHistory(_ keyword: String) {
        lock.lock()
        state.searchHistory.removeAll { $0 == keyword }
        lock.unlock()
        saveData()
    }

    public func clearSearchHistory() {
        lock.lock()
        state.searchHistory = []
        lock.unlock()
        saveData()
    }

    // MARK: - implicitData

    public var implicitData: [String: JSON] {
        withState { $0.implicitData }
    }

    public func implicitValue(_ key: String) -> JSON {
        withState { $0.implicitData[key] ?? .null }
    }

    public func setImplicitValue(_ key: String, _ value: JSON) {
        lock.lock()
        state.implicitData[key] = value
        lock.unlock()
        writeImplicitData()
    }

    public static let sourceTypeRegistryKey = "sourceTypeRegistry"

    /// 从备份采纳的 implicitData 键（对齐原版 syncImplicitDataKeys：
    /// 仅源类型注册表；追更任务记录是设备自己的运行历史，不采纳）。
    public static let syncImplicitDataKeys = [sourceTypeRegistryKey]

    // MARK: - 同步字段

    /// 不参与跨设备同步的设备本地设置键。与 Flutter 版 `_disableSync` 一致，
    /// 增删必须两侧同步修改。
    public static let disableSync: Set<String> = [
        "proxy",
        "authorizationRequired",
        "appLockType",
        "appLockCredential",
        "batteryOptimizationPrompted",
        "customImageProcessing",
        "webdav",
        "disableSyncFields",
        "deviceId",
        "followUpdatesFolder",
        "followUpdatesFolders",
        "followUpdatesAllFolders",
        "followUpdatesFoldersMigrated",
        "syncLocalComics",
        "syncLocalComicImages",
        "appLauncherIcon",
        "comicSourceProvenance",
        "readerNightMode",
        "verboseNetworkLog",
        "enablePredictiveBack",
        "imageTranslationPerformancePreset",
        "imageTranslationPreBatchPages",
        "imageTranslationOcrWorkers",
        "imageTranslationImageConcurrency",
        "imageTranslationLlmConcurrency",
    ]

    public static func syncDisabledFields(_ customFields: [String]) -> Set<String> {
        var fields = disableSync
        for field in customFields where !field.isEmpty {
            fields.insert(field)
        }
        return fields
    }

    public static func splitField(_ merged: String) -> [String] {
        merged.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 加载与保存

    /// 加载 appdata.json / implicitData.json。文件损坏时重置（对齐原版）。
    public func load() {
        let dataPath = AppPaths.dataPath
        let file = AppPaths.join(dataPath, "appdata.json")
        if FileIO.exists(file) {
            if let text = try? String(contentsOfFile: file, encoding: .utf8),
               let json = JSON.decode(text)
            {
                lock.lock()
                if case .object(let settings) = json["settings"] {
                    for (key, value) in settings where !value.isNull {
                        state.settings[key] = value
                    }
                }
                if case .array(let history) = json["searchHistory"] {
                    state.searchHistory = history.compactMap { $0.stringValue }
                }
                lock.unlock()
            } else {
                Log.error("Appdata", "Failed to load appdata")
                Log.info("Appdata", "Resetting appdata")
                FileIO.deleteIgnoringErrors(file)
            }
        }

        if withState({ $0.settings["deviceId"]?.stringValue ?? "" }).isEmpty {
            let id = UUID().uuidString
            lock.lock()
            state.settings["deviceId"] = .string(id)
            lock.unlock()
            saveData(sync: false)
        }

        let implicitFile = AppPaths.join(dataPath, "implicitData.json")
        if FileIO.exists(implicitFile) {
            if let text = try? String(contentsOfFile: implicitFile, encoding: .utf8),
               let json = JSON.decode(text), case .object(let map) = json
            {
                lock.lock()
                state.implicitData = map
                lock.unlock()
            } else {
                Log.error("Appdata", "Failed to load implicit data")
                Log.info("Appdata", "Resetting implicit data")
                FileIO.deleteIgnoringErrors(implicitFile)
            }
        }
        Log.syncVerboseNetwork(withState { $0.settings["verboseNetworkLog"]?.boolValue ?? false })
    }

    /// 保存 appdata.json 与 syncdata.json。`sync` 表示该变更是否应触发
    /// WebDAV 自动上传（M5 接入 DataSync）。
    public func saveData(sync: Bool = true) {
        ioQueue.sync {
            let snapshot = withState { $0 }
            do {
                let json: JSON = .object([
                    "settings": .object(snapshot.settings),
                    "searchHistory": .array(snapshot.searchHistory.map { .string($0) }),
                ])
                let data = try json.encodedString()
                try FileIO.writeStringAtomic(AppPaths.join(AppPaths.dataPath, "appdata.json"), data)

                var syncSettings = snapshot.settings
                let customFields = Self.splitField(syncSettings["disableSyncFields"]?.stringValue ?? "")
                for field in Self.syncDisabledFields(customFields) {
                    syncSettings.removeValue(forKey: field)
                }
                let syncJSON: JSON = .object([
                    "settings": .object(syncSettings),
                    "searchHistory": .array(snapshot.searchHistory.map { .string($0) }),
                ])
                try FileIO.writeStringAtomic(
                    AppPaths.join(AppPaths.dataPath, "syncdata.json"),
                    try syncJSON.encodedString()
                )
            } catch {
                Log.error("Appdata", "Failed to save appdata", error)
            }
        }
        if sync {
            // realtime 档自动上传（DataSync 内部按档位/配置/回放状态门控）。
            DataSync.shared.noteLocalChange()
        }
    }

    public func writeImplicitData() {
        ioQueue.sync {
            let implicit = withState { $0.implicitData }
            do {
                try FileIO.writeStringAtomic(
                    AppPaths.join(AppPaths.dataPath, "implicitData.json"),
                    try JSON.object(implicit).encodedString()
                )
            } catch {
                Log.error("Appdata", "Failed to save implicit data", error)
            }
        }
    }

    /// 从另一台设备同步来的数据（下载/导入路径）。
    /// 对齐原版 `syncData`：不采纳设备本地键、dataVersion 只进不退、
    /// 最后以 sync=false 保存（避免把刚下载的数据立刻推回服务器）。
    public func syncData(_ data: JSON) {
        var changedKeys: [String] = []
        if case .object(let settings) = data["settings"] {
            let customDisableSync = Self.splitField(self.settings["disableSyncFields"].stringValue ?? "")
            let disabled = Self.syncDisabledFields(customDisableSync)
            lock.lock()
            // 本地版本必须在赋值循环之前捕获（对齐原版：循环会把 dataVersion
            // 一并覆盖，merge 需要的是覆盖前的本地值）。
            let localVersion = state.settings["dataVersion"]?.intValue ?? 0
            for (key, value) in settings where !disabled.contains(key) {
                if state.settings[key] != value {
                    state.settings[key] = value
                    changedKeys.append(key)
                }
            }
            let incomingVersion = settings["dataVersion"]?.intValue ?? 0
            // 总是写回 merge 结果：循环可能已把 dataVersion 覆盖为外来值，
            // 这里必须以覆盖前的本地版本为基准回写（对齐原版无条件赋值）。
            let merged = SyncProtocol.mergeIncomingDataVersion(localVersion, incomingVersion)
            state.settings["dataVersion"] = .int(merged)
            if merged != localVersion {
                changedKeys.append("dataVersion")
            }
            lock.unlock()
        }
        if case .array(let history) = data["searchHistory"] {
            lock.lock()
            state.searchHistory = history.compactMap { $0.stringValue }
            lock.unlock()
        }
        if case .object(let syncedImplicit) = data["implicitData"] {
            var implicitChanged = false
            lock.lock()
            for key in Self.syncImplicitDataKeys where syncedImplicit[key] != nil {
                state.implicitData[key] = syncedImplicit[key]!
                implicitChanged = true
            }
            lock.unlock()
            if implicitChanged {
                writeImplicitData()
            }
        }
        for key in changedKeys {
            onSettingsChanged.emit(key)
        }
        saveData(sync: false)
    }
}

/// 轻量回调注册表（任意线程 emit；注册方自行处理线程）。
public final class CallbackRegistry<Arg: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (Arg) -> Void] = [:]

    public init() {}

    @discardableResult
    public func add(_ handler: @escaping @Sendable (Arg) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    public func emit(_ arg: Arg) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current {
            handler(arg)
        }
    }
}
