import SwiftUI
import LocalAuthentication
import CryptoKit
import VeneraKit

/// 应用锁：生物识别（FaceID/TouchID）+ PIN。凭据为设备本地设置键
/// （appLockCredential：{salt, hash}，SHA-256(salt+pin)）。
struct AppLockView: View {
    @State private var pin = ""
    @State private var error: String?
    @State private var isUnlocked = false
    var onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Unlock VeneraX".tl)
                .font(.title3.weight(.medium))
            if isBiometric {
                Button {
                    authenticateBiometric()
                } label: {
                    Label("Use Face ID / Touch ID".tl, systemImage: "faceid")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            if hasPin {
                SecureField("PIN".tl, text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .onSubmit(checkPin)
                Button("Unlock".tl) { checkPin() }
            }
            if let error {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .onAppear {
            if isBiometric {
                authenticateBiometric()
            }
        }
    }

    private var lockType: String {
        AppData.shared.settings["appLockType"].stringValue ?? "biometric"
    }

    private var isBiometric: Bool { lockType == "biometric" }

    private var hasPin: Bool {
        AppData.shared.settings["appLockCredential"].objectValue != nil
    }

    private func authenticateBiometric() {
        let context = LAContext()
        var evalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evalError) else {
            if hasPin { return }
            error = evalError?.localizedDescription
            // 无法使用生物识别且无 PIN 时放行（避免死锁）
            unlock()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock VeneraX".tl) { success, _ in
            Task { @MainActor in
                if success {
                    unlock()
                } else if !hasPin {
                    // 用户取消且无 PIN 备用：仍锁定，等待重试按钮
                }
            }
        }
    }

    private func checkPin() {
        let credential = AppData.shared.settings["appLockCredential"].objectValue ?? [:]
        guard let salt = credential["salt"]?.stringValue,
              let expected = credential["hash"]?.stringValue else { return }
        let digest = Self.hashPin(pin, salt: salt)
        if digest == expected {
            unlock()
        } else {
            error = "Wrong PIN".tl
        }
    }

    private func unlock() {
        isUnlocked = true
        onUnlock()
    }

    static func hashPin(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
