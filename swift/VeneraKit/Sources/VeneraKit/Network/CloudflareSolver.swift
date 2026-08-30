import Foundation

public protocol CloudflareChallengeDelegate: AnyObject, Sendable {
    @MainActor
    func requestSolveCloudflare(url: URL, headers: [String: String]) async -> Bool
}

/// Cloudflare 挑战检测与解盾协调器（对齐原版 cloudflare.dart）。
public final class CloudflareSolver: @unchecked Sendable {
    public static let shared = CloudflareSolver()

    public weak var delegate: CloudflareChallengeDelegate?

    private let lock = NSLock()
    private var solvingTasks: [String: Task<Bool, Never>] = [:]

    private init() {}

    public static func isChallengeResponse(status: Int?, headers: [String: String], body: Data) -> Bool {
        guard let status, status == 403 || status == 503 else { return false }
        if let mitigated = headers["cf-mitigated"], mitigated.lowercased().contains("challenge") {
            return true
        }
        let bodyText = (String(data: body.prefix(4096), encoding: .utf8) ?? "").lowercased()
        if bodyText.contains("challenges.cloudflare.com") ||
           bodyText.contains("just a moment...") ||
           bodyText.contains("cf-browser-verification") ||
           bodyText.contains("turnstile") {
            return true
        }
        return false
    }

    private func getOrStartTask(for host: String, url: URL, headers: [String: String]) -> (Task<Bool, Never>, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = solvingTasks[host] {
            return (existing, false)
        }
        let task = Task<Bool, Never> { @MainActor in
            guard let delegate = self.delegate else { return false }
            return await delegate.requestSolveCloudflare(url: url, headers: headers)
        }
        solvingTasks[host] = task
        return (task, true)
    }

    private func finishTask(for host: String) {
        lock.lock()
        solvingTasks.removeValue(forKey: host)
        lock.unlock()
    }

    public func solve(url: URL, headers: [String: String] = [:]) async -> Bool {
        guard let host = url.host else { return false }
        let (task, isNew) = getOrStartTask(for: host, url: url, headers: headers)
        let result = await task.value
        if isNew {
            finishTask(for: host)
        }
        return result
    }
}
