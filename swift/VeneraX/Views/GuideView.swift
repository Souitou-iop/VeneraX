import SwiftUI

/// 离线使用说明。文档直接复用仓库中的 guide.zh.md / guide.en.md，避免
/// 应用内帮助内容与项目文档长期分叉。
struct GuideView: View {
    @State private var document: AttributedString?
    @State private var failed = false

    private var resourceName: String {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return language == "zh" ? "guide.zh" : "guide.en"
    }

    var body: some View {
        ScrollView {
            if let document {
                Text(document)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if failed {
                ContentUnavailableView {
                    Label("Guide unavailable".tl, systemImage: "book.closed")
                } description: {
                    Text("The offline guide could not be loaded.".tl)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .padding(.horizontal)
        .navigationTitle("Guide".tl)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard document == nil, !failed else { return }
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let parsed = try? AttributedString(markdown: text) else {
                failed = true
                return
            }
            document = parsed
        }
    }
}
