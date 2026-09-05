import Foundation

/// A source URL with embedded HTTP Basic credentials removed from the request URL.
/// Keeping credentials out of the URL prevents them from leaking into diagnostics.
public struct SourceURL: Sendable, Equatable {
    public let url: String
    public let authorization: String?

    public init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URLComponents(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let userEncoded = parsed.percentEncodedUser,
              let user = userEncoded.removingPercentEncoding,
              !user.isEmpty,
              let passwordEncoded = parsed.percentEncodedPassword,
              let password = passwordEncoded.removingPercentEncoding,
              let host = parsed.host, !host.isEmpty else {
            self.url = trimmed
            self.authorization = nil
            return
        }
        var clean = parsed
        clean.user = nil
        clean.password = nil
        self.url = clean.string ?? trimmed
        self.authorization = Data("\(user):\(password)".utf8).base64EncodedString()
    }

    public func headers(_ headers: [String: String] = [:]) -> [String: String] {
        guard let authorization else { return headers }
        var result = headers
        if result["Authorization"] == nil && result["authorization"] == nil {
            result["Authorization"] = "Basic \(authorization)"
        }
        return result
    }

    public static func isValid(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty else { return false }
        return true
    }
}
