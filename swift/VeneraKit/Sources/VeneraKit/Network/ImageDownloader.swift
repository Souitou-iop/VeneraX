import Foundation

/// 图片下载管线（对齐原版 network/images.dart + ImageLoadingConfig）：
/// 磁盘缓存 → JS headers（onImageLoad）→ 下载 → JS onResponse → 写缓存。
/// 同一图片的并发请求会合并，避免阅读器预载与可视页重复打网络请求。
public actor ImageDownloader {
    public static let shared = ImageDownloader()

    /// key -> 共享请求。请求完成后立即移除，不作为长期缓存。
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private init() {}

    /// 缓存 key：`imageKey@sourceKey@cid@eid`（与原版一致）。
    public static func cacheKey(imageKey: String, sourceKey: String, cid: String, eid: String) -> String {
        "\(imageKey)@\(sourceKey)@\(cid)@\(eid)"
    }

    public func load(
        imageKey: String,
        sourceKey: String,
        cid: String,
        eid: String,
        source: ComicSource?
    ) async -> Data? {
        let key = Self.cacheKey(imageKey: imageKey, sourceKey: sourceKey, cid: cid, eid: eid)
        if let cached = CacheManager.shared.getData(key) {
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task: Task<Data?, Never> = Task { [weak self] in
            guard let self else { return nil }
            return await self.fetch(
                imageKey: imageKey,
                sourceKey: sourceKey,
                cid: cid,
                eid: eid,
                source: source,
                cacheKey: key
            )
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func fetch(
        imageKey: String,
        sourceKey: String,
        cid: String,
        eid: String,
        source: ComicSource?,
        cacheKey: String
    ) async -> Data? {
        // 预载任务与可视页之间可能在 actor 重入期间交错，再检查一次磁盘缓存。
        if let cached = CacheManager.shared.getData(cacheKey) {
            return cached
        }

        var requestURL = imageKey
        var headers: [String: String] = ["User-Agent": HTTPClient.webUA]
        var method = "GET"
        var body: Data?
        if let source, source.checkExists("comic.onImageLoad") {
            let config = try? await source.getImageLoadingConfig(imageKey: imageKey, cid: cid, eid: eid)
            if let config, let configuredURL = config["url"].stringValue, !configuredURL.isEmpty {
                requestURL = configuredURL
            }
            if let config, let headerMap = config["headers"].objectValue {
                for (name, value) in headerMap {
                    if let v = value.stringValue { headers[name] = v }
                }
            }
            if let config, let m = config["method"].stringValue { method = m }
            if let config, !config["data"].isNull {
                body = HTTPClient.encodeRequestBody(config["data"].asAny)
            }
        }

        let ignoreBadCertificate = AppData.shared.settings["ignoreBadCertificate"].boolValue ?? false
        let response = await HTTPClient.shared.request(
            method: method,
            url: requestURL,
            headers: headers,
            body: body,
            ignoreBadCertificate: ignoreBadCertificate
        )
        guard let status = response.status, (200..<300).contains(status), !response.body.isEmpty else {
            Log.error("Image", "Failed to load \(imageKey): status=\(response.status ?? -1) error=\(response.error ?? "nil")")
            return nil
        }
        var data = response.body

        // JS onResponse 字节变换：函数无法 JSON 序列化，因此通过 runtime 全局字节桥接。
        if let source, source.checkExists("comic.onImageLoad") {
            let expression = """
            (async () => {
                let c = ComicSource.sources.\(source.key).comic;
                let cfg = await c.onImageLoad(\(ComicSource.encodeArg(imageKey)), \(ComicSource.encodeArg(cid)), \(ComicSource.encodeArg(eid)));
                if (!cfg || !cfg.onResponse) return null;
                return await cfg.onResponse(globalThis['\(Self.bytesKey)']);
            })()
            """
            source.setGlobalBytes(data, key: Self.bytesKey)
            defer { source.clearGlobalBytes(key: Self.bytesKey) }
            if let transformed = try? await source.invoke(expression),
               let bytes = transformed.bytesValue, !bytes.isEmpty {
                data = bytes
            }
        }
        CacheManager.shared.set(cacheKey, data)
        return data
    }

    static let bytesKey = "__veneraImageBytes"
}

extension ComicSource {
    /// 设置全局字节（供 onResponse 表达式读取）。
    public func setGlobalBytes(_ data: Data, key: String) {
        runtime.performOnQueue {
            runtime.context.setObject(data, forKeyedSubscript: key as NSString)
        }
    }

    public func clearGlobalBytes(key: String) {
        runtime.performOnQueue {
            runtime.context.setObject(NSNull(), forKeyedSubscript: key as NSString)
        }
    }
}

extension JSON {
    public var bytesValue: Data? {
        blobValue
    }
}
