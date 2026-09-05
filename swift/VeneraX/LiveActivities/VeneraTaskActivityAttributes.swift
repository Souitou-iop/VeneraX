#if os(iOS)
import ActivityKit
#endif
import Foundation

struct VeneraTaskActivityAttributes: Codable {
    enum Kind: String, Codable, Hashable {
        case preTranslation
        case download

        var symbol: String {
            switch self {
            case .preTranslation: "character.book.closed.fill"
            case .download: "arrow.down.circle.fill"
            }
        }
    }

    enum Status: String, Codable, Hashable {
        case running, paused, completed, failed, cancelled
    }

    struct ContentState: Codable, Hashable {
        var activityTitle: String
        var title: String
        var subtitle: String
        var phase: String
        var coverURL: String
        var progress: Double
        var current: Int
        var total: Int
        var queueCount: Int
        var status: Status

        var failedCount: Int? = nil

        var clampedProgress: Double { progress.isFinite ? min(max(progress, 0), 1) : 0 }
        var isIndeterminate: Bool { total <= 0 && status == .running }
        var statusSymbol: String? {
            switch status {
            case .running: nil
            case .paused: "pause.fill"
            case .completed: "checkmark"
            case .failed: "exclamationmark.triangle.fill"
            case .cancelled: "xmark"
            }
        }

        /// Bound bytes, not grapheme count; pathological combining marks and
        /// untrusted source titles must never exceed ActivityKit's 4 KB budget.
        func bounded(showDetails: Bool) -> Self {
            var state = self
            state.activityTitle = Self.clip(activityTitle, bytes: 120)
            state.title = showDetails ? Self.clip(title, bytes: 240) : state.activityTitle
            state.subtitle = Self.clip(subtitle, bytes: 120)
            state.phase = Self.clip(phase, bytes: 320)
            state.coverURL = showDetails && VeneraTaskActivityAttributes.validCoverName(coverURL) ? coverURL : ""
            state.progress = clampedProgress
            state.current = max(0, current)
            state.total = max(0, total)
            return state
        }

        private static func clip(_ text: String, bytes: Int) -> String {
            var result = ""
            var used = 0
            for scalar in text.unicodeScalars {
                guard scalar.properties.generalCategory != .control else { continue }
                let next = String(scalar)
                guard used + next.utf8.count <= bytes else { break }
                result += next
                used += next.utf8.count
            }
            return result
        }
        var percent: Int { Int((clampedProgress * 100).rounded()) }
    }

    let id: String
    let kind: Kind
}

#if os(iOS)
extension VeneraTaskActivityAttributes: ActivityAttributes {}
#endif

extension VeneraTaskActivityAttributes {
    static let appGroup = "group.io.github.kyosee.venerax"

    static func validCoverName(_ name: String) -> Bool {
        name.hasSuffix(".jpg") && UUID(uuidString: String(name.dropLast(4))) != nil
    }

    static func coverFile(_ name: String) -> URL? {
        guard validCoverName(name) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("LiveActivityCovers", isDirectory: true)
            .appendingPathComponent(name)
    }
}
