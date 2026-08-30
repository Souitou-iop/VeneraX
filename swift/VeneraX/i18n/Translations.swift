import Foundation
import Observation
import VeneraKit

/// 轻量国际化：与 Flutter 版同源（assets/translation.json，键为英文原文，
/// zh_CN / zh_TW 两张表；英文即键本身）。整包 `String.tl` 取词。
/// 内部状态以锁保护，可从任意线程读取；语言变更经 MainActor 发布。
@Observable
final class Translations: @unchecked Sendable {
    static let shared = Translations()

    private let lock = NSLock()
    private var tables: [String: [String: String]] = [:]
    private var languageSetting: String

    private init() {
        languageSetting = AppData.shared.settings["language"].stringValue ?? "system"
        loadTables()
        AppData.shared.onSettingsChanged.add { [weak self] key in
            guard key == "language" else { return }
            Task { @MainActor in
                self?.reload()
            }
        }
    }

    private func loadTables() {
        guard let url = Bundle.main.url(forResource: "translation", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = JSON.decode(String(data: data, encoding: .utf8) ?? ""),
              case .object(let locales) = json
        else { return }
        var result: [String: [String: String]] = [:]
        for (locale, table) in locales {
            var entries: [String: String] = [:]
            if case .object(let map) = table {
                for (key, value) in map {
                    if let text = value.stringValue {
                        entries[key] = text
                    }
                }
            }
            result[locale] = entries
        }
        lock.lock()
        tables = result
        lock.unlock()
    }

    private func reload() {
        lock.lock()
        languageSetting = AppData.shared.settings["language"].stringValue ?? "system"
        lock.unlock()
        loadTables()
    }

    private func tableForLanguage(_ code: String) -> String? {
        switch code {
        case "zh-CN": return "zh_CN"
        case "zh-TW": return "zh_TW"
        default: return nil // en-US：英文即键本身
        }
    }

    private func resolveSystemLanguage() -> String {
        for preferred in Locale.preferredLanguages {
            if preferred.hasPrefix("zh") {
                if preferred.contains("Hans") || preferred.contains("CN") || preferred.contains("SG") {
                    return "zh-CN"
                }
                return "zh-TW"
            }
            if preferred.hasPrefix("en") {
                return "en-US"
            }
        }
        return "en-US"
    }

    var currentLanguage: String {
        lock.lock()
        let setting = languageSetting
        lock.unlock()
        return setting == "system" ? resolveSystemLanguage() : setting
    }

    func t(_ key: String) -> String {
        let code = currentLanguage
        if let tableName = tableForLanguage(code) {
            lock.lock()
            let text = tables[tableName]?[key]
            lock.unlock()
            if let text { return text }
        }
        return key
    }
}

extension String {
    /// 取翻译。英文返回键本身（与原版行为一致）。
    var tl: String {
        Translations.shared.t(self)
    }
}
