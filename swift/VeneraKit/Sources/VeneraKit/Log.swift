import Foundation

/// 分级日志。对齐原版 `lib/foundation/log.dart`：内存缓冲 + 落盘，
/// verbose 网络日志由设置项控制（默认关闭，避免每张图一次磁盘写）。
public enum Log {
    public enum Level: Int, Sendable, Comparable {
        case verbose = 0
        case debug = 1
        case info = 2
        case warning = 3
        case error = 4
        case none = 5

        public var label: String {
            switch self {
            case .verbose: return "VERBOSE"
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warning: return "WARNING"
            case .error: return "ERROR"
            case .none: return "NONE"
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    nonisolated(unsafe) private static var buffer: [String] = []
    nonisolated(unsafe) private static var minimumLevel: Level = .info
    private static let queue = DispatchQueue(label: "venera.log")
    nonisolated(unsafe) private static var flushNeeded = false

    public static func setMinimumLevel(_ level: Level) {
        queue.sync { minimumLevel = level }
    }

    /// 与设置项 `verboseNetworkLog` 联动（原版 load 后推送到 Log）。
    public static func syncVerboseNetwork(_ enabled: Bool) {
        setMinimumLevel(enabled ? .verbose : .info)
    }

    public static func verbose(_ tag: String, _ message: String) { log(.verbose, tag, message, nil) }
    public static func debug(_ tag: String, _ message: String) { log(.debug, tag, message, nil) }
    public static func info(_ tag: String, _ message: String) { log(.info, tag, message, nil) }
    public static func warning(_ tag: String, _ message: String) { log(.warning, tag, message, nil) }
    public static func error(_ tag: String, _ message: String, _ error: (any Error)? = nil) {
        log(.error, tag, message, error)
    }

    public static func log(_ level: Level, _ tag: String, _ message: String, _ error: (any Error)?) {
        let line: String
        if let error {
            line = "[\(level.label)] [\(tag)] \(message): \(describe(error))"
        } else {
            line = "[\(level.label)] [\(tag)] \(message)"
        }
        queue.async {
            guard level >= minimumLevel, minimumLevel != .none else { return }
            buffer.append(line)
            // 内存缓冲上限：仅保留最近 1000 行用于导出。
            if buffer.count > 1000 {
                buffer.removeFirst(buffer.count - 1000)
            }
            if level >= .warning {
                print(line)
            }
            flushNeeded = true
        }
    }

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)[\(nsError.code)]: \(nsError.localizedDescription)"
    }

    public static func currentBuffer() -> [String] {
        queue.sync { buffer }
    }

    /// 立即把缓冲写入 `<dataPath>/logs` 目录。
    public static func flush() {
        queue.sync {
            guard flushNeeded else { return }
            flushNeeded = false
            let directory = AppPaths.join(AppPaths.dataPath, "logs")
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let path = AppPaths.join(directory, "\(formatter.string(from: Date())).log")
            let text = buffer.joined(separator: "\n") + "\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(text.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
