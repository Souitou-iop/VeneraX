import Foundation
import CryptoKit
import CommonCrypto

/// sendMessage 各 method 的处理器集合。逐条对应 `js_engine.dart`
/// 的 `_messageReceiver` 分支；加密算法与 pointycastle 实现保持字节级兼容。
public enum JSHandlers {
    // MARK: - convert

    /// `convert` method：编码 / 哈希 / HMAC / AES / RSA。
    /// 失败时返回 nil（对齐原版 catch 分支）。
    public static func convert(_ message: [String: Any]) -> Any? {
        guard let type = message["type"] as? String else { return nil }
        let isEncode = message["isEncode"] as? Bool ?? true
        do {
            switch type {
            case "utf8":
                if isEncode, let text = message["value"] as? String {
                    return Data(text.utf8)
                }
                if !isEncode, let data = message["value"] as? Data {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            case "gbk":
                if isEncode, let text = message["value"] as? String {
                    return Data(text.utf8).gbkEncoded
                }
                if !isEncode, let data = message["value"] as? Data {
                    return data.gbkDecoded
                }
                return nil
            case "base64":
                if isEncode, let data = message["value"] as? Data {
                    return data.base64EncodedString()
                }
                if !isEncode, let text = message["value"] as? String {
                    return Data(base64Encoded: text)
                }
                return nil
            case "md5":
                return digest(.md5, message["value"])
            case "sha1":
                return digest(.sha1, message["value"])
            case "sha256":
                return digest(.sha256, message["value"])
            case "sha512":
                return digest(.sha512, message["value"])
            case "hmac":
                guard let key = message["key"] as? Data else { return nil }
                let hash = message["hash"] as? String ?? "sha256"
                let value = Data(valueData(message["value"]))
                let symmetricKey = SymmetricKey(data: key)
                let authenticated: Data
                switch hash {
                case "md5": authenticated = Data(HMAC<Insecure.MD5>.authenticationCode(for: value, using: symmetricKey))
                case "sha1": authenticated = Data(HMAC<Insecure.SHA1>.authenticationCode(for: value, using: symmetricKey))
                case "sha256": authenticated = Data(HMAC<SHA256>.authenticationCode(for: value, using: symmetricKey))
                case "sha512": authenticated = Data(HMAC<SHA512>.authenticationCode(for: value, using: symmetricKey))
                default: throw JSRuntimeException(message: "Unsupported hash: \(hash)")
                }
                if message["isString"] as? Bool == true {
                    return authenticated.map { String(format: "%02x", $0) }.joined()
                }
                return authenticated
            case "aes-ecb":
                return try aes(message, mode: CCMode(kCCModeECB), option: 0)
            case "aes-cbc":
                return try aes(message, mode: CCMode(kCCModeCBC), option: 0)
            case "aes-cfb":
                // pointycastle 的 blockSize 以比特为单位；kCCModeCFB +
                // CFB8/CFB128 option 与其 CFBBlockCipher(blockSizeBits) 对应。
                let blockSize = message["blockSize"] as? Int ?? 128
                let option: CCModeOptions = blockSize == 128 ? kModeOptionCFB128 : kModeOptionCFB8
                return try aes(message, mode: CCMode(kCCModeCFB), option: option)
            case "aes-ofb":
                return try aes(message, mode: CCMode(kCCModeOFB), option: 0)
            case "rsa":
                if !isEncode, let key = message["key"] as? String, let value = message["value"] as? Data {
                    return try rsaDecrypt(privateKeyBase64: key, input: value)
                }
                return nil
            default:
                return message["value"]
            }
        } catch {
            Log.error("JS Engine", "Failed to convert \(type): \(error)")
            return nil
        }
    }

    private enum DigestAlgo {
        case md5, sha1, sha256, sha512
    }

    private static func digest(_ algo: DigestAlgo, _ value: Any?) -> Data? {
        let data = Data(valueData(value))
        switch algo {
        case .md5: return Data(Insecure.MD5.hash(data: data))
        case .sha1: return Data(Insecure.SHA1.hash(data: data))
        case .sha256: return Data(SHA256.hash(data: data))
        case .sha512: return Data(SHA512.hash(data: data))
        }
    }

    /// JS 侧传入的 value 可能是 ArrayBuffer(Data)、字符串或数组。
    private static func valueData(_ value: Any?) -> Data {
        switch value {
        case let data as Data: return data
        case let string as String: return Data(string.utf8)
        case let array as [Int]: return Data(array.map { UInt8(truncatingIfNeeded: $0) })
        case let array as [UInt8]: return Data(array)
        default: return Data()
        }
    }

    // MARK: - AES（CommonCrypto，覆盖 ECB/CBC/CFB/OFB，无填充，逐块处理）

    /// CommonCryptorSPI 的稳定枚举值（Swift 模块未导出）。
    private static let kModeOptionCFB8: CCModeOptions = 3
    private static let kModeOptionCFB128: CCModeOptions = 4

    private static func aes(_ message: [String: Any], mode: CCMode, option: CCModeOptions) throws -> Data? {
        guard let key = message["key"] as? Data else { return nil }
        guard let value = message["value"] as? Data else { return nil }
        let iv = message["iv"] as? Data ?? Data()
        let isEncode = message["isEncode"] as? Bool ?? true
        let keyLength = key.count

        var cryptorRef: CCCryptorRef?
        let operation: CCOperation = isEncode ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    operation,
                    mode,
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCPadding(ccNoPadding),
                    ivBytes.isEmpty ? nil : ivBytes.rawPointer(count: iv.count),
                    keyBytes.rawPointer(count: keyLength),
                    keyLength,
                    nil, 0,
                    0,
                    option,
                    &cryptorRef
                )
            }
        }
        guard status == kCCSuccess, let cryptorRef else { return nil }
        defer { CCCryptorRelease(cryptorRef) }

        var output = Data(count: value.count + kCCBlockSizeAES128)
        var moved: Int = 0
        let result = output.withUnsafeMutableBytes { outBytes in
            value.withUnsafeBytes { inBytes in
                CCCryptorUpdate(cryptorRef, inBytes.rawPointer(count: value.count), value.count, outBytes.baseAddress, outBytes.count, &moved)
            }
        }
        guard result == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    // MARK: - RSA（PKCS#8 私钥，PKCS#1 v1.5 解密，逐块处理）

    private static func rsaDecrypt(privateKeyBase64: String, input: Data) throws -> Data {
        guard let der = Data(base64Encoded: privateKeyBase64) else {
            throw JSRuntimeException(message: "invalid rsa key")
        }
        let pkcs1 = try ASN1.stripPKCS8Wrapper(der)
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary, nil) else {
            throw JSRuntimeException(message: "failed to import rsa key")
        }
        let keySize = SecKeyGetBlockSize(secKey)
        var output = Data()
        var offset = 0
        while offset < input.count {
            let chunk = input.subdata(in: offset..<min(offset + keySize, input.count))
            var error: Unmanaged<CFError>?
            guard let decrypted = SecKeyCreateDecryptedData(secKey, .rsaEncryptionPKCS1, chunk as CFData, &error) as Data? else {
                throw JSRuntimeException(message: "rsa decrypt failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            }
            output.append(decrypted)
            offset += keySize
        }
        return output
    }

    // MARK: - 其他 method

    public static func random(_ message: [String: Any]) -> Double {
        let min = (message["min"] as? Double) ?? 0
        let max = (message["max"] as? Double) ?? 1
        return min + (max - min) * Double.random(in: 0..<1)
    }

    public static func uuidV1() -> String {
        // 时间基 UUID v1：满足 init.js「每次调用生成新 UUID」的约定。
        // RFC 4122 v1 布局：time_low(4) time_mid(2) time_hi_and_version(2)
        // clock_seq(2) node(6)。
        let gregorianTicks = UInt64(Date().timeIntervalSince1970 * 10_000_000) + 0x01B21DD213814000
        var bytes = [UInt8]()
        var ticks = gregorianTicks
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: ticks & 0xFF))
            ticks >>= 8
        }
        // version 1 写入 time_hi 高 4 位
        bytes[6] = (bytes[6] & 0x0F) | 0x10
        // clock_seq：随机并保留 variant 位
        let clockSeq = UInt16.random(in: 0...0x3FFF) | 0x8000
        bytes.append(UInt8(truncatingIfNeeded: clockSeq >> 8))
        bytes.append(UInt8(truncatingIfNeeded: clockSeq & 0xFF))
        for _ in 0..<6 {
            bytes.append(UInt8.random(in: 0...255))
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    public static func locale() -> String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.language.region?.identifier ?? ""
        return region.isEmpty ? language : "\(language)_\(region)"
    }

    public static func platform() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "windows"
        #else
        return "unknown"
        #endif
    }

    public static func setClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    public static func getClipboard() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #else
        nil
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - 辅助扩展

