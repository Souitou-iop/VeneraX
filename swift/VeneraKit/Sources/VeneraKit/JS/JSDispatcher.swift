import Foundation
import SwiftSoup

/// sendMessage 全部 method 的分发与注册。逐条对应 js_engine.dart 的
/// `_messageReceiver` switch。需要应用层介入的（源存储、UI 对话框）经
/// delegate 协议注入；headless/测试环境用默认实现。
public final class JSDispatcher: @unchecked Sendable {
    /// 源数据持久化 delegate（ComicSourceManager 实现）。
    public protocol SourceStorageDelegate: AnyObject, Sendable {
        func loadData(sourceKey: String, dataKey: String) -> JSON
        func saveData(sourceKey: String, dataKey: String, data: JSON)
        func deleteData(sourceKey: String, dataKey: String)
        func loadSetting(sourceKey: String, settingKey: String) throws -> JSON
        func isLogged(sourceKey: String) -> Bool
    }

    /// UI 对话框 delegate（App 层实现；headless 返回默认值）。
    public protocol UIDelegate: AnyObject, Sendable {
        func showMessage(_ message: String)
        func showDialog(title: String, content: String)
        func launchUrl(_ url: String)
        func showInputDialog(title: String, completion: @escaping @Sendable (String?) -> Void)
        func showSelectDialog(title: String, options: [String], initialIndex: Int?, completion: @escaping @Sendable (Int?) -> Void)
    }

    public weak var storageDelegate: SourceStorageDelegate?
    public weak var uiDelegate: UIDelegate?

    public init() {}

    /// 把全部处理器注册到 runtime（runtime 强持有本分发器）。
    public func install(to runtime: JSRuntime) {
        runtime.retainedDispatcher = self
        runtime.setHandler("log") { message, _ in
            let level = (message["level"] as? String) ?? "info"
            let title = (message["title"] as? String) ?? "JS"
            let content = message["content"].map { String(describing: $0) } ?? ""
            switch level {
            case "error": Log.error("JS", "\(title): \(content)")
            case "warning": Log.warning("JS", "\(title): \(content)")
            default: Log.info("JS", "\(title): \(content)")
            }
            return nil
        }

        runtime.setHandler("convert") { message, _ in
            JSHandlers.convert(message)
        }

        runtime.setHandler("random") { message, _ in
            JSHandlers.random(message)
        }

        runtime.setHandler("uuid") { _, _ in
            JSHandlers.uuidV1()
        }

        runtime.setHandler("getLocale") { _, _ in
            JSHandlers.locale()
        }

        runtime.setHandler("getPlatform") { _, _ in
            JSHandlers.platform()
        }

        #if canImport(UIKit) || canImport(AppKit)
        runtime.setHandler("setClipboard") { message, _ in
            if let text = message["text"] as? String {
                JSHandlers.setClipboard(text)
            }
            return nil
        }
        runtime.setHandler("getClipboard") { _, completion in
            completion(.success(JSHandlers.getClipboard()))
            return nil
        }
        #endif

        runtime.setHandler("delay") { message, completion in
            let time: Double
            if let double = message["time"] as? Double {
                time = double
            } else if let int = message["time"] as? Int {
                time = Double(int)
            } else {
                time = 0
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + time / 1000) {
                completion(.success(nil))
            }
            return nil
        }

        runtime.setHandler("http") { [weak self] message, completion in
            self?.handleHTTP(message, completion: completion)
            return nil
        }

        runtime.setHandler("html") { message, _ in
            JSDispatcher.handleHTML(message)
        }

        runtime.setHandler("cookie") { message, _ in
            JSDispatcher.handleCookie(message)
        }

        runtime.setHandler("load_data") { [weak self] message, _ in
            guard let key = message["key"] as? String, let dataKey = message["data_key"] as? String else { return nil }
            return self?.storageDelegate?.loadData(sourceKey: key, dataKey: dataKey).asAny
        }

        runtime.setHandler("save_data") { [weak self] message, _ in
            guard let key = message["key"] as? String, let dataKey = message["data_key"] as? String else { return nil }
            if dataKey == "setting" {
                throw JSRuntimeException(message: "setting is not allowed to be saved")
            }
            self?.storageDelegate?.saveData(sourceKey: key, dataKey: dataKey, data: JSON(any: message["data"] ?? NSNull()))
            return nil
        }

        runtime.setHandler("delete_data") { [weak self] message, _ in
            guard let key = message["key"] as? String, let dataKey = message["data_key"] as? String else { return nil }
            self?.storageDelegate?.deleteData(sourceKey: key, dataKey: dataKey)
            return nil
        }

        runtime.setHandler("load_setting") { [weak self] message, _ in
            guard let key = message["key"] as? String, let settingKey = message["setting_key"] as? String else {
                throw JSRuntimeException(message: "Setting not found")
            }
            guard let value = try self?.storageDelegate?.loadSetting(sourceKey: key, settingKey: settingKey), !value.isNull else {
                throw JSRuntimeException(message: "Setting not found: \(settingKey)")
            }
            return value.asAny
        }

        runtime.setHandler("isLogged") { [weak self] message, _ in
            guard let key = message["key"] as? String else { return false }
            return self?.storageDelegate?.isLogged(sourceKey: key) ?? false
        }

        runtime.setHandler("UI") { [weak self] message, completion in
            self?.handleUI(message, completion: completion)
            return nil
        }
    }

