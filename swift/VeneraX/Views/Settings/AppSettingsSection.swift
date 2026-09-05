import SwiftUI
import VeneraKit

/// 「App」分区（对齐 settings/app.dart：外观 + 首页布局 + 备选图标 + 用户/应用锁）。
struct AppSettingsSection: View {
    @State private var showLockSetup = false
    @State private var showHomeLayout = false
    @State private var lockEnabled = AppData.shared.settings["authorizationRequired"].boolValue ?? false
    @State private var currentIcon: String = UIApplication.shared.alternateIconName ?? "default"

    var body: some View {
        Form {
            Section("Appearance".tl) {
                SettingPickerRow(
                    title: "Theme Mode".tl,
                    key: "theme_mode",
                    options: [
                        .init(value: "system", label: "System".tl),
                        .init(value: "light", label: "Light".tl),
                        .init(value: "dark", label: "Dark".tl),
                    ],
                    defaultValue: "system"
                )
                SettingPickerRow(
                    title: "Theme Color".tl,
                    key: "color",
                    options: [
                        .init(value: "system", label: "System".tl),
                        .init(value: "red", label: "Red".tl),
                        .init(value: "pink", label: "Pink".tl),
                        .init(value: "purple", label: "Purple".tl),
                        .init(value: "green", label: "Green".tl),
                        .init(value: "orange", label: "Orange".tl),
                        .init(value: "blue", label: "Blue".tl),
                    ],
                    defaultValue: "system"
                )
                Button {
                    showHomeLayout = true
                } label: {
                    HStack {
                        Text("Home Layout".tl)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if UIApplication.shared.supportsAlternateIcons {
                Section("App Icon".tl) {
                    Picker("Icon".tl, selection: $currentIcon) {
                        Text("Default".tl).tag("default")
                        Text("Dark".tl).tag("AppIconDark")
                        Text("Color".tl).tag("AppIconColor")
                        Text("Retro".tl).tag("AppIconRetro")
                    }
                    .onChange(of: currentIcon) { _, newIcon in
                        let iconName = newIcon == "default" ? nil : newIcon
                        UIApplication.shared.setAlternateIconName(iconName) { error in
                            if let error {
                                Log.error("Icon", "Failed to set alternate icon: \(error)")
                            }
                        }
                    }
                }
            }

            LiveActivitySettingsSection()

            Section("User".tl) {
                SettingPickerRow(
                    title: "Language".tl,
                    key: "language",
                    options: [
                        .init(value: "system", label: "System".tl),
                        .init(value: "zh-CN", label: "简体中文"),
                        .init(value: "zh-TW", label: "繁體中文"),
                        .init(value: "en-US", label: "English"),
                    ],
                    defaultValue: "system"
                )
                Toggle(isOn: Binding(
                    get: { lockEnabled },
                    set: { enabled in
                        if enabled {
                            showLockSetup = true
                        } else {
                            lockEnabled = false
                            AppData.shared.settings["authorizationRequired"] = .bool(false)
                            AppData.shared.saveData()
                        }
                    }
                )) {
                    Text("Authorization Required".tl)
                }
                if lockEnabled {
                    SettingActionRow(
                        title: "Unlock method".tl,
                        subtitle: unlockMethodName,
                        actionTitle: "Change".tl
                    ) {
                        showLockSetup = true
                    }
                }
            }
        }
        .navigationTitle("App".tl)
        .sheet(isPresented: $showLockSetup) {
            AppLockSetupSheet {
                lockEnabled = AppData.shared.settings["authorizationRequired"].boolValue ?? false
            }
        }
        .sheet(isPresented: $showHomeLayout) {
            HomeLayoutEditorSheet()
        }
    }

    private var unlockMethodName: String {
        let type = AppData.shared.settings["appLockType"].stringValue ?? "biometric"
        return type == "biometric" ? "Biometric".tl : "PIN".tl
    }
}
