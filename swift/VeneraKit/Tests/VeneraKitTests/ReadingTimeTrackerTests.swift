import XCTest
@testable import VeneraKit

final class ReadingTimeTrackerTests: XCTestCase {
    func testStopExcludesBackgroundTimeAndRepeatedStartIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppPaths.overrideDataPath = directory.path
        defer {
            AppPaths.overrideDataPath = nil
            try? FileManager.default.removeItem(at: directory)
        }
        HistoryManager.shared.ensureSchema()
        let clock = TestReadingClock()
        let id = UUID().uuidString
        let tracker = ReadingTimeTracker(id: id, type: 0, title: "Fixture", subtitle: "", cover: "", clock: { clock.read() })
        tracker.start()
        clock.advance(2)
        tracker.start() // Must not discard the initial two seconds.
        clock.advance(3)
        tracker.stop()
        clock.advance(600) // App is backgrounded for ten minutes.
        tracker.stop() // A repeated stop must not count background time.
        tracker.start()
        clock.advance(4)
        tracker.stop()
        let total = HistoryManager.shared.getReadingStatistics().filter { $0.id == id }.reduce(0) { $0 + $1.durationMs }
        XCTAssertEqual(total, 9000)
    }
}

private final class TestReadingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