    // MARK: - http

    private func handleHTTP(_ message: [String: Any], completion: @escaping @Sendable (Result<Any?, Error>) -> Void) {
        guard let url = message["url"] as? String else {
            completion(.failure(JSRuntimeException(message: "http: url is required")))
            return
        }
        let method = (message["http_method"] as? String) ?? "GET"
        var headers: [String: String] = [:]
        if let raw = message["headers"] as? [String: Any] {
            headers = raw.compactMapValues { $0 as? String ?? ($0 is NSNull ? nil : String(describing: $0)) }
        }
        let extra: [String: Any] = (message["extra"] as? [String: Any]) ?? [:]
        let bytes = (message["bytes"] as? Bool) ?? false
        let ignoreBadCertificate = AppData.shared.settings["ignoreBadCertificate"].boolValue ?? false

        var body: Data?
        if let data = message["data"] {
            body = HTTPClient.encodeRequestBody(data)
        }

        _ = extra // 原版仅透传给拦截器，此处不需要
        Task {
            let response = await HTTPClient.shared.request(
                method: method,
                url: url,
                headers: headers,
                body: body,
                ignoreBadCertificate: ignoreBadCertificate
            )
            completion(.success(response.asJSPayload(bytes: bytes)))
        }
    }

    // MARK: - html（SwiftSoup DOM 句柄池）

    private final class DocumentPool: @unchecked Sendable {
        static let shared = DocumentPool()
        private let lock = NSLock()
        private var documents: [Int: ParsedDocument] = [Int: ParsedDocument]()
        private var order: [Int] = []
        let limit = 8

        func put(_ key: Int, _ document: ParsedDocument) {
            lock.lock()
            if order.count >= limit, let oldest = order.first, oldest != key {
                documents.removeValue(forKey: oldest)
                order.removeFirst()
                Log.warning("JS Engine", "Too many documents, deleting the oldest: \(oldest)")
            }
            if documents[key] == nil {
                order.append(key)
            }
            documents[key] = document
            lock.unlock()
        }

        func get(_ key: Int) -> ParsedDocument? {
            lock.lock()
            defer { lock.unlock() }
            return documents[key]
        }

        func remove(_ key: Int) {
            lock.lock()
            documents.removeValue(forKey: key)
            order.removeAll { $0 == key }
            lock.unlock()
        }
    }

    /// 已解析文档 + 元素/节点句柄池（对齐 DocumentWrapper）。
    final class ParsedDocument {
        let document: Document
        var elements: [Element] = []
        var nodes: [Node] = []

        init(html: String) throws {
            document = try SwiftSoup.parse(html)
        }

        func addElement(_ element: Element) -> Int {
            elements.append(element)
            return elements.count - 1
        }

        func addNode(_ node: Node) -> Int {
            nodes.append(node)
            return nodes.count - 1
        }
    }

    static func handleHTML(_ message: [String: Any]) -> Any? {
        guard let function = message["function"] as? String else { return nil }
        let key = (message["key"] as? Int) ?? 0
        let docKey = (message["doc"] as? Int) ?? key

        switch function {
        case "parse":
            guard let html = message["data"] as? String else { return nil }
            let document: ParsedDocument
            do {
                document = try ParsedDocument(html: html)
            } catch {
                Log.error("JS Engine", "Failed to parse html: \(error)")
                return nil
            }
            DocumentPool.shared.put(key, document)
            return nil
        case "dispose":
            DocumentPool.shared.remove(key)
            return nil
        default:
            break
        }

        guard let document = DocumentPool.shared.get(docKey) else { return nil }

        do {
            switch function {
            case "querySelector":
                guard let query = message["query"] as? String else { return nil }
                guard let element = try document.document.select(query).first() else { return nil }
                return document.addElement(element)
            case "querySelectorAll":
                guard let query = message["query"] as? String else { return nil }
                return try document.document.select(query).array().map { document.addElement($0) }
            case "getElementById":
                guard let id = message["id"] as? String else { return nil }
                guard let element = try document.document.getElementById(id) else { return nil }
                return document.addElement(element)
            case "getText":
                return try document.elements[key].text()
            case "getAttributes":
                let node = document.elements[key]
                var attributes: [String: String] = [:]
                for attribute in try node.getAttributes()?.asList() ?? [] {
                    attributes[attribute.getKey()] = attribute.getValue()
                }
                return attributes
            case "dom_querySelector":
                guard let query = message["query"] as? String else { return nil }
                guard let element = try document.elements[key].select(query).first() else { return nil }
                return document.addElement(element)
            case "dom_querySelectorAll":
                guard let query = message["query"] as? String else { return nil }
                return try document.elements[key].select(query).array().map { document.addElement($0) }
            case "getChildren":
                return try document.elements[key].children().array().map { document.addElement($0) }
            case "getNodes":
                return (try? document.elements[key].getChildNodes()).map { $0.map { document.addNode($0) } } ?? []
            case "getInnerHTML":
                return try document.elements[key].html()
            case "getParent":
                guard let parent = document.elements[key].parent() else { return nil }
                return document.addElement(parent)
            case "node_text":
                guard key < document.nodes.count else { return nil }
                let node = document.nodes[key]
                if let textNode = node as? TextNode {
                    return textNode.getWholeText()
                }
                if let element = node as? Element {
                    return try element.text()
                }
                return nil
            case "node_type":
                guard key < document.nodes.count else { return "unknown" }
                switch document.nodes[key] {
                case is Element: return "element"
                case is TextNode: return "text"
                case is Comment: return "comment"
                case is DataNode: return "text"
                default: return "unknown"
                }
            case "node_toElement":
                guard key < document.nodes.count, let element = document.nodes[key] as? Element else { return nil }
                return document.addElement(element)
            case "getClassNames":
                return try document.elements[key].classNames()
            case "getId":
                return try document.elements[key].id().isEmpty ? nil : try document.elements[key].id()
            case "getLocalName":
                return document.elements[key].tagName()
            case "getPreviousSibling":
                guard let sibling = try document.elements[key].previousElementSibling() else { return nil }
                return document.addElement(sibling)
            case "getNextSibling":
                guard let sibling = try document.elements[key].nextElementSibling() else { return nil }
                return document.addElement(sibling)
            default:
                return nil
            }
        } catch {
            Log.error("JS Engine", "html handler failed for \(function): \(error)")
            return nil
        }
    }

