import SwiftUI
import VeneraKit

/// 「Reading settings」分区（对齐 settings/reader.dart）。
/// 默认全局作用域（设置页）；从阅读器以漫画上下文打开时提供
/// 「每部漫画独立设置」开关，行读写经 ReaderSettingScope 按上游语义分流：
/// 生效值 = 漫画级 → 设备级 → 全局；写入 = 漫画开 → 漫画级，设备开 → 设备级，否则全局。
/// AI 翻译组按里程碑延后（界面在位，功能走 M7）。
struct ReaderSettingsSection: View {
    var scope: ReaderSettingScope = .global

    @State private var readerMode: String
    @State private var refreshID = UUID()

    init(scope: ReaderSettingScope = .global) {
        self.scope = scope
        _readerMode = State(initialValue: scope.effective("readerMode").stringValue ?? "galleryLeftToRight")
    }

    var body: some View {
        Form {
            scopeGroup
            readingGroup
            gestureGroup
            favoritesGroup
            imageProcessingGroup
            imageTranslationGroup
            displayGroup
        }
        .navigationTitle("Reading settings".tl)
        .id(refreshID)
    }

    private func refresh() {
        refreshID = UUID()
    }

    /// 作用域开关区：漫画上下文显示「每部漫画独立设置」，全局页显示「设备独立设置」。
    @ViewBuilder
    private var scopeGroup: some View {
        Section {
            if scope.hasComicContext {
                Toggle(isOn: Binding(
                    get: { scope.isComicEnabled },
                    set: {
                        AppData.shared.settings.setComicSpecificSettingsEnabled(
                            comicId: scope.comicId ?? "",
                            sourceKey: scope.sourceKey ?? "",
                            enabled: $0
                        )
                        AppData.shared.saveData()
                        refresh()
                    }
                )) {
                    Text("Enable comic specific settings".tl)
                    Text("Overrides global reading settings for this comic only".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if scope.isComicEnabled {
                    SettingActionRow(
                        title: "Reset comic reading settings".tl,
                        actionTitle: "Reset".tl
                    ) {
                        AppData.shared.settings.resetComicReaderSettings(
                            comicId: scope.comicId ?? "",
                            sourceKey: scope.sourceKey ?? ""
                        )
                        AppData.shared.saveData()
                        refresh()
                    }
                }
            } else {
                Toggle(isOn: Binding(
                    get: { scope.isDeviceEnabled },
                    set: {
                        AppData.shared.settings.setDeviceSpecificSettingsEnabled($0)
                        AppData.shared.saveData()
                        refresh()
                    }
                )) {
                    Text("Use device-specific settings".tl)
                    Text("Edits below are stored for this device only".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if scope.isDeviceEnabled {
                    SettingActionRow(
                        title: "Reset device reading settings".tl,
                        actionTitle: "Reset".tl
                    ) {
                        AppData.shared.settings.resetDeviceReaderSettings()
                        AppData.shared.saveData()
                        refresh()
                    }
                }
            }
        }
    }

    private var isGalleryMode: Bool { readerMode.hasPrefix("gallery") }
    private var isContinuousMode: Bool { readerMode.hasPrefix("continuous") }

    // MARK: - 阅读组

    @ViewBuilder
    private var readingGroup: some View {
        Section("Reading settings".tl) {
            SettingToggleRow(title: "Page animation".tl, key: "enablePageAnimation", defaultValue: true, scope: scope)
            Picker("Reading mode".tl, selection: Binding(
                get: { readerMode },
                set: {
                    scope.write("readerMode", value: .string($0))
                    AppData.shared.saveData()
                    if $0.hasPrefix("continuous") {
                        // 连续模式单屏单页（对齐原版联动：写全局键）。
                        AppData.shared.settings["readerScreenPicNumberForLandscape"] = .int(1)
                        AppData.shared.settings["readerScreenPicNumberForPortrait"] = .int(1)
                        AppData.shared.saveData()
                    }
                    readerMode = $0
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
                defaultValue: true,
                scope: scope
            )
            if isGalleryMode {
                SettingSliderRow(
                    title: "The number of pic in screen for landscape (Only Gallery Mode)".tl,
                    key: "readerScreenPicNumberForLandscape",
                    min: 1, max: 5, step: 1, defaultValue: 1,
                    scope: scope
                )
                SettingSliderRow(
                    title: "The number of pic in screen for portrait (Only Gallery Mode)".tl,
                    key: "readerScreenPicNumberForPortrait",
                    min: 1, max: 5, step: 1, defaultValue: 1,
                    scope: scope
                )
            }
            if isGalleryMode {
                let landscape = scope.effective("readerScreenPicNumberForLandscape").intValue ?? 1
                let portrait = scope.effective("readerScreenPicNumberForPortrait").intValue ?? 1
                if landscape > 1 || portrait > 1 {
                    SettingToggleRow(
                        title: "Show single image on first page".tl,
                        key: "showSingleImageOnFirstPage",
                        defaultValue: false,
                        scope: scope
                    )
                }
                SettingToggleRow(
                    title: "Fill screen".tl,
                    key: "galleryFillScreen",
                    subtitle: "Crop image to fill screen instead of letterboxing".tl,
                    defaultValue: false,
                    scope: scope
                )
            }
            SettingSliderRow(
                title: "Auto page turning interval".tl,
                key: "autoPageTurningInterval",
                min: 1, max: 20, step: 1, defaultValue: 5,
                scope: scope
            )
            if isContinuousMode {
                SettingSliderRow(
                    title: "Mouse scroll speed".tl,
                    key: "readerScrollSpeed",
                    min: 0.5, max: 3, step: 0.1, defaultValue: 1,
                    scope: scope
                )
            }
            if readerMode == "continuousTopToBottom" {
                SettingToggleRow(
                    title: "Center page after turning".tl,
                    key: "readerCenterPageOnTurn",
                    subtitle: "Center a short page vertically instead of pinning it to the top".tl,
                    defaultValue: false,
                    scope: scope
                )
            }
            if isContinuousMode {
                SettingSliderRow(
                    title: "Spacing between pages".tl,
                    key: "readerPageSpacing",
                    min: 0, max: 50, step: 2, defaultValue: 0,
                    scope: scope
                )
            }
            SettingToggleRow(
                title: "Remove from read later when reading starts".tl,
                key: "autoRemoveFromReadLater",
                defaultValue: false,
                scope: scope
            )
            SettingSliderRow(
                title: "Number of images preloaded".tl,
                key: "preloadImageCount",
                min: 1, max: 16, step: 1, defaultValue: 4,
                scope: scope
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
                    let enabled = scope.effective("enableTapToTurnPages").boolValue ?? true
                    let reverse = scope.effective("reverseTapToTurnPages").boolValue ?? false
                    return !enabled ? "off" : (reverse ? "reverse" : "forward")
                },
                set: { newValue in
                    scope.write("enableTapToTurnPages", value: .bool(newValue != "off"))
                    scope.write("reverseTapToTurnPages", value: .bool(newValue == "reverse"))
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
                defaultValue: true,
                scope: scope
            )
            SettingToggleRow(
                title: "Long press to zoom".tl,
                key: "enableLongPressToZoom",
                defaultValue: false,
                scope: scope
            )
            if scope.effective("enableLongPressToZoom").boolValue ?? false {
                SettingPickerRow(
                    title: "Long press zoom position".tl,
                    key: "longPressZoomPosition",
                    options: [
                        .init(value: "press", label: "Press position".tl),
                        .init(value: "center", label: "Screen center".tl),
                    ],
                    defaultValue: "press",
                    scope: scope
                )
            }
            if scope.effective("enableTapToTurnPages").boolValue ?? true {
                SettingToggleRow(
                    title: "Custom tap-to-turn zones".tl,
                    key: "enableCustomTapZones",
                    subtitle: "Choose what tapping each screen edge does".tl,
                    defaultValue: false,
                    scope: scope
                )
                if scope.effective("enableCustomTapZones").boolValue ?? false {
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
            defaultValue: defaultValue,
            scope: scope
        )
    }

    // MARK: - 收藏组

    private var favoritesGroup: some View {
        Section("Favorites settings".tl) {
            SettingToggleRow(
                title: "Also collect chapter cover when collecting image".tl,
                key: "autoFavoriteCover",
                defaultValue: false,
                scope: scope
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
                help: "On the image browsing page, you can quickly collect images by sliding horizontally or vertically according to your reading mode".tl,
                scope: scope
            )
        }
    }

    // MARK: - 图片处理组

    @ViewBuilder
    private var imageProcessingGroup: some View {
        Section("Image processing / enhancement".tl) {
            Toggle(isOn: Binding(
                get: { scope.effective("limitImageWidth").boolValue ?? false },
                set: {
                    scope.write("limitImageWidth", value: .bool($0))
                    AppData.shared.saveData()
                    refresh()
                }
            )) {
                Text("Limit image width".tl)
                Text("When using Continuous(Top to Bottom) mode".tl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if scope.effective("limitImageWidth").boolValue ?? false {
                SettingSliderRow(
                    title: "Image width (% of screen height)".tl,
                    key: "imageWidthPercent",
                    min: 40, max: 150, step: 5, defaultValue: 70,
                    scope: scope
                )
            }
            SettingToggleRow(
                title: "Image enhancement".tl,
                key: "enableReaderImageEnhance",
                subtitle: "Sharpen blurry images at render time without extra loading or battery cost".tl,
                defaultValue: false,
                scope: scope
            )
            if scope.effective("enableReaderImageEnhance").boolValue ?? false {
                SettingSliderRow(
                    title: "Sharpen strength".tl,
                    key: "readerImageEnhanceStrength",
                    min: 0, max: 10, step: 0.1, defaultValue: 0.5,
                    format: { String(format: "%.1f", $0) },
                    scope: scope
                )
                SettingSliderRow(
                    title: "Clarity".tl,
                    key: "readerImageEnhanceClarity",
                    min: 0, max: 1, step: 0.1, defaultValue: 0,
                    format: { String(format: "%.1f", $0) },
                    scope: scope
                )
                SettingSliderRow(
                    title: "Contrast".tl,
                    key: "readerImageEnhanceContrast",
                    min: 0, max: 1, step: 0.1, defaultValue: 0,
                    format: { String(format: "%.1f", $0) },
                    scope: scope
                )
                SettingSliderRow(
                    title: "Color vibrance".tl,
                    key: "readerImageEnhanceVibrance",
                    min: 0, max: 1, step: 0.1, defaultValue: 0,
                    format: { String(format: "%.1f", $0) },
                    scope: scope
                )
            }
        }
    }

    @ViewBuilder
    private var imageTranslationGroup: some View {
        Section("Image translation".tl) {
                SettingToggleRow(
                    title: "Translate comic images".tl,
                    key: "enableImageTranslation",
                    subtitle: "Recognize text with Apple Vision and show translated overlays in the reader".tl,
                    defaultValue: false,
                    scope: scope
                )
                if scope.effective("enableImageTranslation").boolValue ?? false {
                    SettingPickerRow(
                        title: "Source language".tl,
                        key: "imageTranslationSource",
                        options: [
                            .init(value: "auto", label: "Auto detect".tl),
                            .init(value: "ja", label: "Japanese".tl),
                            .init(value: "zh", label: "Chinese".tl),
                            .init(value: "en", label: "English".tl),
                            .init(value: "ko", label: "Korean".tl)
                        ],
                        defaultValue: "auto",
                        scope: scope
                    )
                    SettingPickerRow(
                        title: "Target language".tl,
                        key: "imageTranslationTarget",
                        options: [
                            .init(value: "zh", label: "Simplified Chinese".tl),
                            .init(value: "zh-TW", label: "Traditional Chinese".tl),
                            .init(value: "en", label: "English".tl),
                            .init(value: "ja", label: "Japanese".tl)
                        ],
                        defaultValue: "zh",
                        scope: scope
                    )
                    TextField("OpenAI-compatible provider URL".tl, text: SettingsBinding.string("imageTranslationLlmUrl", scope: scope))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Provider API key (optional)".tl, text: SettingsBinding.string("imageTranslationLlmKey", scope: scope))
                    TextField("Provider model (optional)".tl, text: SettingsBinding.string("imageTranslationLlmModel", scope: scope))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Leave provider URL empty to use the built-in public translation provider. Inpainting is not part of this native MVP; the original image remains visible with translated overlays.".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                defaultValue: "system",
                scope: scope
            )
            SettingToggleRow(
                title: "Night mode".tl,
                key: "readerNightMode",
                subtitle: "Dim the page with a warm overlay to reduce eye strain".tl,
                defaultValue: false,
                scope: scope
            )
            SettingToggleRow(
                title: "Follow system dark mode".tl,
                key: "readerNightModeFollowSystem",
                subtitle: "Turn night mode on/off automatically with the system theme".tl,
                defaultValue: false,
                scope: scope
            )
            let nightActive = (scope.effective("readerNightMode").boolValue ?? false)
                || (scope.effective("readerNightModeFollowSystem").boolValue ?? false)
            if nightActive {
                SettingPickerRow(
                    title: "Night mode color".tl,
                    key: "readerNightModeColor",
                    options: [
                        .init(value: "warm", label: "Warm".tl),
                        .init(value: "black", label: "Black".tl),
                        .init(value: "red", label: "Dim red".tl),
                    ],
                    defaultValue: "warm",
                    scope: scope
                )
                SettingSliderRow(
                    title: "Night mode intensity".tl,
                    key: "readerNightModeIntensity",
                    min: 0.1, max: 0.85, step: 0.05, defaultValue: 0.45,
                    format: { String(format: "%.2f", $0) },
                    scope: scope
                )
            }
            SettingToggleRow(
                title: "Display time & battery info in reader".tl,
                key: "enableClockAndBatteryInfoInReader",
                defaultValue: false,
                scope: scope
            )
            SettingToggleRow(
                title: "Show system status bar".tl,
                key: "showSystemStatusBar",
                defaultValue: false,
                scope: scope
            )
            SettingToggleRow(
                title: "Show Page Number".tl,
                key: "showPageNumberInReader",
                defaultValue: true,
                scope: scope
            )
            Toggle(isOn: Binding(
                get: { scope.effective("showChapterComments").boolValue ?? false },
                set: {
                    scope.write("showChapterComments", value: .bool($0))
                    if !$0 {
                        // 关闭章节评论时联动关闭「章末评论」（对齐原版）。
                        scope.write("showChapterCommentsAtEnd", value: .bool(false))
                    }
                    AppData.shared.saveData()
                    refresh()
                }
            )) {
                Text("Show Chapter Comments".tl)
            }
            SettingSliderRow(
                title: "Comment font size".tl,
                key: "commentsFontSize",
                min: 12, max: 24, step: 1, defaultValue: 14,
                scope: scope
            )
            if isGalleryMode, scope.effective("showChapterComments").boolValue ?? false {
                SettingToggleRow(
                    title: "Show Comments at Chapter End".tl,
                    key: "showChapterCommentsAtEnd",
                    defaultValue: false,
                    scope: scope
                )
            }
        }
    }
}