private extension UnsafeRawBufferPointer {
    /// 空 buffer（长度 0）时 baseAddress 为 nil，回退 nil 表示「无 IV」。
    func rawPointer(count: Int) -> UnsafeRawPointer? {
        guard count > 0 else { return nil }
        return baseAddress
    }
}

private extension Data {
    /// GBK 编码：GB_18030_2000 是 GBK 的超集，编码结果对 GBK 兼容。
    var gbkEncoded: Data? {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0631)))
        return self.utf8String?.data(using: encoding)
    }

    var gbkDecoded: String? {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0631)))
        guard let string = String(data: self, encoding: encoding) else { return nil }
        return string
    }

    var utf8String: String? {
        String(data: self, encoding: .utf8)
    }
}

/// 极简 DER 解析：仅需处理 PKCS#8 外层包裹与长度编码。
enum ASN1 {
    static func stripPKCS8Wrapper(_ der: Data) throws -> Data {
        var reader = DERReader(data: der)
        let top = try reader.readTLV()
        guard top.tag == 0x30 else {
            // 已是 PKCS#1，原样返回
            return der
        }
        var inner = DERReader(data: top.content)
        _ = try inner.readTLV() // version INTEGER
        let alg = try inner.readTLV() // AlgorithmIdentifier SEQUENCE
        guard alg.tag == 0x30 else { throw JSRuntimeException(message: "bad pkcs8") }
        let octet = try inner.readTLV()
        guard octet.tag == 0x04 else { throw JSRuntimeException(message: "bad pkcs8") }
        return octet.content
    }

    struct TLV {
        let tag: UInt8
        let content: Data
    }

    struct DERReader {
        let data: Data
        var offset = 0

        mutating func readTLV() throws -> TLV {
            guard offset + 2 <= data.count else { throw JSRuntimeException(message: "der truncated") }
            let tag = data[data.startIndex + offset]
            offset += 1
            var length = Int(data[data.startIndex + offset])
            offset += 1
            if length & 0x80 != 0 {
                let lengthBytes = length & 0x7F
                guard lengthBytes > 0, lengthBytes <= 4, offset + lengthBytes <= data.count else {
                    throw JSRuntimeException(message: "der bad length")
                }
                length = 0
                for _ in 0..<lengthBytes {
                    length = (length << 8) | Int(data[data.startIndex + offset])
                    offset += 1
                }
            }
            guard offset + length <= data.count else { throw JSRuntimeException(message: "der truncated") }
            let content = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
            offset += length
            return TLV(tag: tag, content: content)
        }
    }
}
