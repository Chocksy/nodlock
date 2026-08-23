import SwiftUI
import AVFoundation
import AudioToolbox

// Live camera QR scanner. Reports the first decoded string, then stops.
struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.coordinator = context.coordinator
        context.coordinator.controller = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let parent: QRScannerView
        weak var controller: ScannerController?
        private var handled = false
        init(_ parent: QRScannerView) { self.parent = parent }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            handled = true
            controller?.stop() // tear the camera down immediately, don't wait for dismissal
            AudioServicesPlaySystemSound(1108) // subtle capture tick
            parent.onFound(value)
        }
    }
}

// UIKit host for the AVCaptureSession + preview layer.
final class ScannerController: UIViewController {
    weak var coordinator: QRScannerView.Coordinator?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setupSession() }
                    else { self?.coordinator?.parent.onError("Camera access denied.") }
                }
            }
        default:
            coordinator?.parent.onError("Camera access denied. Enable it in Settings.")
        }
    }

    private func setupSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            coordinator?.parent.onError("No camera available.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            coordinator?.parent.onError("Cannot start scanner.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }
}
