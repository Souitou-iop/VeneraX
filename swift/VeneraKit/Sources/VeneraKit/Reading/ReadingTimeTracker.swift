import Foundation

/// Counts only explicitly active reading sessions. The monotonic clock avoids
/// wall-clock changes; timer callbacks and UI stop/start share one state lock.
public final class ReadingTimeTracker: @unchecked Sendable {
    private let id: String
    private let type: Int
    private let title: String
    private let subtitle: String
    private let cover: String
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var startTick: TimeInterval?
    private var timer: DispatchSourceTimer?

    public init(id: String, type: Int, title: String, subtitle: String, cover: String,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.clock = clock
    }

    deinit { timer?.cancel() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard startTick == nil else { return }
        startTick = clock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.flush(stopping: false) }
        self.timer = timer
        timer.resume()
    }

    public func stop() { flush(stopping: true) }

    private func flush(stopping: Bool) {
        lock.lock()
        guard let start = startTick else {
            lock.unlock()
            return
        }
        let now = clock()
        let elapsed = max(0, Int((now - start) * 1000))
        startTick = stopping ? nil : now
        let oldTimer = stopping ? timer : nil
        if stopping { timer = nil }
        lock.unlock()
        oldTimer?.cancel()
        guard elapsed > 0 else { return }
        HistoryManager.shared.addReadingTime(
            id: id, type: type, title: title, subtitle: subtitle, cover: cover,
            durationMs: elapsed
        )
    }
}
