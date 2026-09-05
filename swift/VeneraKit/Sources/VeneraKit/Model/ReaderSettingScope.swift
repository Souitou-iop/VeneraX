import Foundation

/// 阅读设置的读写作用域路由（对齐上游 settings/reader.dart 的行级分流）：
/// - 读取一律走生效链：漫画级（有漫画上下文时）→ 设备级 → 全局；
/// - 写入分流：漫画开关开启且有漫画上下文 → 写漫画级；否则设备开关开启 → 写设备级；否则写全局。
/// 纯路由逻辑，无 UI 依赖，可单测。
public struct ReaderSettingScope: Equatable, Sendable {
    public let comicId: String?
    public let sourceKey: String?

    public init(comicId: String? = nil, sourceKey: String? = nil) {
        self.comicId = comicId
        self.sourceKey = sourceKey
    }

    /// 全局作用域（无漫画上下文）。
    public static let global = ReaderSettingScope()

    public var hasComicContext: Bool { comicId != nil && sourceKey != nil }

    public var isComicEnabled: Bool {
        guard let comicId, let sourceKey else { return false }
        return AppData.shared.settings.isComicSpecificSettingsEnabled(comicId: comicId, sourceKey: sourceKey)
    }

    public var isDeviceEnabled: Bool {
        AppData.shared.settings.isDeviceSpecificSettingsEnabled()
    }

    public func effective(_ key: String) -> JSON {
        if hasComicContext, let comicId, let sourceKey {
            return AppData.shared.settings.getReaderSetting(comicId: comicId, sourceKey: sourceKey, key: key)
        }
        return AppData.shared.settings.getDeviceReaderSetting(key: key)
    }

    public func write(_ key: String, value: JSON) {
        if isComicEnabled, let comicId, let sourceKey {
            AppData.shared.settings.setReaderSetting(comicId: comicId, sourceKey: sourceKey, key: key, value: value)
        } else if isDeviceEnabled {
            AppData.shared.settings.setDeviceReaderSetting(key: key, value: value)
        } else {
            AppData.shared.settings[key] = value
        }
    }
}
