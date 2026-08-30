import SwiftUI
import VeneraKit

/// 「Reading settings」分区（对齐 settings/reader.dart 的全局 scope；
/// AI 翻译组按里程碑延后，每部漫画/设备独立设置入口在阅读器内提供）。
struct ReaderSettingsSection: View {
    @State private var readerMode = AppData.shared.settings["readerMode"].stringValue ?? "galleryLeftToRight"
    @State private var tapTurnForward = !(AppData.shared.settings["enableTapToTurnPages"].boolValue ?? true == false)
    @State private var refreshID = UUID()

    var body: some View {
        Form {
            readingGroup
            gestureGroup
            favoritesGroup
            imageProcessingGroup
            displayGroup
        }
        .navigationTitle("Reading settings".tl)
        .id(refreshID)
    }

    private var isGalleryMode: Bool { readerMode.hasPrefix("gallery") }
    private var isContinuousMode: Bool { readerMode.hasPrefix("continuous") }

    // MARK: - 阅读组

    @ViewBuilder
    private var readingGroup: some View {
        Section("Reading settings".tl) {
            SettingToggleRow(title: "Page animation".tl, key: "enablePageAnimation", defaultValue: true)
            Picker("Reading mode".tl, selection: Binding(
                get: { readerMode },
                set: {
                    readerMode = $0
                    AppData.shared.settings["readerMode"] = .string($0)
                    AppData.shared.saveData()
                    if $0.hasPrefix("continuous") {
                        // 连续模式单屏单页（对齐原版联动）。
                        AppData.shared.settings["readerScreenPicNumberForLandscape"] = .int(1)
                        AppData.shared.settings["readerScreenPicNumberForPortrait"] = .int(1)
                        AppData.shared.saveData()
                    }
                }
            )) {
                Text("Gallery (Left to Right)".tl).tag("galleryLeftToRight")
                Text("Gallery (Right to Left)".tl).tag("galleryRightToLeft")
                Text("Gallery (Top to Bottom)".tl).tag("galleryTopToBottom")
                Text("Continuous (Left to Right)".tl).tag("continuousLeftToRight")
                Text("Continuous (Right to Left)".tl).tag("continuousRightToLeft")
                Text("Continuous (Top to Bottom)".tl).tag("continuousTopToBottom")
            }
            SettingToggleRow(
                title: "Seamless chapter reading".tl,
                key: "enableContinuousChapterReading",
                subtitle: "Join chapters in continuous reading modes".tl,
                defaultValue: true
            )
            if isGalleryMode {
                SettingSliderRow(
                    title: "The number of pic in screen for landscape (Only Gallery Mode)".tl,
                    key: "readerScreenPicNumberForLandscape",
                    min: 1, max: 5, step: 1, defaultValue: 1
                )
                SettingSliderRow(
                    title: "The number of pic in screen for portrait (Only Gallery Mode)".tl,
                    key: "readerScreenPicNumberForPortrait",
                    min: 1, max: 5, step: 1, defaultValue: 1
                )
            }
            if isGalleryMode {
                let landscape = AppData.shared.settings["readerScreenPicNumberForLandscape"].intValue ?? 1
                let portrait = AppData.shared.settings["readerScreenPicNumberForPortrait"].intValue ?? 1
                if landscape > 1 || portrait > 1 {
                    SettingToggleRow(
                        title: "Show single image on first page".tl,
                        key: "showSingleImageOnFirstPage",
                        defaultValue: false
                    )
                }
                SettingToggleRow(
                    title: "Fill screen".tl,
                    key: "galleryFillScreen",
                    subtitle: "Crop image to fill screen instead of letterboxing".tl,
                    defaultValue: false
                )
            }
            SettingSliderRow(
                title: "Auto page turning interval".tl,
                key: "autoPageTurningInterval",
                min: 1, max: 20, step: 1, defaultValue: 5
            )
            if isContinuousMode {
                SettingSliderRow(
                    title: "Mouse scroll speed".tl,
                    key: "readerScrollSpeed",
                    min: 0.5, max: 3, step: 0.1, defaultValue: 1
                )
            }
            if readerMode == "continuousTopToBottom" {
                SettingToggleRow(
                    title: "Center page after turning".tl,
                    key: "readerCenterPageOnTurn",
                    subtitle: "Center a short page vertically instead of pinning it to the top".tl,
                    defaultValue: false
                )
            }
            if isContinuousMode {
                SettingSliderRow(
                    title: "Spacing between pages".tl,
                    key: "readerPageSpacing",
                    min: 0, max: 50, step: 2, defaultValue: 0
                )
            }
            SettingToggleRow(
                title: "Remove from read later when reading starts".tl,
                key: "autoRemoveFromReadLater",
                defaultValue: false
            )
            SettingSliderRow(
                title: "Number of images preloaded".tl,
                key: "preloadImageCount",
                min: 1, max: 16, step: 1, defaultValue: 4
            )
        }
    }

