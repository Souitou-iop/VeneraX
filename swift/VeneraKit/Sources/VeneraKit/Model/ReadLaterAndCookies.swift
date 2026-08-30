import Foundation

/// 稍后读条目（read_later.db）。
public struct ReadLaterItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var cover: String
    public var type: Int
    public var tags: [String]
    public var time: Int64

    public init(id: String, title: String, subtitle: String, cover: String, type: Int, tags: [String], time: Int64) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.type = type
        self.tags = tags
        self.time = time
    }

    init(row: [String: SQLiteValue]) {
        id = row["id"]?.textValue ?? ""
        title = row["title"]?.textValue ?? ""
        subtitle = row["subtitle"]?.textValue ?? ""
        cover = row["cover"]?.textValue ?? ""
        type = row["type"]?.intValue ?? 0
        if let text = row["tags"]?.textValue, !text.isEmpty {
            tags = text.split(separator: ",").map(String.init)
        } else {
            tags = []
        }
        time = row["time"]?.int64Value ?? 0
    }

    var rowValues: [SQLiteValue] {
        [
            .text(id), .text(title), .text(subtitle), .text(cover),
            .int(type), .text(tags.joined(separator: ",")), .int(Int(time)),
        ]
    }
}

/// 稍后读管理器。时间戳为毫秒。
public final class ReadLaterManager: @unchecked Sendable {
    public static let shared = ReadLaterManager()

    public let onChange = CallbackRegistry<Void>()

    public let customDataPath: String?

    private var dbPath: String {
        AppPaths.join(customDataPath ?? AppPaths.dataPath, "read_later.db")
    }

    private var db: SQLiteDatabase {
        DatabaseGateway.shared.openManagedRecovering(dbPath)
    }

    public init(dataPath: String? = nil) {
        self.customDataPath = dataPath
        ensureSchema()
    }

    public func ensureSchema() {
        db.executeRaw("""
        create table if not exists read_later (
          id text,
          title text,
          subtitle text,
          cover text,
          type int,
          tags text,
          time int,
          primary key (id, type)
        );
        """)
    }

    public func contains(id: String, type: Int) -> Bool {
        let rows = (try? db.select("select rowid from read_later where id = ? and type = ?;", [.text(id), .int(type)])) ?? []
        return !rows.isEmpty
    }

    public func add(_ item: ReadLaterItem) {
        try? db.execute("""
        insert or replace into read_later (id, title, subtitle, cover, type, tags, time)
        values (?, ?, ?, ?, ?, ?, ?);
        """, item.rowValues)
        onChange.emit(())
    }

