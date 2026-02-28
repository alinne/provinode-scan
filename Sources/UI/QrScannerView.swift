import SwiftUI
import AVFoundation

struct QrScannerView: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if targetEnvironment(simulator)
        VStack(spacing: 12) {
            Text("Camera scanning is unavailable in the iOS simulator.")
                .multilineTextAlignment(.center)
            Button("Close") {
                dismiss()
            }
        }
        .padding(24)
        #else
        ScannerCameraView { value in
            onScan(value)
            dismiss()
        }
        #endif
    }
}

#if !targetEnvironment(simulator)
private struct ScannerCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
    }
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(input)
        else {
            return
        }

        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            return
        }

        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.layer.bounds
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        captureSession.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let value = metadataObject.stringValue
        else {
            return
        }

        captureSession.stopRunning()
        onScan?(value)
    }
}
#endif
