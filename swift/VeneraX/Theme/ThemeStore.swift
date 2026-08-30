import SwiftUI
import VeneraKit

/// 主题桥接：设置键（theme_mode / color）→ SwiftUI ColorScheme 与 tint。
/// color: 'system' 使用系统强调色（资产目录 AccentColor），其余映射到
/// iOS 原生系统色（与 Material 色板对应的 iOS 等价物）。
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var themeMode: String
    private(set) var colorName: String

    private init() {
        let settings = AppData.shared.settings
        themeMode = settings["theme_mode"].stringValue ?? "system"
        colorName = settings["color"].stringValue ?? "system"
        AppData.shared.onSettingsChanged.add { [weak self] key in
            guard key == "theme_mode" || key == "color" else { return }
            let settings = AppData.shared.settings
            let mode = settings["theme_mode"].stringValue ?? "system"
            let color = settings["color"].stringValue ?? "system"
            Task { @MainActor in
                self?.themeMode = mode
                self?.colorName = color
            }
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var accent: Color {
        switch colorName {
        case "red": return .red
        case "pink": return .pink
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "blue": return .blue
        default: return .accentColor
        }
    }
}