    public func add(id: String, title: String, subtitle: String, cover: String, type: Int, tags: [String]) {
        add(ReadLaterItem(
            id: id, title: title, subtitle: subtitle, cover: cover,
            type: type, tags: tags, time: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    @discardableResult
    public func remove(id: String, type: Int) -> Bool {
        try? db.execute("delete from read_later where id = ? and type = ?;", [.text(id), .int(type)])
        onChange.emit(())
        return true
    }

    public func getAll() -> [ReadLaterItem] {
        let rows = (try? db.select("select * from read_later order by time desc;")) ?? []
        return rows.map(ReadLaterItem.init)
    }
}

// MARK: - Cookie 持久化

/// 持久化 Cookie（cookie.db，结构对齐原版 CookieJarSql）。
/// HTTP 客户端与 WKWebView（登录/Cloudflare 解盾）共享同一存储。
public final class CookieStore: @unchecked Sendable {
    public static let shared = CookieStore()

    public struct StoredCookie: Equatable, Sendable {
        public var name: String
        public var value: String
        public var domain: String
        public var path: String
        public var expires: Date?
        public var secure: Bool
        public var httpOnly: Bool

        public init(name: String, value: String, domain: String, path: String = "/",
                    expires: Date? = nil, secure: Bool = false, httpOnly: Bool = false) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.expires = expires
            self.secure = secure
            self.httpOnly = httpOnly
        }
    }

    public let customDataPath: String?

    private var dbPath: String {
        AppPaths.join(customDataPath ?? AppPaths.dataPath, "cookie.db")
    }

    private var db: SQLiteDatabase {
        DatabaseGateway.shared.openManagedRecovering(dbPath)
    }

    public init(dataPath: String? = nil) {
        self.customDataPath = dataPath
        ensureSchema()
    }

    public func ensureSchema() {
        db.executeRaw("""
        CREATE TABLE IF NOT EXISTS cookies (
          name TEXT NOT NULL,
          value TEXT NOT NULL,
          domain TEXT NOT NULL,
          path TEXT,
          expires INTEGER,
          secure INTEGER,
          httpOnly INTEGER,
          PRIMARY KEY (name, domain, path)
        );
        """)
    }

    /// 该 URL 请求应携带的 cookie（域后缀匹配 + path 前缀匹配 + 过期过滤）。
    public func loadForRequest(_ url: URL) -> [StoredCookie] {
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"
        let now = Date().timeIntervalSince1970
        let rows = (try? db.select("select * from cookies;")) ?? []
        return rows.compactMap { row -> StoredCookie? in
            guard let name = row["name"]?.textValue, let value = row["value"]?.textValue else { return nil }
            let domain = row["domain"]?.textValue ?? ""
            let cookiePath = row["path"]?.textValue ?? "/"
            let expires = row["expires"]?.doubleValue
            let secure = (row["secure"]?.intValue ?? 0) != 0
            let httpOnly = (row["httpOnly"]?.intValue ?? 0) != 0
            if let expires, expires < now { return nil }
            if secure && !isSecure { return nil }
            if !domainMatches(requestHost: host, cookieDomain: domain) { return nil }
            if !pathMatches(requestPath: path, cookiePath: cookiePath) { return nil }
            return StoredCookie(
                name: name, value: value, domain: domain, path: cookiePath,
                expires: expires.map { Date(timeIntervalSince1970: $0) },
                secure: secure, httpOnly: httpOnly
            )
        }
    }

    private func domainMatches(requestHost: String, cookieDomain: String) -> Bool {
        let host = requestHost.lowercased()
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        if host == domain { return true }
        if host.hasSuffix("." + domain) { return true }
        return false
    }

    private func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if cookiePath.isEmpty { return true }
        if cookiePath == "/" { return true }
        if requestPath.hasPrefix(cookiePath) { return true }
        return false
    }

    /// 保存（insert or replace 语义）。
    public func save(_ cookie: StoredCookie) {
        try? db.execute("""
        insert or replace into cookies (name, value, domain, path, expires, secure, httpOnly)
        values (?, ?, ?, ?, ?, ?, ?);
        """, [
            .text(cookie.name), .text(cookie.value), .text(cookie.domain),
            .text(cookie.path),
            cookie.expires.map { .double($0.timeIntervalSince1970) } ?? .null,
            .int(cookie.secure ? 1 : 0),
            .int(cookie.httpOnly ? 1 : 0),
        ])
    }

    public func saveFromResponse(url: URL, headers: [String: String]) {
        let setCookieValues = headers.compactMap { key, value -> [String]? in
            key.lowercased() == "set-cookie" ? splitSetCookieHeaders(value) : nil
        }.flatMap { $0 }
        for text in setCookieValues {
            guard let cookie = parseSetCookie(text, requestURL: url) else { continue }
            save(cookie)
        }
    }

    func splitSetCookieHeaders(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = 0
        let characters = Array(value)
        while index < characters.count {
            let char = characters[index]
            if char == "," {
                let rest = String(characters[(index + 1)...])
                if rest.range(of: "^\\s*\\d{1,2}\\s+\\w{3}", options: .regularExpression) != nil
                    || rest.range(of: "^\\s*\\w{3},", options: .regularExpression) != nil {
                    current.append(char)
                } else {
                    parts.append(current)
                    current = ""
                    index += 1
                    continue
                }
            } else {
                current.append(char)
            }
            index += 1
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }
    }

    func parseSetCookie(_ text: String, requestURL: URL) -> StoredCookie? {
        let segments = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = segments.first else { return nil }
        let pair = first.split(separator: "=", maxSplits: 1).map { String($0) }
        guard pair.count == 2, !pair[0].isEmpty else { return nil }
        var cookie = StoredCookie(
            name: pair[0],
            value: pair[1],
            domain: requestURL.host ?? ""
        )
        for segment in segments.dropFirst() {
            let kv = segment.split(separator: "=", maxSplits: 1).map { String($0) }
            let key = kv[0].lowercased()
            let value = kv.count > 1 ? kv[1] : ""
            switch key {
            case "domain":
                cookie.domain = value.hasPrefix(".") ? String(value.dropFirst()) : value
            case "path":
                cookie.path = value
            case "expires":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz"] {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: value) {
                        cookie.expires = date
                        break
                    }
                }
            case "secure":
                cookie.secure = true
            case "httponly":
                cookie.httpOnly = true
            default:
                break
            }
        }
        return cookie
    }

    public func delete(domain: String) {
        try? db.execute("delete from cookies where domain = ? or domain = ?;", [.text(domain), .text(".\(domain)")])
    }

    public func deleteAll() {
        try? db.execute("delete from cookies;")
    }

    public func getAllCookies() -> [StoredCookie] {
        let rows = (try? db.select("select * from cookies;")) ?? []
        return rows.compactMap { row in
            guard let name = row["name"]?.textValue, let value = row["value"]?.textValue else { return nil }
            return StoredCookie(
                name: name,
                value: value,
                domain: row["domain"]?.textValue ?? "",
                path: row["path"]?.textValue ?? "/",
                expires: row["expires"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                secure: (row["secure"]?.intValue ?? 0) != 0,
                httpOnly: (row["httpOnly"]?.intValue ?? 0) != 0
            )
        }
    }
}
