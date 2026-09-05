import Foundation

public enum AppLinkRoute: Equatable, Sendable {
    case comic(sourceKey: String, id: String)
    case installSource(url: String)
    case syncConfig(url: String, user: String, pass: String)
    case tasks
}

/// 深度链接与 URL 路由解析器（对齐 app_links.dart，支持 venera:// 与源域名自动匹配）。
public enum AppLinksHandler {

    public static func parse(url: URL) async -> AppLinkRoute? {
        let scheme = url.scheme?.lowercased()

        // 1. venera:// 自定义 Scheme
        if scheme == "venera" {
            let host = url.host?.lowercased() ?? ""
            let path = url.path.lowercased()

            if host == "tasks" || path.contains("tasks") {
                return .tasks
            } else if host == "source" || path.contains("source") {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems {
                    if let scriptUrl = queryItems.first(where: { $0.name == "url" })?.value {
                        return .installSource(url: scriptUrl)
                    }
                }
            } else if host == "comic" || path.contains("comic") {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems {
                    let id = queryItems.first(where: { $0.name == "id" })?.value ?? ""
                    let source = queryItems.first(where: { $0.name == "source" })?.value ?? ""
                    if !id.isEmpty && !source.isEmpty {
                        return .comic(sourceKey: source, id: id)
                    }
                }
            } else if host == "sync" || path.contains("sync") {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems {
                    let syncUrl = queryItems.first(where: { $0.name == "url" })?.value ?? ""
                    let user = queryItems.first(where: { $0.name == "user" })?.value ?? ""
                    let pass = queryItems.first(where: { $0.name == "pass" })?.value ?? ""
                    if !syncUrl.isEmpty {
                        return .syncConfig(url: syncUrl, user: user, pass: pass)
                    }
                }
            }
        }

        // 2. HTTP/HTTPS 外链：匹配已安装源的 linkHandler 域名
        if scheme == "http" || scheme == "https" {
            let host = url.host?.lowercased() ?? ""
            let installedSources = ComicSourceManager.shared.all()
            for source in installedSources {
                if let domains = source.linkHandlerDomains,
                   domains.contains(where: { $0.lowercased() == host }) {
                    do {
                        if let id = try await source.linkToId(url.absoluteString), !id.isEmpty {
                            return .comic(sourceKey: source.key, id: id)
                        }
                    } catch {}
                }
            }
        }

        return nil
    }
}
