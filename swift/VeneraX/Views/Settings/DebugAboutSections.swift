import SwiftUI
import VeneraKit

/// 「Debug」分区（对齐 settings/debug.dart：重载配置/日志/忽略证书错误/JS 求值器）。
struct DebugSettingsSection: View {
    @State private var message: String?
    @State private var showLogs = false

    var body: some View {
        Form {
            Section {
                SettingActionRow(title: "Reload Configs".tl, actionTitle: "Reload".tl) {
                    Task {
                        await ComicSourceManager.shared.reloadSources()
                        message = "Config reloaded".tl
                    }
                }
                SettingActionRow(title: "Open Log".tl, actionTitle: "Open".tl) {
                    showLogs = true
                }
                SettingToggleRow(
                    title: "Ignore Certificate Errors".tl,
                    key: "ignoreBadCertificate",
                    defaultValue: false
                )
            }
            Section {
                NavigationLink("JS Evaluator".tl) {
                    JSEvaluatorView()
                }
            }
            if let message {
                Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Debug".tl)
        .sheet(isPresented: $showLogs) {
            LogViewerPage()
        }
    }
}

/// 日志查看页（分级过滤/复制/清空，对齐 LogsPage）。
struct LogViewerPage: View {
    @State private var entries: [String] = []
    @State private var levelFilter = "all"

    var body: some View {
        NavigationStack {
            List(entries.reversed(), id: \.self) { line in
                Text(verbatim: line)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            .navigationTitle("Logs".tl)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(["all", "info", "warning", "error"], id: \.self) { level in
                            Button(level) { levelFilter = level; reload() }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = entries.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close".tl) {
                        dismissLast()
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    @Environment(\.dismiss) private var dismissLast

    private func reload() {
        let all = Log.currentBuffer()
        if levelFilter == "all" {
            entries = all
        } else {
            // 行格式：`[INFO] [tag] message`（对齐 Log 输出的大写级别标签）。
            entries = all.filter { $0.contains("[\(levelFilter.uppercased())]") }
        }
    }
}

/// JS 求值器（同步执行表达式并展示结果，对齐 DebugPage 的 JS Evaluator）。
struct JSEvaluatorView: View {
    @State private var code = ""
    @State private var result = ""

    var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $code)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.4))
                )
                .padding(.horizontal)
            Button("Run".tl) { run() }
                .buttonStyle(.borderedProminent)
            Text("Result".tl)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            ScrollView {
                Text(result.isEmpty ? " " : result)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.4))
            )
            .padding(.horizontal)
        }
        .navigationTitle("JS Evaluator".tl)
    }

    private func run() {
        guard let runtime = ComicSourceManager.shared.debugRuntime else {
            result = "Runtime not attached".tl
            return
        }
        do {
            let value = try runtime.evaluate(code, name: "<debug>")
            result = value.toString()
        } catch {
            result = error.localizedDescription
        }
    }
}
