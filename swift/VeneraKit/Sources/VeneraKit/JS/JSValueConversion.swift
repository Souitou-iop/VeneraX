import Foundation
import JavaScriptCore

/// JSValue 深度转换：ArrayBuffer ↔ Data 的可靠路径。
/// `JSValue.toDictionary()` 会把 ArrayBuffer 搅成索引字典，因此字节字段
/// 必须经 C API（JSValueGetTypedArrayType / JSObjectGetArrayBufferBytesPtr）提取。
extension JSValue {
    var isArrayBufferValue: Bool {
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(context.jsGlobalContextRef, jsValueRef, &exception)
        return exception == nil && type == kJSTypedArrayTypeArrayBuffer
    }

    var arrayBufferData: Data? {
        guard isArrayBufferValue else { return nil }
        guard let object = JSValueToObject(context.jsGlobalContextRef, jsValueRef, nil) else {
            return nil
        }
        var exception: JSValueRef?
        let byteLength = Int(JSObjectGetArrayBufferByteLength(context.jsGlobalContextRef, object, &exception))
        guard exception == nil else { return nil }
        guard byteLength > 0 else { return Data() }
        guard let pointer = JSObjectGetArrayBufferBytesPtr(context.jsGlobalContextRef, object, &exception), exception == nil else {
            return nil
        }
        return Data(bytes: pointer, count: byteLength)
    }

    /// 深度转换为 Foundation 值（ArrayBuffer → Data）。
    func deepConverted(maxDepth: Int = 10) -> Any {
        if isArrayBufferValue {
            return arrayBufferData ?? Data()
        }
        let kind = JSValueGetType(context.jsGlobalContextRef, jsValueRef)
        if kind == kJSTypeBoolean { return toBool() }
        if kind == kJSTypeNumber {
            // 整数值归一为 Int（对齐 JSON/Dart 语义），其余保持 Double。
            let number = toDouble() ?? 0
            if number.truncatingRemainder(dividingBy: 1) == 0, abs(number) < 1e15 {
                return Int(number)
            }
            return number
        }
        if kind == kJSTypeString { return toString() }
        if kind == kJSTypeNull || kind == kJSTypeUndefined { return NSNull() }
        if maxDepth <= 0 { return NSNull() }
        if kind == kJSTypeObject {
            let isArray = context
                .objectForKeyedSubscript("__isArray")?
                .call(withArguments: [self])?
                .toBool() ?? false
            if isArray {
                let count = Int(objectForKeyedSubscript("length")?.toDouble() ?? 0)
                var array: [Any] = []
                array.reserveCapacity(count)
                for index in 0..<count {
                    let child = objectAtIndexedSubscript(index)?.deepConverted(maxDepth: maxDepth - 1)
                    array.append(child ?? NSNull())
                }
                return array
            }
            // JS Map / Set：源脚本（如 Komiic 章节）使用 Map 传递分组章节。
            let isMap = context.objectForKeyedSubscript("__isMap")?
                .call(withArguments: [self])?.toBool() ?? false
            if isMap, let converted = context.objectForKeyedSubscript("__mapToObject")?
                .call(withArguments: [self]) {
                return converted.deepConverted(maxDepth: maxDepth - 1)
            }
            let isSet = context.objectForKeyedSubscript("__isSet")?
                .call(withArguments: [self])?.toBool() ?? false
            if isSet, let converted = context.objectForKeyedSubscript("__setToArray")?
                .call(withArguments: [self]) {
                return converted.deepConverted(maxDepth: maxDepth - 1)
            }
            let keys = (toDictionary() as? [String: Any])?.keys.map { $0 } ?? []
            var dict: [String: Any] = [:]
            for key in keys {
                let child = objectForKeyedSubscript(key)?.deepConverted(maxDepth: maxDepth - 1)
                dict[key] = child ?? NSNull()
            }
            return dict
        }
        if let dict = toDictionary() {
            return dict
        }
        return NSNull()
    }
}

/// Swift 值 → JS ArrayBuffer：malloc 拷贝 + NoCopy 构造 + 释放回调。
extension JSRuntime {
    func makeArrayBuffer(_ data: Data) -> JSValue {
        if data.isEmpty {
            return context.evaluateScript("new ArrayBuffer(0)") ?? JSValue(nullIn: context)
        }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: MemoryLayout<UInt8>.alignment)
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        var exception: JSValueRef?
        let buffer = JSObjectMakeArrayBufferWithBytesNoCopy(
            context.jsGlobalContextRef,
            pointer,
            data.count,
            { bytes, _ in bytes?.deallocate() },
            nil,
            &exception
        )
        if let buffer, exception == nil {
            return JSValue(jsValueRef: buffer, in: context)
        }
        Log.error("JS Engine", "Failed to make ArrayBuffer")
        return JSValue(nullIn: context)
    }
}
