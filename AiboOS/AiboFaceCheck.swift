import UIKit
import AVFoundation
import Vision
import Security
import ImageIO

// Optional 2D face-geometry convenience check for the iPhone SE's ordinary
// front-facing camera. NOT Apple Face ID, not depth-based, not spoof resistant.
// Never use this for payments or to replace Touch ID / the device passcode.
final class AiboFaceCheckController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Purpose { case enroll, verify }
    var purpose: Purpose = .verify
    var completion: ((Bool, String) -> Void)?
    private let camera = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let status = UILabel()
    private var finished = false
    private var processing = false
    private var frameNumber = 0
    private var successes = 0
    private var samples: [[Double]] = []
    private let captureQueue = DispatchQueue(label: "dev.aiboos.face.camera", qos: .userInitiated)
    private var reference: [Double]?

    private static let service = "dev.aiboos.facecheck.v1"
    static func enrolled() -> Bool { load() != nil }
    static func erase() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
           kSecAttrService as String: service,
           kSecAttrAccount as String: "face-geometry"]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: "aiboFaceEnabled")
    }
    private static func load() -> [Double]? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "face-geometry"]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([Double].self, from: data)
    }
    private static func save(_ vector: [Double]) -> Bool {
        guard let data = try? JSONEncoder().encode(vector) else { return false }
        erase()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "face-geometry",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        reference = Self.load()
        let heading = UILabel()
        heading.text = purpose == .enroll ? "Set up Aibo Face Check" : "Use Face Check"
        heading.textColor = UIColor.white
        heading.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        heading.textAlignment = .center
        heading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heading)
        status.text = "Point your front camera at your face"
        status.textColor = UIColor.white
        status.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        status.numberOfLines = 3
        status.textAlignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        let warning = UILabel()
        warning.text = "Experimental 2D camera match. Less secure than Touch ID; another person or a photograph may fool it. No photos are saved."
        warning.textColor = UIColor(white: 0.76, alpha: 1)
        warning.font = UIFont.systemFont(ofSize: 12)
        warning.numberOfLines = 5
        warning.textAlignment = .center
        warning.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(warning)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(UIColor.systemPink, for: .normal)
        cancel.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 145),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            warning.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            warning.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            warning.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -22),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted { self?.setupCamera() }
                else { self?.finish(false, "Camera permission is required for optional Face Check") }
            }
        }
    }
    private func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            finish(false, "This iPhone has no usable front camera")
            return
        }
        camera.beginConfiguration()
        camera.sessionPreset = .medium
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard camera.canAddInput(input) else { finish(false, "Camera cannot start"); return }
            camera.addInput(input)
        } catch { finish(false, "Camera cannot start"); return }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        guard camera.canAddOutput(output) else { finish(false, "Camera cannot start"); return }
        output.setSampleBufferDelegate(self, queue: captureQueue)
        camera.addOutput(output)
        camera.commitConfiguration()
        let p = AVCaptureVideoPreviewLayer(session: camera)
        p.videoGravity = .resizeAspectFill
        p.cornerRadius = 23
        p.masksToBounds = true
        view.layer.insertSublayer(p, at: 0)
        preview = p
        view.setNeedsLayout()
        captureQueue.async { self.camera.startRunning() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let side = min(view.bounds.width - 35, 340)
        preview?.frame = CGRect(x: (view.bounds.width - side) / 2,
                                y: max(90, view.bounds.height / 2 - side / 2 - 42),
                                width: side, height: side)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if finished || processing { return }
        frameNumber += 1
        if frameNumber % 8 != 0 { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processing = true
        defer { processing = false }
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .leftMirrored).perform([request])
            guard let faces = request.results, faces.count == 1,
                  let shape = Self.features(faces[0]) else { return }
            if purpose == .enroll {
                samples.append(shape)
                if samples.count >= 7 {
                    let count = Double(samples.count)
                    let average = shape.indices.map { i in samples.reduce(0.0) { $0 + $1[i] } / count }
                    let saved = Self.save(average)
                    DispatchQueue.main.async {
                        self.finish(saved, saved ? "Face Check enrolled" : "Could not store face template")
                    }
                }
            } else if let reference = reference, reference.count == shape.count {
                let difference = zip(shape, reference).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(shape.count)
                // This is a simple, spoofable 2D landmark match, not secure biometric matching.
                if difference < 0.035 { successes += 1 } else { successes = 0 }
                if successes >= 3 {
                    DispatchQueue.main.async { self.finish(true, "Face Check matched") }
                }
            }
        } catch { }
    }
    private static func features(_ observation: VNFaceObservation) -> [Double]? {
        guard let landmarks = observation.landmarks,
              let left = landmarks.leftEye, let right = landmarks.rightEye,
              let nose = landmarks.nose, let lips = landmarks.outerLips,
              let contour = landmarks.faceContour else { return nil }
        func mean(_ points: VNFaceLandmarkRegion2D) -> [Double] {
            let ps = points.normalizedPoints
            guard !ps.isEmpty else { return [0, 0] }
            let count = Double(ps.count)
            return [ps.reduce(0.0) { $0 + Double($1.x) } / count,
                    ps.reduce(0.0) { $0 + Double($1.y) } / count]
        }
        return mean(left) + mean(right) + mean(nose) + mean(lips) + mean(contour)
    }
    @objc private func cancelPressed() { finish(false, "Face Check cancelled") }
    private func finish(_ ok: Bool, _ message: String) {
        guard !finished else { return }
        finished = true
        if camera.isRunning { captureQueue.async { self.camera.stopRunning() } }
        if purpose == .enroll && ok {
            UserDefaults.standard.set(true, forKey: "aiboFaceEnabled")
        }
        dismiss(animated: true) { [weak self] in self?.completion?(ok, message) }
    }
    override var prefersStatusBarHidden: Bool { true }
}
