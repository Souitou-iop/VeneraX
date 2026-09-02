import Foundation
import CryptoKit
import CommonCrypto

/// PIN-protected WebDAV sync configuration exchanged as `venera://sync` QR data.
public struct SyncConfigPayload: Sendable, Equatable {
    public let url: String
    public let user: String
    public let pass: String
    public let autoSync: Bool
    public let disableSyncFields: String

    public init(url: String, user: String, pass: String, autoSync: Bool, disableSyncFields: String) {
        self.url = url
        self.user = user
        self.pass = pass
        self.autoSync = autoSync
        self.disableSyncFields = disableSyncFields
    }
}

public enum SyncConfigTransferError: Error, Equatable, Sendable {
    case notSyncConfig
    case unsupportedVersion
    case malformed
    case wrongPinOrTampered
}

public enum SyncConfigTransfer {
    private static let scheme = "venera"
    private static let host = "sync"
    private static let version = 1
    private static let iterations = 200_000
    private static let keyLength = 32
    private static let saltLength = 16
    private static let ivLength = 12
    private static let tagLength = 16

    public static func isSyncConfigURI(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == scheme,
              components.host == host,
              components.queryItems?.first(where: { $0.name == "d" })?.value?.isEmpty == false else {
            return false
        }
        return true
    }

    /// Decodes the format used by Flutter's `sync_config_transfer.dart`.
    public static func decode(uri raw: String, pin: String) throws -> SyncConfigPayload {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == scheme, components.host == host else {
            throw SyncConfigTransferError.notSyncConfig
        }

        guard let versionText = components.queryItems?.first(where: { $0.name == "v" })?.value,
              let payloadVersion = Int(versionText) else {
            throw SyncConfigTransferError.malformed
        }
        guard payloadVersion <= version else {
            throw SyncConfigTransferError.unsupportedVersion
        }
        guard let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value,
              !encoded.isEmpty,
              let blob = decodeBase64URL(encoded),
              blob.count >= saltLength + ivLength + tagLength else {
            throw SyncConfigTransferError.malformed
        }

        let salt = blob.prefix(saltLength)
        let iv = blob.dropFirst(saltLength).prefix(ivLength)
        let encrypted = blob.dropFirst(saltLength + ivLength)
        let key = try deriveKey(pin: pin, salt: Data(salt))

        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: Data(iv))
            let ciphertext = encrypted.dropLast(tagLength)
            let tag = encrypted.suffix(tagLength)
            let sealed = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw SyncConfigTransferError.wrongPinOrTampered
        }

        do {
            let object = try JSONDecoder().decode([String: JSON].self, from: plaintext)
            return SyncConfigPayload(
                url: object["url"]?.stringValue ?? "",
                user: object["user"]?.stringValue ?? "",
                pass: object["pass"]?.stringValue ?? "",
                autoSync: object["autoSync"]?.boolValue ?? false,
                disableSyncFields: object["disableSyncFields"]?.stringValue ?? ""
            )
        } catch {
            throw SyncConfigTransferError.malformed
        }
    }

    private static func deriveKey(pin: String, salt: Data) throws -> SymmetricKey {
        var key = Data(repeating: 0, count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                pin.data(using: .utf8)!.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordBytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyBytes.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SyncConfigTransferError.malformed }
        return SymmetricKey(data: key)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
}
