import SwiftUI
import VeneraKit

struct AppUpdateCheckResult: Sendable {
    let tag: String
    let hasUpdate: Bool
}

/// Shares an in-flight release request so startup and manual checks cannot race.
actor AppUpdateChecker {
    static let shared = AppUpdateChecker()

    private var inFlight: Task<AppUpdateCheckResult, Error>?

    func check(forceRefresh: Bool = false) async throws -> AppUpdateCheckResult {
        if !forceRefresh, let inFlight {
            return try await inFlight.value
        }
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task {
            try await Self.fetchLatestRelease()
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private static func fetchLatestRelease() async throws -> AppUpdateCheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(AboutSettingsSection.repoOwner)/\(AboutSettingsSection.repoName)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tag = json?["tag_name"] as? String, !tag.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let remote = AboutSettingsSection.normalizeVersion(tag)
        return AppUpdateCheckResult(
            tag: tag,
            hasUpdate: AboutSettingsSection.compareVersion(remote, current) > 0
        )
    }
}

/// 「About」分区（对齐 settings/about.dart：版本/更新检查/仓库/免责声明；
/// 应用内指南随 M5 迁移）。
struct AboutSettingsSection: View {
    @Environment(AppState.self) private var appState
    nonisolated static let repoOwner = "Kyosee"
    nonisolated static let repoName = "VeneraX"

    @State private var isCheckingUpdate = false
    @State private var updateMessage: String?
    @State private var showDisclaimer = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "V\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .padding(.top, 8)
                    Text(verbatim: appVersion)
                        .font(.callout.weight(.medium))
                    Text("VeneraX is a free and open-source, multi-platform comic reader forked from Venera and maintained with enhancements over the original.".tl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                SettingActionRow(
                    title: "Check for updates".tl,
                    subtitle: updateMessage ?? appState.startupUpdateTag.map {
                        "New version available".tl + ": \($0)"
                    },
                    actionTitle: isCheckingUpdate ? "…" : "Check".tl
                ) {
                    checkUpdate()
                }
                SettingToggleRow(
                    title: "Check for updates on startup".tl,
                    key: "checkUpdateOnStart",
                    defaultValue: true
                )
            }
            Section {
                NavigationLink {
                    GuideView()
                } label: {
                    HStack {
                        Text("Guide".tl)
                        Spacer()
                        Image(systemName: "book.pages")
                    }
                }
                Link(destination: URL(string: "https://github.com/\(Self.repoOwner)/\(Self.repoName)")!) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Repository".tl)
                            Text(verbatim: "\(Self.repoOwner)/\(Self.repoName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "safari")
                    }
                }
                Button {
                    showDisclaimer = true
                } label: {
                    HStack {
                        Text("User Agreement & Disclaimer".tl)
                        Spacer()
                        Image(systemName: "info.circle")
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("About".tl)
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerSheet()
        }
    }

    /// GitHub Release 检查（对齐 checkUpdateUi：版本比较 + changelog 提示）。
    private func checkUpdate() {
        isCheckingUpdate = true
        updateMessage = nil
        Task {
            do {
                let result = try await AppUpdateChecker.shared.check(forceRefresh: true)
                isCheckingUpdate = false
                updateMessage = result.hasUpdate
                    ? "New version available".tl + ": \(result.tag)"
                    : "No updates".tl
            } catch {
                isCheckingUpdate = false
                updateMessage = error.localizedDescription
            }
        }
    }

    /// tag → 版本号（去 v 前缀与预发布后缀）。
    nonisolated static func normalizeVersion(_ tag: String) -> String {
        var text = tag
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let dash = text.firstIndex(of: "-") {
            text = String(text[..<dash])
        }
        return text
    }

    /// 逐段数值比较；段数不足补 0。返回 >0 表示 a 更新。
    nonisolated static func compareVersion(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(aParts.count, bParts.count) {
            let left = index < aParts.count ? aParts[index] : 0
            let right = index < bParts.count ? bParts[index] : 0
            if left != right { return left - right }
        }
        return 0
    }
}

/// 用户协议与免责声明（对齐 disclaimer.dart 的核心条款摘要）。
struct DisclaimerSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, body: String)] = [
        ("1. Nature of the Software",
         "This software is a user-configurable, local content reading tool that only provides technical capabilities such as network access, content parsing, reading layout, and local data management. The code is provided \"AS IS\", without warranty of any kind. By default, this software does not pre-configure, bundle, or provide any third-party website content, data resources, or parsing extensions. This project is for personal learning and research only and is a non-profit open-source project."),
        ("2. Extensions and User Conduct",
         "The online reading capability is implemented as a JavaScript-extension-compatible API. Whether and which extensions are loaded is entirely up to the user to configure lawfully, and the user shall independently judge and bear full responsibility for their origin, legality, accuracy, and applicability. Users must comply with the laws and regulations of their jurisdiction and the terms of service and copyright policies of the relevant websites."),
        ("3. Third-Party Platforms and Communities",
         "Any extension-sharing platform, website, forum, or chat group established or maintained by third parties is an independently operated third party with no affiliation to this project. This project has not established and does not operate any official community, group, or public account."),
        ("4. Privacy and Data",
         "All features of this software run on the user's local device. This project operates no server, does not collect or upload any user data to the maintainers, and integrates no analytics, crash-reporting, or telemetry components. WebDAV sync transmits data only to a server configured by the user."),
        ("5. Intellectual Property",
         "This project respects intellectual property rights. This project neither hosts nor controls any third-party extension or the third-party content parsed or presented by extensions. This project does not accept issues or technical-support requests concerning third-party website content, extension configuration, or copyright ownership."),
        ("6. Limitation of Liability",
         "To the maximum extent permitted by applicable law, this project and its maintainers shall not be liable for any direct, indirect, incidental, special, punitive, or consequential losses arising from the use of or inability to use this software, or from third-party extensions, third-party websites, network conditions, data loss, or similar causes."),
        ("7. Derivative Work and Redistribution",
         "This project is a modified version of Venera, independently developed and published by this project's maintainers. Any version modified, built, or distributed from this project's source code is the sole responsibility of whoever publishes that version. Only the builds provided on this repository's Release page are published by this project."),
        ("8. Miscellaneous",
         "Do not promote or advertise this project on any public or official platforms or official account areas. By downloading, copying, modifying, or using this project, you are deemed to have read and accepted this disclaimer in its entirety. The maintainers reserve the right to modify or supplement this disclaimer at any time, effective upon publication."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.callout.weight(.semibold))
                            Text(section.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("User Agreement & Disclaimer".tl)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK".tl) { dismiss() }
                }
            }
        }
    }
}
