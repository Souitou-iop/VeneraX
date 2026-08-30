import Foundation

/// 通用 HTTP 客户端（URLSession）。对应原版 AppDio 的 JS http 通道：
/// 默认 webUA、共享 CookieStore、代理、可选忽略坏证书、Cloudflare 5秒盾挑战检测与自动解盾重试。
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    public struct Response: Sendable {
        public var status: Int?
        public var headers: [String: String]
        public var body: Data
        public var error: String?
    }

    /// 原版 consts.dart webUA（JS http 默认 UA）。
    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"

    private init() {}

    /// 依据设置构造会话配置。proxy: direct/system/host:port。
    private func makeSession(ignoreBadCertificate: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false // cookie 由 CookieStore 注入
        configuration.httpMaximumConnectionsPerHost = 8
        let proxy = HTTPClient.customProxySetting()
        if let proxy {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port,
                "HTTPSEnable": true,
                "HTTPSProxy": proxy.host,
                "HTTPSPort": proxy.port,
            ]
        }
        let delegate = ProxyDelegate(ignoreBadCertificate: ignoreBadCertificate)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private static func customProxySetting() -> (host: String, port: Int)? {
        let setting = AppData.shared.settings["proxy"].stringValue ?? "system"
        if setting == "direct" || setting == "system" { return nil }
        let parts = setting.split(separator: ":").map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
        return (parts[0], port)
    }

    public func request(
        method: String,
        url: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        ignoreBadCertificate: Bool = false,
        retryOnCloudflare: Bool = true
    ) async -> Response {
        guard let requestURL = URL(string: url) else {
            return Response(status: nil, headers: [:], body: Data(), error: "Invalid URL: \(url)")
        }
        var reqHeaders = headers
        var request = URLRequest(url: requestURL)
        request.httpMethod = method.uppercased()
        request.httpBody = body
        if body != nil, reqHeaders["Content-Type"] == nil && reqHeaders["content-type"] == nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        // cookie 注入
        let cookies = CookieStore.shared.loadForRequest(requestURL)
        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        // UA 默认 webUA
        if reqHeaders["user-agent"] == nil && reqHeaders["User-Agent"] == nil {
            request.setValue(HTTPClient.webUA, forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in reqHeaders {
            if key == "http_client" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = makeSession(ignoreBadCertificate: ignoreBadCertificate)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            var responseHeaders: [String: String] = [:]
            for (key, value) in httpResponse?.allHeaderFields ?? [:] {
                guard let keyString = key as? String else { continue }
                let valueString = value is String ? (value as! String) : String(describing: value)
                if let existing = responseHeaders[keyString] {
                    responseHeaders[keyString] = existing + "," + valueString
                } else {
                    responseHeaders[keyString] = valueString
                }
            }
            // Set-Cookie 持久化
            let setCookieHeaders = httpResponse?.value(forHTTPHeaderField: "Set-Cookie")
            if let setCookieHeaders {
                CookieStore.shared.saveFromResponse(url: requestURL, headers: ["Set-Cookie": setCookieHeaders])
            }

            // Cloudflare 挑战拦截与解盾重试
            if retryOnCloudflare && CloudflareSolver.isChallengeResponse(status: httpResponse?.statusCode, headers: responseHeaders, body: data) {
                let solved = await CloudflareSolver.shared.solve(url: requestURL, headers: reqHeaders)
                if solved {
                    return await self.request(
                        method: method,
                        url: url,
                        headers: headers,
                        body: body,
                        ignoreBadCertificate: ignoreBadCertificate,
                        retryOnCloudflare: false
                    )
                }
            }

            return Response(
                status: httpResponse?.statusCode,
                headers: responseHeaders,
                body: data,
                error: nil
            )
        } catch {
            return Response(status: nil, headers: [:], body: Data(), error: error.localizedDescription)
        }
    }
}

/// 证书校验代理（忽略坏证书开关）。
final class ProxyDelegate: NSObject, URLSessionDelegate {
    let ignoreBadCertificate: Bool

    init(ignoreBadCertificate: Bool) {
        self.ignoreBadCertificate = ignoreBadCertificate
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if ignoreBadCertificate,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