    // MARK: - cookie

    static func handleCookie(_ message: [String: Any]) -> Any? {
        guard let function = message["function"] as? String,
              let urlString = message["url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        switch function {
        case "set":
            guard let cookies = message["cookies"] as? [[String: Any]] else { return nil }
            for entry in cookies {
                guard let name = entry["name"] as? String else { continue }
                let cookie = CookieStore.StoredCookie(
                    name: name,
                    value: (entry["value"] as? String) ?? "",
                    domain: (entry["domain"] as? String) ?? (url.host ?? ""),
                    path: (entry["path"] as? String) ?? "/"
                )
                CookieStore.shared.save(cookie)
            }
            return nil
        case "get":
            let cookies = CookieStore.shared.loadForRequest(url)
            return cookies.map { cookie in
                [
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain,
                    "path": cookie.path,
                    "expires": cookie.expires.map { $0.timeIntervalSince1970 } ?? NSNull(),
                    "secure": cookie.secure,
                    "httpOnly": cookie.httpOnly,
                    "session": cookie.expires == nil,
                ] as [String: Any]
            }
        case "delete":
            if let host = url.host {
                CookieStore.shared.delete(domain: host)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - UI

    private func handleUI(_ message: [String: Any], completion: @escaping @Sendable (Result<Any?, Error>) -> Void) {
        guard let function = message["function"] as? String else {
            completion(.success(nil))
            return
        }
        switch function {
        case "showMessage":
            uiDelegate?.showMessage((message["message"] as? String) ?? "")
            completion(.success(nil))
        case "showDialog":
            uiDelegate?.showDialog(
                title: (message["title"] as? String) ?? "",
                content: (message["content"] as? String) ?? ""
            )
            completion(.success(nil))
        case "launchUrl":
            uiDelegate?.launchUrl((message["url"] as? String) ?? "")
            completion(.success(nil))
        case "showInputDialog":
            uiDelegate?.showInputDialog(title: (message["title"] as? String) ?? "") { value in
                completion(.success(value))
            }
        case "showSelectDialog":
            let options = (message["options"] as? [String]) ?? []
            uiDelegate?.showSelectDialog(
                title: (message["title"] as? String) ?? "",
                options: options,
                initialIndex: message["initialIndex"] as? Int
            ) { index in
                completion(.success(index))
            }
        default:
            completion(.success(nil))
        }
    }
}

/// http 响应负载组装（bytes 模式 body 为 ArrayBuffer，否则为文本）。
extension HTTPClient.Response {
    func asJSPayload(bytes: Bool) -> [String: Any] {
        [
            "status": status ?? NSNull(),
            "headers": headers,
            "body": bytes ? body : (String(data: body, encoding: .utf8) ?? ""),
            "error": error ?? NSNull(),
        ]
    }
}

/// 请求体编码：字符串原样；ArrayBuffer 原样；对象转 JSON 文本。
extension HTTPClient {
    public static func encodeRequestBody(_ data: Any) -> Data? {
        switch data {
        case is NSNull: return nil
        case let string as String: return Data(string.utf8)
        case let bytes as Data: return bytes
        case let number as Int: return Data(String(number).utf8)
        case let number as Double: return Data(String(number).utf8)
        case let bool as Bool: return Data(String(bool).utf8)
        default:
            if let json = try? JSON(any: data).encodedString() {
                return Data(json.utf8)
            }
            return nil
        }
    }
}
