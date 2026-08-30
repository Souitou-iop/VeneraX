import Foundation

/// 动态 JSON 值，对应 Flutter 版 appdata / 漫画源 data 等处使用的
/// `Map<String, dynamic>`。设置项的值类型混合（字符串 / 整数 / 浮点 /
/// 布尔 / 数组 / 对象），因此整个设置存储建立在动态 JSON 之上。
public enum JSON: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
    case blob(Data)

    // MARK: - 访问器

    public var isNull: Bool { if case .null = self { return true }; return false }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .string(let v): return ["true", "1"].contains(v.lowercased()) ? true : ["false", "0"].contains(v.lowercased()) ? false : nil
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var blobValue: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSON {
        get {
            if case .object(let dict) = self, let v = dict[key] { return v }
            return .null
        }
        set {
            var dict: [String: JSON]
            if case .object(let existing) = self {
                dict = existing
            } else if case .null = self {
                dict = [:]
            } else {
                return
            }
            dict[key] = newValue
            self = .object(dict)
        }
    }

    public subscript(index: Int) -> JSON {
        get {
            if case .array(let list) = self, index >= 0, index < list.count { return list[index] }
            return .null
        }
        set {
            guard case .array(var list) = self, index >= 0, index <= list.count else { return }
            if index == list.count { list.append(newValue) } else { list[index] = newValue }
            self = .array(list)
        }
    }

    // MARK: - 与 Foundation 桥接

    /// 从任意 Foundation/JSON 反序列化产物尽力转换。
    public init(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Int64: self = .int(Int(v))
        case let v as Double: self = .double(v)
        case let v as String: self = .string(v)
        case let v as Data: self = .blob(v)
        case let v as [Any]: self = .array(v.map { JSON(any: $0) })
        case let v as [String: Any]:
            var dict: [String: JSON] = [:]
            for (k, item) in v { dict[k] = JSON(any: item) }
            self = .object(dict)
        case let v as NSNumber:
            // NSNumber 布尔与数值无法完全区分，优先按 CFBoolean 判断。
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if String(cString: v.objCType) == "c" {
                self = .bool(v.boolValue)
            } else if v.doubleValue == v.doubleValue.truncatingRemainder(dividingBy: 1), v.doubleValue < 1.0e15 {
                self = .double(v.doubleValue)
            } else if String(cString: v.objCType) == "d" {
                self = .double(v.doubleValue)
            } else {
                self = .int(v.intValue)
            }
        default:
            self = .null
        }
    }

    public var asAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .blob(let v): return v
        case .array(let v): return v.map { $0.asAny }
        case .object(let v):
            var dict: [String: Any] = [:]
            for (k, item) in v { dict[k] = item.asAny }
            return dict
        }
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSON].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSON].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .blob(let v): try container.encode(v.base64EncodedString())
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    // MARK: - 序列化

    public func encodedString(prettyPrinted: Bool = false) throws -> String {
        let any = asAny
        let options: JSONSerialization.WritingOptions = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            : [.sortedKeys, .fragmentsAllowed]
        let data = try JSONSerialization.data(withJSONObject: any, options: options)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    public static func decode(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSON(any: any)
    }
}