    // MARK: - 手势组

    @ViewBuilder
    private var gestureGroup: some View {
        Section("Gesture settings".tl) {
            // 点区翻页三态（对齐 _PageTurnModeSetting：off/forward/reverse）。
            Picker("Tap to turn pages".tl, selection: Binding(
                get: {
                    let enabled = AppData.shared.settings["enableTapToTurnPages"].boolValue ?? true
                    let reverse = AppData.shared.settings["reverseTapToTurnPages"].boolValue ?? false
                    return !enabled ? "off" : (reverse ? "reverse" : "forward")
                },
                set: { newValue in
                    AppData.shared.settings["enableTapToTurnPages"] = .bool(newValue != "off")
                    AppData.shared.settings["reverseTapToTurnPages"] = .bool(newValue == "reverse")
                    AppData.shared.saveData()
                }
            )) {
                Text("Off".tl).tag("off")
                Text("Forward".tl).tag("forward")
                Text("Reverse".tl).tag("reverse")
            }
            SettingToggleRow(
                title: "Double tap to zoom".tl,
                key: "enableDoubleTapToZoom",
                defaultValue: true
            )
            SettingToggleRow(
                title: "Long press to zoom".tl,
                key: "enableLongPressToZoom",
                defaultValue: false
            )
            if AppData.shared.settings["enableLongPressToZoom"].boolValue ?? false {
                SettingPickerRow(
                    title: "Long press zoom position".tl,
                    key: "longPressZoomPosition",
                    options: [
                        .init(value: "press", label: "Press position".tl),
                        .init(value: "center", label: "Screen center".tl),
                    ],
                    defaultValue: "press"
                )
            }
            if AppData.shared.settings["enableTapToTurnPages"].boolValue ?? true {
                SettingToggleRow(
                    title: "Custom tap-to-turn zones".tl,
                    key: "enableCustomTapZones",
                    subtitle: "Choose what tapping each screen edge does".tl,
                    defaultValue: false
                )
                if AppData.shared.settings["enableCustomTapZones"].boolValue ?? false {
                    tapZonePicker("Top edge tap".tl, key: "tapZoneTop", defaultValue: "prev")
                    tapZonePicker("Bottom edge tap".tl, key: "tapZoneBottom", defaultValue: "next")
                    tapZonePicker("Left edge tap".tl, key: "tapZoneLeft", defaultValue: "none")
                    tapZonePicker("Right edge tap".tl, key: "tapZoneRight", defaultValue: "none")
                }
            }
        }
    }

    private func tapZonePicker(_ title: String, key: String, defaultValue: String) -> some View {
        SettingPickerRow(
            title: title,
            key: key,
            options: [
                .init(value: "prev", label: "Previous page".tl),
                .init(value: "next", label: "Next page".tl),
                .init(value: "none", label: "No action".tl),
            ],
            defaultValue: defaultValue
        )
    }

    // MARK: - 收藏组

    private var favoritesGroup: some View {
        Section("Favorites settings".tl) {
            SettingToggleRow(
                title: "Also collect chapter cover when collecting image".tl,
                key: "autoFavoriteCover",
                defaultValue: false
            )
            SettingPickerRow(
                title: "Quick collect image".tl,
                key: "quickCollectImage",
                options: [
                    .init(value: "No", label: "Not enable".tl),
                    .init(value: "DoubleTap", label: "Double Tap".tl),
                    .init(value: "Swipe", label: "Swipe".tl),
                ],
                defaultValue: "No",
                help: "On the image browsing page, you can quickly collect images by sliding horizontally or vertically according to your reading mode".tl
            )
        }
    }

    // MARK: - 图片处理组

