import AVFoundation
import SwiftUI
import UIKit
import VeneraKit

/// Native QR scanner used for importing `venera://sync` configuration.
struct SyncConfigScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if let errorMessage {
                    ContentUnavailableView(
                        "Camera unavailable".tl,
                        systemImage: "camera.slash",
                        description: Text(verbatim: errorMessage)
                    )
                    .padding()
                } else {
                    CameraScannerRepresentable(
                        onCode: onCode,
                        onError: { errorMessage = $0 }
                    )
                    .ignoresSafeArea()
                    ScannerOverlay()
                }
            }
            .navigationTitle("Scan Sync QR".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
            }
        }
    }
}

private struct ScannerOverlay: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Point the camera at the sync QR code on the other device".tl)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 36)
        }
        .allowsHitTesting(false)
    }
}

private struct CameraScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerViewController {
        let controller = CameraScannerViewController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ controller: CameraScannerViewController, context: Context) {}
}

private final class CameraScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.github.kyosee.venerax.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReportError = false
    private var didScan = false

    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureSession() }
                else { self.reportError("Camera permission was denied. Enable camera access in Settings.") }
            }
        case .denied, .restricted:
            reportError("Camera permission was denied. Enable camera access in Settings.")
        @unknown default:
            reportError("Camera is unavailable on this device.")
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = AVCaptureDevice.default(for: .video) else {
                self.reportError("Camera is unavailable on this device.")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.reportError("Camera is unavailable on this device.")
                    return
                }
                self.session.beginConfiguration()
                self.session.addInput(input)
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration()

                DispatchQueue.main.async {
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    self.previewLayer = preview
                    self.view.layer.insertSublayer(preview, at: 0)
                    self.view.setNeedsLayout()
                }
                self.session.startRunning()
            } catch {
                self.reportError("Camera could not be started: \(error.localizedDescription)")
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let value = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .compactMap(\.stringValue)
                .first(where: { SyncConfigTransfer.isSyncConfigURI($0) }) else { return }
        didScan = true
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        onCode?(value)
    }

    private func reportError(_ message: String) {
        guard !didReportError else { return }
        didReportError = true
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}

struct SyncConfigPINEntryView: View {
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the 6-digit PIN shown on the other device".tl)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("PIN".tl, text: $pin)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .monospacedDigit()
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .onChange(of: pin) { _, value in
                            pin = String(value.filter(\.isNumber).prefix(6))
                        }
                }
                Section {
                    Button("Confirm".tl) {
                        onConfirm(pin)
                    }
                    .disabled(pin.count != 6)
                }
            }
            .navigationTitle("Enter PIN".tl)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
            }
        }
    }
}
