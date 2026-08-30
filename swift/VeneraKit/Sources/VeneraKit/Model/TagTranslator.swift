import Foundation

/// 标签翻译字典管理器（对齐原版 tags.json, tags_tw.json 与 tagsTranslate 逻辑）。
/// 支持按 namespace（female, male, parody, character, language, artist, group, other 等）精准翻译
/// 或全局模糊匹配翻译。
public final class TagTranslator: @unchecked Sendable {
    public static let shared = TagTranslator()

    private let lock = NSLock()
    private var cnDict: [String: [String: String]] = [:]
    private var twDict: [String: [String: String]] = [:]
    private var isLoaded = false

    private init() {
        loadDictionaries()
    }

    public func loadDictionaries() {
        lock.lock()
        defer { lock.unlock() }
        if isLoaded { return }

        // 尝试从 Bundle 加载 tags.json 与 tags_tw.json
        if let cnURL = Bundle.main.url(forResource: "tags", withExtension: "json"),
           let cnData = try? Data(contentsOf: cnURL),
           let cnJSON = JSON.decode(String(data: cnData, encoding: .utf8) ?? "") {
            cnDict = parseDict(cnJSON)
        }

        if let twURL = Bundle.main.url(forResource: "tags_tw", withExtension: "json"),
           let twData = try? Data(contentsOf: twURL),
           let twJSON = JSON.decode(String(data: twData, encoding: .utf8) ?? "") {
            twDict = parseDict(twJSON)
        }

        isLoaded = !cnDict.isEmpty
    }

    /// 手动载入字典数据（供单元测试或无 Bundle 场景注入）。
    public func loadRaw(cnJson: String, twJson: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let json = JSON.decode(cnJson) {
            cnDict = parseDict(json)
        }
        if let twJson = twJson, let json = JSON.decode(twJson) {
            twDict = parseDict(json)
        }
        isLoaded = true
    }

    private func parseDict(_ json: JSON) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        guard let root = json.objectValue else { return result }
        for (ns, group) in root {
            guard let map = group.objectValue else { continue }
            var sub: [String: String] = [:]
            for (k, v) in map {
                if let str = v.stringValue {
                    sub[k.lowercased()] = str
                }
            }
            result[ns.lowercased()] = sub
        }
        return result
    }

    /// 翻译标签。
    public func translate(_ tag: String, namespace: String? = nil) -> String {
        let isEnabled = AppData.shared.settings["enableTagsTranslate"].boolValue ?? true
        guard isEnabled else { return tag }

        lock.lock()
        let dict = AppData.shared.settings["language"].stringValue == "zh-TW" ? (twDict.isEmpty ? cnDict : twDict) : cnDict
        lock.unlock()

        guard !dict.isEmpty else { return tag }
        let lowerTag = tag.lowercased().trimmingCharacters(in: .whitespaces)

        // 1. 如果指定了 namespace，先在对应 namespace 中查找
        if let ns = namespace?.lowercased().trimmingCharacters(in: .whitespaces), let nsMap = dict[ns] {
            if let translated = nsMap[lowerTag] {
                return translated
            }
        }

        // 2. 在全局各 namespace 中查找匹配
        for (_, nsMap) in dict {
            if let translated = nsMap[lowerTag] {
                return translated
            }
        }

        return tag
    }

    /// 翻译 Namespace（例如 female -> 女性, parody -> 原作, language -> 语言）。
    public func translateNamespace(_ namespace: String) -> String {
        let lower = namespace.lowercased().trimmingCharacters(in: .whitespaces)
        lock.lock()
        let dict = AppData.shared.settings["language"].stringValue == "zh-TW" ? (twDict.isEmpty ? cnDict : twDict) : cnDict
        lock.unlock()

        if let rows = dict["rows"], let translated = rows[lower] {
            return translated
        }

        switch lower {
        case "female": return "女性"
        case "male": return "男性"
        case "parody": return "原作"
        case "character": return "角色"
        case "language": return "语言"
        case "artist": return "画师"
        case "group": return "团队"
        case "cosplayer": return "Coser"
        case "reclass": return "分类"
        case "mixed": return "混合"
        case "other": return "其他"
        case "tags": return "标签"
        default: return namespace
        }
    }
}

extension String {
    /// 标签本地化翻译。
    public func translatedTag(namespace: String? = nil) -> String {
        TagTranslator.shared.translate(self, namespace: namespace)
    }

    /// 分类命名空间本地化翻译。
    public var translatedNamespace: String {
        TagTranslator.shared.translateNamespace(self)
    }
}
