import Foundation
@preconcurrency import JavaScriptCore

#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// JavaScriptCore 运行时。对应 Flutter 版 `js_engine.dart` 中的 FlutterQjs
/// 封装：单一同步桥入口 `sendMessage(message)`；同步处理器直接返回值，
/// 异步处理器（http/delay/compute 等）返回 Promise。
///
/// JSC 非线程安全：所有脚本求值与 JS 互调都固定在专用串行队列上。
/// Swift 侧 resolve Promise 后以 no-op 求值冲刷微任务队列，驱动
/// async/await 链与 `setTimeout`（init.js 用 delay+then 实现）。
public final class JSRuntime: @unchecked Sendable {
    public static let defaultQueueLabel = "venera.js"

    /// 运行时队列（串行）。所有 JSContext 访问必须在此队列。
    let queue: DispatchQueue

    var context: JSContext!

    /// 同步/异步统一消息处理器：返回非 nil 即同步结果；
    /// 返回 nil 则必须恰好调用一次 completion（异步路径）。
    /// 同步抛出错误会转化为 JS 异常（对齐原版 rethrow 行为）。
    public typealias MessageHandler = @Sendable (_ message: [String: Any], _ completion: @escaping @Sendable (Result<Any?, Error>) -> Void) throws -> Any?

    private let lock = NSLock()
    private var handlers: [String: MessageHandler] = [:]

    /// JS 未捕获异常回调（任意线程）。
    public let onUnhandledException = CallbackRegistry<String>()

    /// 已安装的分发器（强持有，防止处理器闭包中的弱引用失效）。
    public var retainedDispatcher: AnyObject?

    private static let deferredFactorySource = """
    globalThis.__createDeferred = () => {
        let resolveFn, rejectFn;
        const promise = new Promise((resolve, reject) => {
            resolveFn = resolve;
            rejectFn = reject;
        });
        return { promise: promise, resolve: resolveFn, reject: rejectFn };
    };
    """

    private static let queueKey = DispatchSpecificKey<UInt8>()

