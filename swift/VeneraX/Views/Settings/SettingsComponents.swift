import SwiftUI
import VeneraKit

/// 设置项与 AppData 的绑定工具：读取当前值，写入后立即 saveData（对齐
/// 原版 SelectSetting/SwitchSetting 的即时落盘行为）。
/// 传入 scope 时走阅读设置作用域（漫画级 → 设备级 → 全局）。
enum SettingsBinding {
    static func bool(_ key: String, default def: Bool = false, scope: ReaderSettingScope? = nil) -> Binding<Bool> {
        Binding(
            get: { (scope?.effective(key) ?? AppData.shared.settings[key]).boolValue ?? def },
            set: {
                if let scope {
                    scope.write(key, value: .bool($0))
                } else {
                    AppData.shared.settings[key] = .bool($0)
                }
                AppData.shared.saveData()
            }
        )
    }

    static func string(_ key: String, default def: String = "", scope: ReaderSettingScope? = nil) -> Binding<String> {
        Binding(
            get: { (scope?.effective(key) ?? AppData.shared.settings[key]).stringValue ?? def },
            set: {
                if let scope {
                    scope.write(key, value: .string($0))
                } else {
                    AppData.shared.settings[key] = .string($0)
                }
                AppData.shared.saveData()
            }
        )
    }

    static func double(_ key: String, default def: Double = 0, scope: ReaderSettingScope? = nil) -> Binding<Double> {
        Binding(
            get: { (scope?.effective(key) ?? AppData.shared.settings[key]).doubleValue ?? def },
            set: {
                if let scope {
                    scope.write(key, value: .double($0))
                } else {
                    AppData.shared.settings[key] = .double($0)
                }
                AppData.shared.saveData()
            }
        )
    }

    static func int(_ key: String, default def: Int = 0, scope: ReaderSettingScope? = nil) -> Binding<Int> {
        Binding(
            get: { (scope?.effective(key) ?? AppData.shared.settings[key]).intValue ?? def },
            set: {
                if let scope {
                    scope.write(key, value: .int($0))
                } else {
                    AppData.shared.settings[key] = .int($0)
                }
                AppData.shared.saveData()
            }
        )
    }
}

/// Picker 选项。
struct SettingOption: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

/// 下拉选择行（对齐 SelectSetting）。
struct SettingPickerRow: View {
    let title: String
    let key: String
    let options: [SettingOption]
    var defaultValue: String?
    var help: String?
    var scope: ReaderSettingScope?
    @State private var selection: String

    private var currentValue: String {
        (scope?.effective(key) ?? AppData.shared.settings[key]).stringValue
            ?? defaultValue ?? options.first?.value ?? ""
    }

    init(
        title: String,
        key: String,
        options: [SettingOption],
        defaultValue: String? = nil,
        help: String? = nil,
        scope: ReaderSettingScope? = nil
    ) {
        self.title = title
        self.key = key
        self.options = options
        self.defaultValue = defaultValue
        self.help = help
        self.scope = scope
        let initial = (scope?.effective(key) ?? AppData.shared.settings[key]).stringValue
            ?? defaultValue ?? options.first?.value ?? ""
        _selection = State(initialValue: initial)
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                Text(verbatim: option.label).tag(option.value)
            }
        }
        .onChange(of: selection) { _, newValue in
            if let scope {
                scope.write(key, value: .string(newValue))
            } else {
                AppData.shared.settings[key] = .string(newValue)
            }
            AppData.shared.saveData()
        }
        .onAppear {
            selection = currentValue
        }
        if let help {
            Text(verbatim: help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 开关行（对齐 _SwitchSetting）。
struct SettingToggleRow: View {
    let title: String
    let key: String
    var subtitle: String?
    var defaultValue = false
    var scope: ReaderSettingScope?
    var onChange: ((Bool) -> Void)?

    var body: some View {
        Toggle(isOn: Binding(
            get: { (scope?.effective(key) ?? AppData.shared.settings[key]).boolValue ?? defaultValue },
            set: {
                if let scope {
                    scope.write(key, value: .bool($0))
                } else {
                    AppData.shared.settings[key] = .bool($0)
                }
                AppData.shared.saveData()
                onChange?($0)
            }
        )) {
            if let subtitle {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
            }
        }
    }
}

/// 滑杆行（对齐 _SliderSetting；显示格式化当前值）。
struct SettingSliderRow: View {
    let title: String
    let key: String
    let range: ClosedRange<Double>
    let step: Double
    var defaultValue: Double
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    init(
        title: String, key: String,
        min minValue: Double, max maxValue: Double, step: Double,
        defaultValue: Double,
        format: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        scope: ReaderSettingScope? = nil
    ) {
        self.title = title
        self.key = key
        self.range = minValue...maxValue
        self.step = step
        self.defaultValue = defaultValue
        self.format = format
        self.scope = scope
    }

    var scope: ReaderSettingScope?

    var body: some View {
        let binding = SettingsBinding.double(key, default: defaultValue, scope: scope)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(binding.wrappedValue))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            Slider(
                value: Binding(
                    get: { binding.wrappedValue },
                    set: { binding.wrappedValue = ($0 / step).rounded() * step }
                ),
                in: range,
                step: step
            )
        }
    }
}

