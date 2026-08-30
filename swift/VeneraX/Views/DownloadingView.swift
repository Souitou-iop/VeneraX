import SwiftUI
import VeneraKit

/// 下载队列管理视图（对齐原版 downloading_page.dart）。
/// 包含实时网速汇总、每任务进度条、单任务暂停/恢复/重试/置顶与整队控制。
struct DownloadingView: View {
    @State private var tasks: [DownloadTask] = []
    @State private var showCancelAllConfirm = false
    @State private var taskPendingCancellation: DownloadTask?
    @State private var timer: Timer?

    var body: some View {
        List {
            headerSection

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No downloading tasks".tl, systemImage: "arrow.down.circle")
                } description: {
                    Text("Downloaded comics will appear in Local library".tl)
                }
            } else {
                ForEach(tasks) { task in
                    DownloadTaskRow(task: task)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                taskPendingCancellation = task
                            } label: {
                                Label("Cancel".tl, systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                DownloadManager.shared.moveToFirst(task)
                                refreshTasks()
                            } label: {
                                Label("Top".tl, systemImage: "arrow.up.to.line")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .navigationTitle("Downloading".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        DownloadManager.shared.pauseAll()
                        refreshTasks()
                    } label: {
                        Label("Pause All".tl, systemImage: "pause.fill")
                    }

                    Button {
                        DownloadManager.shared.resumeAll()
                        refreshTasks()
                    } label: {
                        Label("Resume All".tl, systemImage: "play.fill")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showCancelAllConfirm = true
                    } label: {
                        Label("Cancel All".tl, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Cancel Download?".tl, isPresented: Binding(
            get: { taskPendingCancellation != nil },
            set: { if !$0 { taskPendingCancellation = nil } }
        ), presenting: taskPendingCancellation) { task in
            Button("Cancel Download".tl, role: .destructive) {
                task.cancel()
                taskPendingCancellation = nil
                refreshTasks()
            }
            Button("Keep Downloading".tl, role: .cancel) {
                taskPendingCancellation = nil
            }
        } message: { _ in
            Text("The partial download may be removed and the task will leave the queue.".tl)
        }
        .confirmationDialog(
            "Cancel all downloading tasks?".tl,
            isPresented: $showCancelAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Confirm".tl, role: .destructive) {
                DownloadManager.shared.cancelAll()
                refreshTasks()
            }
            Button("Cancel".tl, role: .cancel) {}
        }
        .onAppear {
            refreshTasks()
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }

    private var headerSection: some View {
        Section {
            let active = tasks.filter { !$0.isPaused && !$0.isError }
            let totalSpeed = active.reduce(0) { $0 + $1.speed }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatBytesSpeed(totalSpeed))
                        .font(.headline)
                        .foregroundStyle(active.isEmpty ? .secondary : .primary)
                    Text("\(active.count) active · \(tasks.count) total".tl)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !active.isEmpty {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func refreshTasks() {
        tasks = DownloadManager.shared.downloadingTasks
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.refreshTasks()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func formatBytesSpeed(_ bytesPerSec: Int) -> String {
        if bytesPerSec <= 0 { return "0 B/s" }
        let kb = Double(bytesPerSec) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.2f MB/s", mb)
    }
}

/// 单个下载任务卡片。
struct DownloadTaskRow: View {
    let task: DownloadTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ComicCover(url: task.cover ?? "")
                .frame(width: 64, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: task.title)
                    .font(.subheadline)
                    .lineLimit(2)

                Spacer()

                HStack {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(task.isError ? .red : .secondary)
                        .lineLimit(1)
                    Spacer()
                }

                ProgressView(value: task.progress > 0 ? task.progress : nil)
                    .progressViewStyle(.linear)
            }

            VStack(spacing: 8) {
                if task.isError {
                    Button {
                        DownloadManager.shared.resumeTask(task)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else if task.isPaused {
                    Button {
                        DownloadManager.shared.resumeTask(task)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        DownloadManager.shared.pauseTask(task)
                    } label: {
                        Image(systemName: "pause.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }

    private var statusMessage: String {
        var msg = task.message
        if !task.isPaused && !task.isError, let eta = task.eta, eta > 0 {
            msg += " · " + formatEta(eta)
        }
        return msg
    }

    private func formatEta(_ seconds: TimeInterval) -> String {
        let sec = Int(seconds)
        if sec < 60 {
            return "~\(sec)s left".tl
        }
        let min = sec / 60
        let remSec = sec % 60
        if min < 60 {
            return "~\(min)m \(remSec)s left".tl
        }
        let hr = min / 60
        let remMin = min % 60
        return "~\(hr)h \(remMin)m left".tl
    }
}
