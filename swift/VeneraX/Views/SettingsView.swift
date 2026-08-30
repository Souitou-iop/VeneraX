import SwiftUI
import VeneraKit

/// 设置入口（Tab 根）：8 分区导航 + 设置搜索（见 Settings/SettingsHome.swift）。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            SettingsHome()
        }
    }
}
