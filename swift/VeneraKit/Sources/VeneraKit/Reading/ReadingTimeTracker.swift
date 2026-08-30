import Foundation

/// 阅读时长统计器：阅读器开启期间累计阅读时长（每 30 秒结算一次，
/// 关闭时结算剩余），写入 reading_statistics 表。
public final class ReadingTimeTracker: @unchecked Sendable {
    private let id: String
    private let type: Int
    private let title: String
    private let subtitle: String
    private let cover: String
    private var accumulated: Int = 0
    private var startDate: Date?
    private var timer: DispatchSourceTimer?

    public init(id: String, type: Int, title: String, subtitle: String, cover: String) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
    }

    public func start() {
        guard startDate == nil else { return }
        startDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        flush()
        timer?.cancel()
        timer = nil
        startDate = nil
    }

    private func flush() {
        guard let startDate else { return }
        let elapsed = Int(Date().timeIntervalSince(startDate) * 1000)
        self.startDate = Date()
        guard elapsed > 500 else { return }
        accumulated += elapsed
        let duration = accumulated
        accumulated = 0
        let manager = HistoryManager.shared
        manager.addReadingTime(
            id: id, type: type, title: title, subtitle: subtitle, cover: cover,
            durationMs: duration
        )
    }
}
