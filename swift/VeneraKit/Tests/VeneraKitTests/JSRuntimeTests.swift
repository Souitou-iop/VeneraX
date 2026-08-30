import XCTest
import JavaScriptCore
@testable import VeneraKit

/// 跨线程结果盒子（测试辅助）。
final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Any?
    func set(_ value: Any?) {
        lock.lock()
        storage = value
        lock.unlock()
    }
    var jsValue: JSValue? {
        lock.lock()
        defer { lock.unlock() }
        return storage as? JSValue
    }
    var intValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return ((storage as? JSValue)?.toInt32()).map(Int.init) ?? -1
    }
    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return (storage as? JSValue)?.toString() ?? ""
    }
}

final class JSRuntimeTests: XCTestCase {
    /// 尖峰验证 1：同步求值 + 同步消息处理器。
    func testSyncEvaluationAndMessage() throws {
        let runtime = JSRuntime()
        runtime.setHandler("add") { message, _ in
            let a = message["a"] as? Int ?? 0
            let b = message["b"] as? Int ?? 0
            return a + b
        }
        let result = try runtime.evaluate("sendMessage({method: 'add', a: 2, b: 3})")
        XCTAssertEqual(result.toInt32(), 5)
    }

    /// 尖峰验证 2：异步处理器（Promise 返回 + resolve 后微任务推进）。
    func testAsyncHandlerResolvesPromise() {
        let runtime = JSRuntime()
        runtime.setHandler("asyncValue") { message, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                completion(.success(message["value"]))
            }
            return nil
        }
        let script = """
        (async () => {
            const v = await sendMessage({method: 'asyncValue', value: 42});
            return v * 2;
        })()
        """
        let box = ValueBox()
        let expectation = expectation(description: "async done")
        runtime.queue.async {
            do {
                let promise = try runtime.evaluate(script)
                runtime.awaitPromise(promise) { result in
                    if case .success(let value) = result { box.set(value) }
                    expectation.fulfill()
                }
            } catch {
                box.set(nil)
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(box.intValue, 84)
    }

    /// 尖峰验证 3：连续多个 await + setTimeout（init.js 的 delay 机制）。
    func testAsyncChainWithTimers() {
        let runtime = JSRuntime()
        runtime.setHandler("convert") { message, _ in
            JSHandlers.convert(message)
        }
        runtime.setHandler("log") { _, _ in nil }
        runtime.setHandler("delay") { message, completion in
            let ms = (message["time"] as? Double) ?? ((message["time"] as? Int).map(Double.init)) ?? 0
            DispatchQueue.global().asyncAfter(deadline: .now() + ms / 1000) {
                completion(.success(nil))
            }
            return nil
        }
        runtime.setHandler("fetchLike") { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                completion(.success(["status": 200, "body": "ok"]))
            }
            return nil
        }
        let script = """
        (async () => {
            const order = [];
            await sendMessage({method: 'delay', time: 30});
            order.push('timer1');
            const res = await sendMessage({method: 'fetchLike'});
            order.push(res.body);
            await new Promise(r => setTimeout(r, 10));  // init.js 的 setTimeout 路径
            order.push('timer2');
            return order.join(',');
        })()
        """
        let box = ValueBox()
        let expectation = expectation(description: "chain done")
        runtime.queue.async {
            do {
                try runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
                let promise = try runtime.evaluate(script)
                runtime.awaitPromise(promise) { result in
                    if case .success(let value) = result { box.set(value) }
                    expectation.fulfill()
                }
            } catch {
                box.set(nil)
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(box.stringValue, "timer1,ok,timer2")
    }

    /// 尖峰验证 4：ArrayBuffer 往返（convert 管线的根基）。
    func testArrayBufferRoundTrip() {
        let runtime = JSRuntime()
        runtime.setHandler("reverseBytes") { message, completion in
            guard let data = message["value"] as? Data else {
                completion(.failure(JSRuntimeException(message: "no bytes, got \(type(of: message["value"]))")))
                return nil
            }
            completion(.success(Data(data.reversed())))
            return nil
        }
        let script = """
        (async () => {
            const input = new Uint8Array([1, 2, 3, 4]).buffer;
            const output = await sendMessage({method: 'reverseBytes', value: input});
            return Array.from(new Uint8Array(output)).join('-');
        })()
        """
        let box = ValueBox()
        let expectation = expectation(description: "bytes done")
        runtime.queue.async {
            do {
                let promise = try runtime.evaluate(script)
                runtime.awaitPromise(promise) { result in
                    if case .success(let value) = result { box.set(value) }
                    expectation.fulfill()
                }
            } catch {
                box.set(nil)
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(box.stringValue, "4-3-2-1", "ArrayBuffer 往返失败")
    }

    /// 尖峰验证 5：init.js 完整加载 + Convert 各算法走通。
    func testInitJsLoadsAndConvertWorks() throws {
        let runtime = JSRuntime()
        runtime.setHandler("convert") { message, _ in
            JSHandlers.convert(message)
        }
        runtime.setHandler("log") { message, _ in
            Log.info("JS", "\(message["title"] ?? ""): \(message["content"] ?? "")")
            return nil
        }
        try runtime.evaluate(JSRuntime.initJsSource, name: "<init>")
        let hex = try runtime.evaluate("Convert.hexEncode(Convert.md5(Convert.encodeUtf8('hello')))")
        XCTAssertEqual(hex.toString(), "5d41402abc4b2a76b9719d911017c592")
        let b64 = try runtime.evaluate("Convert.encodeBase64(Convert.encodeUtf8('venera'))")
        XCTAssertEqual(b64.toString(), "dmVuZXJh")
        let roundTrip = try runtime.evaluate("Convert.decodeUtf8(Convert.decodeBase64(Convert.encodeBase64(Convert.encodeUtf8('venera'))))")
        XCTAssertEqual(roundTrip.toString(), "venera")
        let script = """
        (() => {
            const key = Convert.encodeUtf8('0123456789abcdef');
            const iv = Convert.encodeUtf8('abcdef9876543210');
            const encrypted = Convert.encryptAesCbc(Convert.encodeUtf8('attack at dawn!!'), key, iv);
            const decrypted = Convert.decryptAesCbc(encrypted, key, iv);
            return Convert.decodeUtf8(decrypted);
        })()
        """
        let aes = try runtime.evaluate(script)
        XCTAssertEqual(aes.toString(), "attack at dawn!!")
        _ = try runtime.evaluate("console.log('engine alive')")
        let uuid = try runtime.evaluate("createUuid()")
        XCTAssertFalse(uuid.toString().isEmpty)
    }

    func testThrowingAsyncHandlerRejects() {
        let runtime = JSRuntime()
        runtime.setHandler("boom") { _, completion in
            DispatchQueue.global().async {
                completion(.failure(JSRuntimeException(message: "network unreachable")))
            }
            return nil
        }
        let script = """
        (async () => {
            try {
                await sendMessage({method: 'boom'});
                return 'no-throw';
            } catch (e) {
                return 'caught:' + e;
            }
        })()
        """
        let box = ValueBox()
        let expectation = expectation(description: "reject done")
        runtime.queue.async {
            do {
                let promise = try runtime.evaluate(script)
                runtime.awaitPromise(promise) { outcome in
                    if case .success(let value) = outcome { box.set(value) }
                    expectation.fulfill()
                }
            } catch {
                box.set(nil)
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(box.stringValue, "caught:network unreachable")
    }
}
