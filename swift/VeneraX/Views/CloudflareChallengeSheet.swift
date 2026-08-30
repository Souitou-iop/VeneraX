import SwiftUI
import WebKit
import VeneraKit

/// Cloudflare 人机验证挑战弹窗（对齐原版 cloudflare.dart）。
/// 包含 WKWebView 页面加载与 Cookie 监听，检测到 cf_clearance 通关后自动持久化并关闭。
struct CloudflareChallengeSheet: View {
    let url: URL
    let headers: [String: String]
    let onComplete: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSolved = false

    var body: some View {
        NavigationStack {
            CloudflareWebViewRepresentable(url: url, headers: headers) { solved in
                isSolved = solved
                onComplete(solved)
                dismiss()
            }
            .navigationTitle("Verification".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) {
                        onComplete(false)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct CloudflareWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    let onSolved: (Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = HTTPClient.webUA

        var request = URLRequest(url: url)
        for (k, v) in headers {
            if k.lowercased() != "cookie" && k.lowercased() != "user-agent" {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        webView.load(request)
        context.coordinator.startCookieTimer(webView: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopTimer()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSolved: onSolved)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSolved: (Bool) -> Void
        private var timer: Timer?
        private var solved = false

        init(onSolved: @escaping (Bool) -> Void) {
            self.onSolved = onSolved
        }

        func startCookieTimer(webView: WKWebView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak webView] _ in
                Task { @MainActor in
                    guard let self, let webView, !self.solved else { return }
                    self.checkCookies(webView: webView)
                }
            }
        }

        func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies(webView: webView)
        }

        func checkCookies(webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor in
                    guard let self, !self.solved else { return }
                    var hasClearance = false
                    for c in cookies {
                        if c.name == "cf_clearance" || c.name == "__cf_bm" {
                            hasClearance = true
                        }
                        CookieStore.shared.save(CookieStore.StoredCookie(
                            name: c.name,
                            value: c.value,
                            domain: c.domain,
                            path: c.path,
                            expires: c.expiresDate,
                            secure: c.isSecure,
                            httpOnly: c.isHTTPOnly
                        ))
                    }

                    if hasClearance {
                        self.solved = true
                        self.stopTimer()
                        self.onSolved(true)
                    }
                }
            }
        }
    }
}