    private var isOnRuntimeQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == 1
    }

    public init(queueLabel: String = JSRuntime.defaultQueueLabel) {
        queue = DispatchQueue(label: queueLabel)
        queue.setSpecific(key: Self.queueKey, value: 1)
        queue.sync {
            context = JSContext()!
            context.name = queueLabel
            context.exceptionHandler = { [weak self] _, exception in
                let text = exception?.toString() ?? "unknown exception"
                Log.error("JS Engine", "Unhandled exception: \(text)")
                self?.onUnhandledException.emit(text)
            }
            let sendMessage: @convention(block) (JSValue) -> Any? = { [weak self] message in
                self?.handleMessage(message)
            }
            context.setObject(sendMessage, forKeyedSubscript: "sendMessage" as NSString)
            context.setObject(JSRuntime.appVersion, forKeyedSubscript: "appVersion" as NSString)
            _ = context.evaluateScript(JSRuntime.deferredFactorySource)
            _ = context.evaluateScript("globalThis.__isArray = Array.isArray;")
            _ = context.evaluateScript("""
            globalThis.__isMap = (v) => v instanceof Map;
            globalThis.__mapToObject = (m) => Object.fromEntries(m);
            globalThis.__isSet = (v) => v instanceof Set;
            globalThis.__setToArray = (s) => Array.from(s);
            globalThis.__isPromise = (v) => v instanceof Promise;
            """)
        }
    }

    /// 原版将 App.version 注入为全局 `appVersion`。
    nonisolated(unsafe) public static var appVersion: String = "3.0.0"

    /// init.js（Venera JS Library）源码。构建时内嵌为常量（InitJSSource.swift），
    /// 与 Flutter 版 assets/init.js 内容一致。
    public static var initJsSource: String {
        initJsEmbedded
    }

    public func setHandler(_ method: String, _ handler: @escaping MessageHandler) {
        lock.lock()
        handlers[method] = handler
        lock.unlock()
    }

    public func setGlobalValue(_ key: String, _ value: Any) {
        let apply = { self.context.setObject(value, forKeyedSubscript: key as NSString) }
        if isOnRuntimeQueue {
            apply()
        } else {
            queue.sync(execute: apply)
        }
    }

    // MARK: - 求值

    /// 同步求值。返回 JSValue（仅可在运行时队列上进一步使用）。
    /// 已在运行时队列上时直接执行，否则跨队列同步等待。
    @discardableResult
    public func evaluate(_ script: String, name: String? = nil) throws -> JSValue {
        if isOnRuntimeQueue {
            return try evaluateOnQueue(script, name: name)
        }
        return try queue.sync {
            try evaluateOnQueue(script, name: name)
        }
    }

    private func evaluateOnQueue(_ script: String, name: String?) throws -> JSValue {
        let result = context.evaluateScript(script, withSourceURL: scriptURL(name))
        if let exception = context.exception {
            context.exception = nil
            throw JSRuntimeException(message: exception.toString())
        }
        return result ?? JSValue(undefinedIn: context)
    }

    /// 异步求值：脚本需返回 Promise；落定后经回调带回结果。
    public func evaluateAsync(_ script: String, name: String? = nil, completion: @escaping @Sendable (Result<Any?, Error>) -> Void) {
        Self.trace("evaluateAsync enter: \(script.prefix(90))")
        queue.async { [self] in
            do {
                let value = try evaluate(script, name: name)
                Self.trace("evaluateAsync evaluated, isPromise=\(value.isObject)")
                awaitPromise(value, completion: completion)
                Self.trace("awaitPromise attached")
            } catch {
                Self.trace("evaluateAsync error: \(error)")
                completion(.failure(error))
            }
        }
    }

    /// 调试跟踪（临时；写入 /tmp/venera_js_trace.txt）。
    static func trace(_ line: String) {
        guard ProcessInfo.processInfo.environment["VENERA_JS_TRACE"] != nil else { return }
        let path = "/tmp/venera_js_trace.txt"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write("\(Date().timeIntervalSince1970) \(line)\n".data(using: .utf8)!)
            try? handle.close()
        } else {
            try? "\(Date().timeIntervalSince1970) \(line)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 等待一个 Promise JSValue 落定。必须在运行时队列上调用。
    func awaitPromise(_ value: JSValue, completion: @escaping @Sendable (Result<Any?, Error>) -> Void) {
        // 源脚本方法不一定 async（如 onImageLoad 返回普通对象、init() 返回
        // undefined）：对非 Promise 取 .then 会抛 JS 异常并泄漏 continuation，
        // 必须先分流。
        let kind = JSValueGetType(context.jsGlobalContextRef, value.jsValueRef)
        var isPromise = false
        if kind == kJSTypeObject {
            isPromise = context.objectForKeyedSubscript("__isPromise")?
                .call(withArguments: [value])?.toBool() ?? false
        }
        guard isPromise else {
            completion(.success(value))
            return
        }
        let then: @convention(block) (JSValue) -> Void = { result in
            completion(.success(result))
        }
        let catchHandler: @convention(block) (JSValue) -> Void = { error in
            completion(.failure(JSRuntimeException(message: error.toString())))
        }
        _ = value.invokeMethod("then", withArguments: [
            JSValue(object: then, in: context),
            JSValue(object: catchHandler, in: context),
        ])
        // 冲刷微任务让 then 链推进。
        drainMicrotasks()
    }

    /// 在运行时队列上执行工作；已在队列上时直接执行（避免自死锁）。
    public func performOnQueue<T>(_ work: () throws -> T) rethrows -> T {
        if isOnRuntimeQueue {
            return try work()
        }
        return try queue.sync {
            try work()
        }
    }

    /// 微任务冲刷：JSC 在每次 evaluateScript 后运行待处理的微任务。
    func drainMicrotasks() {
        context.evaluateScript("0;")
    }

    private func scriptURL(_ name: String?) -> URL? {
        guard let name else { return nil }
        return URL(fileURLWithPath: "/dev/null/\(name)")
    }

    // MARK: - 消息分发

    /// 由 JS 的 sendMessage 调用（运行时队列上同步执行）。
    private func handleMessage(_ message: JSValue) -> Any? {
        guard message.isObject, let dict = message.deepConverted() as? [String: Any] else {
            return nil
        }
        guard let method = dict["method"] as? String else { return nil }
        lock.lock()
        let handler = handlers[method]
        lock.unlock()
        guard let handler else {
            Log.error("JS Engine", "No handler for method: \(method)")
            return nil
        }

        // 先创建 deferred：同步结果直接返回，异步结果经 box 完成回调。
        guard let deferred = context.evaluateScript("__createDeferred()"),
              let resolve = deferred.objectForKeyedSubscript("resolve"),
              let reject = deferred.objectForKeyedSubscript("reject"),
              let promise = deferred.objectForKeyedSubscript("promise")
        else { return nil }
        let box = DeferredBox(resolve: resolve, reject: reject)

        let syncResult: Any?
        do {
            syncResult = try handler(dict) { [weak self] result in
                // 异步完成回调：可能来自任意线程，跳回运行时队列处理。
                guard let self else { return }
                self.queue.async {
                    self.completeAsync(box: box, result: result)
                }
            }
        } catch {
            // 同步错误转化为 JS 异常（在 sendMessage 调用点抛出）。
            let message: String
            if let runtimeError = error as? JSRuntimeException {
                message = runtimeError.message
            } else {
                message = String(describing: error)
            }
            context.exception = JSValue(newErrorFromMessage: message, in: context)
            return nil
        }

        if let syncResult {
            return convertToJS(syncResult)
        }

        return promise
    }

    /// 异步完成：resolve/reject 后冲刷微任务。
    private func completeAsync(box: DeferredBox, result: Result<Any?, Error>) {
        switch result {
        case .success(let value):
            box.resolve.call(withArguments: [convertToJS(value) ?? JSValue(nullIn: context)])
        case .failure(let error):
            let message: String
            if let runtimeError = error as? JSRuntimeException {
                message = runtimeError.message
            } else {
                message = String(describing: error)
            }
            box.reject.call(withArguments: [message])
        }
        drainMicrotasks()
    }

    // MARK: - 值转换

    /// Swift/Foundation 值 → JS。Data 经 Uint8Array 转为 ArrayBuffer。
    func convertToJS(_ value: Any?) -> JSValue? {
        guard let value else { return nil }
        switch value {
        case is Void:
            return JSValue(undefinedIn: context)
        case let data as Data:
            return makeArrayBuffer(data)
        case let dict as [String: Any]:
            return JSValue(object: dict, in: context)
        case let array as [Any]:
            return JSValue(object: array, in: context)
        default:
            return JSValue(object: value, in: context)
        }
    }
}

/// 异步完成令牌：resolve/reject JSValue 只在运行时队列上使用，
/// 以 @unchecked Sendable 跨线程传递。
final class DeferredBox: @unchecked Sendable {
    let resolve: JSValue
    let reject: JSValue
    init(resolve: JSValue, reject: JSValue) {
        self.resolve = resolve
        self.reject = reject
    }
}

public struct JSRuntimeException: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { "JSException: \(message)" }
    public var errorDescription: String? { message }
}
