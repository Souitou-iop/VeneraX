#if DEBUG
@preconcurrency import ActivityKit
import SwiftUI

/// Explicit opt-in visual fixture. It never creates real downloads, touches user
/// settings, or runs in Release. System ActivityKit still renders the extension.
struct LiveActivityPreviewHost: View {
    @State private var result = "Starting visual fixture…"
    @State private var coverName = ""
    @State private var activity: Activity<VeneraTaskActivityAttributes>?

    var body: some View {
        VStack(spacing: 20) {
            Text("Live Activity QA").font(.title)
            Text("Synthetic task — not a real download").font(.caption)
            Text(result)
            ForEach(["running", "paused", "stale", "failed", "completed"], id: \.self) { value in
                Button(value) { Task { await display(value) } }
            }
        }
        .task {
            prepareCover()
            await display("running")
        }
    }

    @MainActor
    private func prepareCover() {
        let name = UUID().uuidString + ".jpg"
        guard let file = VeneraTaskActivityAttributes.coverFile(name) else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 128), format: format).image { _ in
            UIColor.systemIndigo.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 96, height: 128))
            ("QA" as NSString).draw(at: CGPoint(x: 16, y: 44), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.white
            ])
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.jpegData(compressionQuality: 0.8)?.write(to: file, options: .atomic)
            coverName = name
        } catch { result = "Shared cover unavailable" }
    }

    @MainActor
    private func display(_ value: String) async {
        typealias Attributes = VeneraTaskActivityAttributes
        let status = Attributes.Status(rawValue: value) ?? .running
        let state = Attributes.ContentState(
            activityTitle: "预翻译", title: "测试漫画 · 长标题排版与状态验证", subtitle: "当前任务",
            phase: status == .paused ? "已暂停" : (status == .failed ? "部分页面失败" : "第 126 话 · 翻译中"),
            coverURL: coverName, progress: status == .completed ? 1 : 0.68,
            current: status == .completed ? 50 : 34, total: 50, queueCount: 1,
            status: status, failedCount: status == .failed ? 3 : 0)
        let content = ActivityContent(state: state, staleDate: value == "stale" ? Date().addingTimeInterval(-1) : nil)
        do {
            if let activity {
                if status == .completed {
                    await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(45)))
                    self.activity = nil
                } else { await activity.update(content) }
            } else {
                for old in Activity<Attributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
                activity = try Activity.request(attributes: Attributes(id: "visual-fixture", kind: .preTranslation), content: content, pushType: nil)
            }
            result = "ActivityKit: \(value)"
        } catch { result = error.localizedDescription }
    }
}
#endif
