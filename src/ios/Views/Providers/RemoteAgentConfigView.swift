import SwiftUI
import AVFoundation

/// Configuration section for the "My Computer" (CC Pocket Bridge) provider.
/// Lets the user scan the Bridge's QR code (auto-fills wss URL + token) and
/// pick the project path the agent should run in.
struct RemoteAgentConfigView: View {
    @Binding var wssURL: String
    @Binding var token: String
    @Binding var projectPath: String

    @State private var showScanner = false

    var body: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.medium))
            }
            Text("Scan the QR code printed by your Bridge Server — the URL and token fill in automatically. You can also paste them below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Quick Setup")
        }

        Section("Project Path") {
            TextField("/path/to/project", text: $projectPath)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Text("The working directory the agent runs in on your computer (e.g. /home/ubuntu).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        .sheet(isPresented: $showScanner) {
            QRScannerSheet { urlString in
                applyScanned(urlString)
            }
        }
    }

    /// Parse a scanned deep link (wss://host/path?token=xxx) into URL + token.
    private func applyScanned(_ urlString: String) {
        guard let components = URLComponents(string: urlString) else { return }
        guard let scheme = components.scheme, scheme.hasPrefix("ws") else { return }

        var base = components
        base.queryItems = nil
        base.fragment = nil
        if let baseString = base.string {
            wssURL = baseString
        }
        if let token = components.queryItems?.first(where: { $0.name == "token" })?.value {
            self.token = token
        }
    }
}

// MARK: - QR Scanner (AVFoundation)

/// Full-screen camera scanner that reports the first detected QR payload.
struct QRScannerSheet: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var didReport = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        startCamera()
    }

    private func startCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            dismissWithError("Camera unavailable")
            return
        }
        let session = AVCaptureSession()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        captureSession = session

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReport,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue else { return }
        didReport = true
        captureSession?.stopRunning()
        onScan?(payload)
        dismiss(animated: true)
    }

    private func dismissWithError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
}