    @ViewBuilder
    private var imageProcessingGroup: some View {
        Section("Image processing / enhancement".tl) {
            Toggle(isOn: Binding(
                get: { AppData.shared.settings["limitImageWidth"].boolValue ?? false },
                set: {
                    AppData.shared.settings["limitImageWidth"] = .bool($0)
                    AppData.shared.saveData()
                    refreshID = UUID()
                }
            )) {
                Text("Limit image width".tl)
                Text("When using Continuous(Top to Bottom) mode".tl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if AppData.shared.settings["limitImageWidth"].boolValue ?? false {
                SettingSliderRow(
                    title: "Image width (% of screen height)".tl,
                    key: "imageWidthPercent",
                    min: 40, max: 150, step: 5, defaultValue: 70
                )
            }
            SettingToggleRow(
                title: "Image enhancement".tl,
                key: "enableReaderImageEnhance",
                subtitle: "Sharpen blurry images at render time without extra loading or battery cost".tl,
                defaultValue: false
            )
            if AppData.shared.settings["enableReaderImageEnhance"].boolValue ?? false {
                SettingSliderRow(
                    title: "Sharpen strength".tl,
                    key: "readerImageEnhanceStrength",
                    min: 0, max: 10, step: 0.1, defaultValue: 0.5,
                    format: { String(format: "%.1f", $0) }
                )
                SettingSliderRow(
                    title: "Clarity".tl,
                    key: "readerImageEnhanceClarity",
                    min: 0, max: 1, step: 0.1, defaultValue: 0,
                    format: { String(format: "%.1f", $0) }
                )
                SettingSliderRow(
                    title: "Contrast".tl,
                    key: "readerImageEnhanceContrast",
                    min: 0, max: 1, step: 0.1, defaultValue: 0,
                    format: { String(format: "%.1f", $0) }
                )
                SettingSliderRow(
                    title: "Color vibrance".tl,
                    key: "readerImageEnhanceVibrance",
                    min: 0, max: 1, step: 0.1, defaultValue: 0,
                    format: { String(format: "%.1f", $0) }
                )
            }
        }
    }

    // MARK: - 显示组

    @ViewBuilder
    private var displayGroup: some View {
        Section("Display settings".tl) {
            SettingPickerRow(
                title: "Reading background color".tl,
                key: "readerBackgroundColor",
                options: [
                    .init(value: "system", label: "Follow theme".tl),
                    .init(value: "white", label: "White".tl),
                    .init(value: "gray", label: "Gray".tl),
                    .init(value: "black", label: "Black".tl),
                    .init(value: "sepia", label: "Sepia".tl),
                    .init(value: "green", label: "Eye-care green".tl),
                ],
                defaultValue: "system"
            )
            SettingToggleRow(
                title: "Night mode".tl,
                key: "readerNightMode",
                subtitle: "Dim the page with a warm overlay to reduce eye strain".tl,
                defaultValue: false
            )
            SettingToggleRow(
                title: "Follow system dark mode".tl,
                key: "readerNightModeFollowSystem",
                subtitle: "Turn night mode on/off automatically with the system theme".tl,
                defaultValue: false
            )
            let nightActive = (AppData.shared.settings["readerNightMode"].boolValue ?? false)
                || (AppData.shared.settings["readerNightModeFollowSystem"].boolValue ?? false)
            if nightActive {
                SettingPickerRow(
                    title: "Night mode color".tl,
                    key: "readerNightModeColor",
                    options: [
                        .init(value: "warm", label: "Warm".tl),
                        .init(value: "black", label: "Black".tl),
                        .init(value: "red", label: "Dim red".tl),
                    ],
                    defaultValue: "warm"
                )
                SettingSliderRow(
                    title: "Night mode intensity".tl,
                    key: "readerNightModeIntensity",
                    min: 0.1, max: 0.85, step: 0.05, defaultValue: 0.45,
                    format: { String(format: "%.2f", $0) }
                )
            }
            SettingToggleRow(
                title: "Display time & battery info in reader".tl,
                key: "enableClockAndBatteryInfoInReader",
                defaultValue: false
            )
            SettingToggleRow(
                title: "Show system status bar".tl,
                key: "showSystemStatusBar",
                defaultValue: false
            )
            SettingToggleRow(
                title: "Show Page Number".tl,
                key: "showPageNumberInReader",
                defaultValue: true
            )
            Toggle(isOn: Binding(
                get: { AppData.shared.settings["showChapterComments"].boolValue ?? false },
                set: {
                    AppData.shared.settings["showChapterComments"] = .bool($0)
                    if !$0 {
                        // 关闭章节评论时联动关闭「章末评论」（对齐原版）。
                        AppData.shared.settings["showChapterCommentsAtEnd"] = .bool(false)
                    }
                    AppData.shared.saveData()
                    refreshID = UUID()
                }
            )) {
                Text("Show Chapter Comments".tl)
            }
            SettingSliderRow(
                title: "Comment font size".tl,
                key: "commentsFontSize",
                min: 12, max: 24, step: 1, defaultValue: 14
            )
            if isGalleryMode, AppData.shared.settings["showChapterComments"].boolValue ?? false {
                SettingToggleRow(
                    title: "Show Comments at Chapter End".tl,
                    key: "showChapterCommentsAtEnd",
                    defaultValue: false
                )
            }
        }
    }
}
