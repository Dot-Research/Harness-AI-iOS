import SwiftUI
import AVFoundation
import HarnessCore

/// Recognizes only valid, unexpired Harness pairing QR payloads. Scanned codes
/// never open URLs, execute commands, or enter the user's conversation history.
struct QRScanner: UIViewControllerRepresentable {
    var onPayload: (String) -> Void
    var onError: (String) -> Void = { _ in }
    func makeUIViewController(context: Context) -> PairingScannerController {
        PairingScannerController(onPayload: onPayload, onError: onError)
    }
    func updateUIViewController(_ controller: PairingScannerController, context: Context) {
        controller.onPayload = onPayload
        controller.onError = onError
    }
    static func dismantleUIViewController(_ controller: PairingScannerController, coordinator: ()) { controller.stop() }
}

final class PairingScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onPayload: (String) -> Void
    var onError: (String) -> Void
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "org.harnessai.Harness.pairing-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var configured = false
    private var visible = false
    private var lastInvalidPayload: String?
    private let status = UILabel()

    init(onPayload: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onPayload = onPayload; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use the SwiftUI scanner initializer.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        status.textColor = .white
        status.numberOfLines = 0
        status.textAlignment = .center
        status.text = "Scan the pairing code shown by Harness Companion on your computer."
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.visible else { return }
                    if allowed { self.configureAndStart() }
                    else { self.cameraUnavailable("Enable camera access in iPhone Settings to scan a pairing code.") }
                }
            }
        default: cameraUnavailable("Enable camera access in iPhone Settings to scan a pairing code.")
        }
    }

    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection {
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let angle: CGFloat
            switch orientation {
            case .landscapeLeft: angle = 0
            case .landscapeRight: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    func stop() {
        visible = false
        captureQueue.async { [captureSession] in if captureSession.isRunning { captureSession.stopRunning() } }
    }

    private func configureAndStart() {
        guard !delivered else { return }
        if !configured {
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                  captureSession.canAddInput(input) else { cameraUnavailable("This device's camera is unavailable."); return }
            captureSession.beginConfiguration()
            captureSession.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                cameraUnavailable("This device cannot scan QR codes.")
                return
            }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                captureSession.commitConfiguration()
                cameraUnavailable("This device cannot scan QR codes.")
                return
            }
            output.metadataObjectTypes = [.qr]
            captureSession.commitConfiguration()
            let layer = AVCaptureVideoPreviewLayer(session: captureSession)
            layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, at: 0)
            preview = layer
            configured = true
            view.setNeedsLayout()
        }
        captureQueue.async { [captureSession] in if !captureSession.isRunning { captureSession.startRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr, let payload = code.stringValue else { continue }
            do {
                _ = try CompanionPairingPayload.parse(payload)
                delivered = true
                stop()
                onPayload(payload)
                return
            } catch {
                if lastInvalidPayload != payload {
                    lastInvalidPayload = payload
                    let message = (error as? LocalizedError)?.errorDescription ?? "This is not a valid Harness pairing code."
                    status.text = message
                    onError(message)
                }
            }
        }
    }

    private func cameraUnavailable(_ message: String) { status.text = message; onError(message) }
}
