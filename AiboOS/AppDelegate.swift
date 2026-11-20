import UIKit
import WebKit
import AVFoundation
import Speech
import LocalAuthentication

// iOS-hosted AiboOS beta. Native hardware features here use iOS APIs.
// This wrapper is not a replacement OS or a bootloader.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate, WKNavigationDelegate,
                         WKUIDelegate, WKScriptMessageHandler, UIImagePickerControllerDelegate,
                         UINavigationControllerDelegate {
    var window: UIWindow?
    private var webView: WKWebView?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasAudioTap = false
    private let speech = AVSpeechSynthesizer()
    private var currentVoiceID: String?
    private var torchEnabled = false
    private var lastRecognitionText = ""
    private lazy var nearby: AiboNearby = {
        let p = AiboNearby()
        p.event = { [weak self] type, fields in self?.emit(type, fields) }
        return p
    }()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(self, name: "aiboNative")
        let web = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        vc.view.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            web.topAnchor.constraint(equalTo: vc.view.topAnchor),
            web.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
        ])
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        webView = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let label = UILabel(frame: vc.view.bounds)
            label.text = "AiboOS assets missing"
            label.textColor = .white
            label.textAlignment = .center
            vc.view.addSubview(label)
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged),
                 name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged),
                 name: UIDevice.batteryStateDidChangeNotification, object: nil)
        checkForUpdatesSilently()
        return true
    }

    private func emit(_ type: String, _ fields: [String: Any] = [:]) {
        var payload = fields
        payload["type"] = type
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('aibo-native', {detail: \(json)}))", completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "aiboNative", let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "torch":
            setTorch(body["on"] as? Bool ?? false)
        case "camera":
            showCamera()
        case "voiceStart":
            startVoice()
        case "voiceStop":
            stopVoice()
        case "speak":
            let text = (body["text"] as? String ?? "").prefix(1200)
            if !text.isEmpty {
                speech.stopSpeaking(at: .immediate)
                let utterance = AVSpeechUtterance(string: String(text))
                utterance.rate = 0.51
                utterance.pitchMultiplier = 1.07
                utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-GB")
                speech.speak(utterance)
            }
        case "stopSpeaking":
            speech.stopSpeaking(at: .immediate)
        case "touchAuth":
            checkTouchID()
        case "updateCheck":
            checkForUpdatesSilently()
        case "batteryRequest":
            batteryChanged()
        case "peerIdentity":
            nearby.configure(id: body["id"] as? String ?? "",
                name: body["name"] as? String ?? "Aibo User",
                photo: body["photo"] as? String ?? "")
        case "peerSend":
            nearby.message(to: body["to"] as? String ?? "",
                text: body["text"] as? String ?? "",
                messageID: body["id"] as? String ?? "")
        case "peerCall":
            nearby.call(to: body["to"] as? String ?? "")
        case "peerAccept":
            nearby.acceptCall(from: body["from"] as? String ?? "")
        case "peerDecline":
            nearby.declineCall(from: body["from"] as? String ?? "")
        case "peerHangup":
            nearby.hangup()
        case "faceStatus":
            emit("faceStatus", ["enrolled": AiboFaceCheckController.enrolled(),
                  "enabled": UserDefaults.standard.bool(forKey: "aiboFaceEnabled")])
        case "faceEnroll":
            showFaceCheck(enroll: true)
        case "faceVerify":
            if UserDefaults.standard.bool(forKey: "aiboFaceEnabled") && AiboFaceCheckController.enrolled() {
                showFaceCheck(enroll: false)
            } else {
                emit("faceCheckResult", ["ok": false, "mode": "verify", "message": "Face Check not enrolled"])
            }
        case "faceDisable":
            AiboFaceCheckController.erase()
            emit("faceStatus", ["enrolled": false, "enabled": false])
        default:
            break
        }
    }

    @objc private func batteryChanged() {
        let d = UIDevice.current
        let level = d.batteryLevel
        let hasLevel = level >= 0 && level <= 1
        emit("batteryStatus", ["level": hasLevel ? Double(level) : -1,
             "charging": d.batteryState == .charging || d.batteryState == .full,
             "state": d.batteryState == .full ? "full" : d.batteryState == .charging ? "charging" : "unplugged"])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        batteryChanged()
    }

    private func showFaceCheck(enroll: Bool) {
        guard let parent = window?.rootViewController, parent.presentedViewController == nil else {
            emit("faceCheckResult", ["ok": false, "mode": enroll ? "enroll" : "verify", "message": "Camera is busy"])
            return
        }
        let check = AiboFaceCheckController()
        check.purpose = enroll ? .enroll : .verify
        check.modalPresentationStyle = .fullScreen
        check.completion = { [weak self] ok, message in
            self?.emit("faceCheckResult", ["ok": ok, "mode": enroll ? "enroll" : "verify", "message": message])
            if enroll { self?.emit("faceStatus", ["enrolled": AiboFaceCheckController.enrolled(),
                "enabled": UserDefaults.standard.bool(forKey: "aiboFaceEnabled")]) }
        }
        parent.present(check, animated: true)
    }

    private func setTorch(_ enabled: Bool) {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              camera.hasTorch else {
            torchEnabled = false
            emit("torch", ["on": false, "error": "Rear LED flashlight unavailable"])
            return
        }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if enabled {
                try camera.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 0.85))
            } else {
                camera.torchMode = .off
            }
            torchEnabled = enabled
            emit("torch", ["on": enabled])
        } catch {
            torchEnabled = false
            emit("torch", ["on": false, "error": "Flashlight could not be switched on"])
        }
    }

    private func showCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              let vc = window?.rootViewController else {
            emit("camera", ["error": "Camera unavailable on this device"])
            return
        }
        guard vc.presentedViewController == nil else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        vc.present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        if let image = info[.originalImage] as? UIImage {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            emit("camera", ["saved": true])
        }
        picker.dismiss(animated: true)
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    private func checkTouchID() {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              ctx.biometryType == .touchID else {
            emit("touchResult", ["ok": false, "error": "Touch ID isn't available or enrolled. Enter your AiboOS passcode."])
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Authenticate with your iPhone SE Touch ID sensor") { [weak self] ok, _ in
            self?.emit("touchResult", ["ok": ok])
        }
    }

    private func startVoice() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-GB")),
              recognizer.isAvailable else {
            emit("voiceError", ["message": "Speech recognition is currently unavailable"])
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                self?.emit("voiceError", ["message": "Allow Speech Recognition in iPhone Settings"])
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                guard allowed else {
                    self?.emit("voiceError", ["message": "Allow Microphone access in iPhone Settings"])
                    return
                }
                DispatchQueue.main.async {
                    self?.beginListening(recognizer)
                }
            }
        }
    }

    private func beginListening(_ recognizer: SFSpeechRecognizer) {
        stopVoice(silent: true)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request
            lastRecognitionText = ""
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw NSError(domain: "AiboOS", code: 1) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasAudioTap = true
            audioEngine.prepare()
            try audioEngine.start()
            emit("voiceReady")
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self?.lastRecognitionText = text
                    self?.emit("voiceText", ["text": text, "final": result.isFinal])
                    if result.isFinal { self?.stopVoice() }
                }
                if error != nil { self?.stopVoice(silent: true) }
            }
        } catch {
            stopVoice(silent: true)
            emit("voiceError", ["message": "Microphone couldn't start"])
        }
    }

    private func stopVoice(silent: Bool = false) {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if !silent { emit("voiceStopped", ["text": lastRecognitionText]) }
    }

    // Checks release metadata only; never flashes, installs, or shows a prompt.
    private func checkForUpdatesSilently() {
        guard let url = URL(string: "https://api.github.com/repos/wwoolf21963-dotcom/AiboOS/releases/tags/aiboos-se-latest") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("AiboOS-iPhone-SE", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let ipa = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true }),
                  let updated = ipa["updated_at"] as? String else { return }
            UserDefaults.standard.set(updated, forKey: "aiboLatestReleaseDate")
            UserDefaults.standard.set(ipa["browser_download_url"] as? String, forKey: "aiboLatestReleaseURL")
            // No visible UI, no automatic install. TrollStore must handle IPA updates.
        }.resume()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        nearby.hangup()
        stopVoice(silent: true)
        if torchEnabled { setTorch(false) }
    }
    func applicationWillEnterForeground(_ application: UIApplication) {
        checkForUpdatesSilently()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        switch (url.scheme ?? "").lowercased() {
        case "file", "about", "blob", "data":
            decisionHandler(.allow)
        case "sileo":
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:])
        case "http", "https":
            if action.targetFrame?.isMainFrame == true {
                decisionHandler(.cancel)
                UIApplication.shared.open(url, options: [:])
            } else {
                decisionHandler(.allow)
            }
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let vc = window?.rootViewController else { completionHandler(); return }
        let alert = UIAlertController(title: "AiboOS", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        vc.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let vc = window?.rootViewController else { completionHandler(false); return }
        let alert = UIAlertController(title: "AiboOS", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        vc.present(alert, animated: true)
    }
}