/// 回调动作行（对齐 _CallbackSetting）。
struct SettingActionRow: View {
    let title: String
    var subtitle: String?
    var actionTitle: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                Text(actionTitle).foregroundStyle(.tint)
            }
        }
    }
}

/// 屏蔽词编辑页（关键词/标签/评论关键词共用，对齐 _ManageBlockListView）。
struct BlocklistEditorView: View {
    let settingKey: String
    let titleKey: String
    let hintKey: String
    @State private var entries: [String] = []
    @State private var newKeyword = ""
    @State private var showAdd = false
    @State private var duplicateError = false

    var body: some View {
        List {
            Section {
                Text(hintKey.tl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack {
                        Text(verbatim: entry)
                        Spacer()
                        Button {
                            entries.remove(at: index)
                            persist()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle(titleKey.tl)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newKeyword = ""
                    duplicateError = false
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Add keyword".tl, isPresented: $showAdd) {
            TextField("Keyword".tl, text: $newKeyword)
                .textInputAutocapitalization(.never)
            Button("Add".tl) {
                let text = newKeyword.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                if entries.contains(text) {
                    duplicateError = true
                    showAdd = true
                    return
                }
                entries.append(text)
                persist()
            }
            Button("Cancel".tl, role: .cancel) {}
        } message: {
            if duplicateError {
                Text("Keyword already exists".tl)
            }
        }
        .onAppear {
            entries = AppData.shared.settings[settingKey].arrayValue?
                .compactMap { $0.stringValue } ?? []
        }
    }

    private func persist() {
        AppData.shared.settings[settingKey] = .array(entries.map { .string($0) })
        AppData.shared.saveData()
    }
}

/// 可见页过滤编辑器（探索页/分类页/搜索源，对齐 _MultiPagesFilter：
/// 存储可见键列表，空列表 = 全部显示，顺序即显示顺序）。
struct PageFilterEditorView: View {
    let titleKey: String
    let settingKey: String
    /// id - 显示名（全部候选）。
    let pages: [(id: String, label: String)]

    @State private var selected: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Checked pages are shown; unchecked pages are hidden. The list order defines the display order.".tl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(pages, id: \.id) { page in
                    Toggle(isOn: pageBinding(page.id)) {
                        Text(verbatim: page.label)
                    }
                }
            }
        }
        .navigationTitle(titleKey.tl)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done".tl) { dismiss() }
            }
        }
        .onAppear {
            selected = AppData.shared.settings[settingKey].arrayValue?
                .compactMap { $0.stringValue } ?? []
        }
        .onDisappear { persist() }
    }

    private func pageBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on {
                    // 新增页追加到尾部（对齐原版 Add 行为）。
                    selected.append(id)
                } else {
                    selected.removeAll { $0 == id }
                }
                persist()
            }
        )
    }

    private func persist() {
        AppData.shared.settings[settingKey] = .array(selected.map { .string($0) })
        AppData.shared.saveData()
    }
}
