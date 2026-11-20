import Foundation
import MultipeerConnectivity
import AVFoundation

// Nearby AiboID transport for the iOS test app.
// Local Wi-Fi / peer-to-peer Wi-Fi only. No internet relay, phone-number routing,
// remote identity verification, or guaranteed delivery while offline.
final class AiboNearby: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    private let service = "aibo-peer"
    private(set) var myID = ""
    private var myName = "Aibo User"
    private var myPhoto = ""
    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discovered: [String: MCPeerID] = [:]
    private var connecting = Set<String>()
    private var pending: [[String: Any]] = []
    private let networkQueue = DispatchQueue(label: "dev.aiboos.voice.transport", qos: .userInitiated)
    private var activeCall: String?
    private var callAudio: AiboCallAudio?
    var event: ((String, [String: Any]) -> Void)?

    func configure(id: String, name: String, photo: String) {
        guard id.range(of: "^\\d{7}$", options: .regularExpression) != nil else { return }
        myName = String(name.prefix(48)).isEmpty ? "Aibo User" : String(name.prefix(48))
        myPhoto = String(photo.prefix(25000))
        if myID == id && session != nil { announce(); return }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        myID = id
        discovered.removeAll()
        connecting.removeAll()
        let me = MCPeerID(displayName: "aibo-" + id)
        peerID = me
        let newSession = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session = newSession
        newSession.delegate = self
        let ad = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["id": id], serviceType: service)
        let br = MCNearbyServiceBrowser(peer: me, serviceType: service)
        advertiser = ad; browser = br
        ad.delegate = self; br.delegate = self
        ad.startAdvertisingPeer()
        br.startBrowsingForPeers()
        emitPeers()
    }

    private func emit(_ type: String, _ fields: [String: Any] = [:]) {
        event?(type, fields)
    }
    private func onlineIDs() -> Set<String> {
        Set((session?.connectedPeers ?? []).compactMap { peer in
            let label = peer.displayName
            return label.hasPrefix("aibo-") ? String(label.dropFirst(5)) : nil
        })
    }
    private func emitPeers() {
        let online = onlineIDs()
        let peers = discovered.keys.sorted().map { ["id": $0, "connected": online.contains($0)] as [String: Any] }
        emit("peerList", ["peers": peers])
    }
    private func connectedPeer(_ id: String) -> MCPeerID? {
        session?.connectedPeers.first(where: { $0.displayName == "aibo-" + id })
    }
    private func connect(to id: String) {
        guard let peer = discovered[id], connectedPeer(id) == nil,
              !connecting.contains(id), let browser = browser, let session = session else { return }
        connecting.insert(id)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }
    private func send(_ packet: [String: Any], to id: String, reliable: Bool = true) -> Bool {
        guard let peer = connectedPeer(id), let session = session,
              JSONSerialization.isValidJSONObject(packet),
              let data = try? JSONSerialization.data(withJSONObject: packet) else { return false }
        do {
            try session.send(data, toPeers: [peer], with: reliable ? .reliable : .unreliable)
            return true
        } catch { return false }
    }
    private func sendProfile(to id: String) {
        var packet: [String: Any] = ["type": "profile", "from": myID, "to": id, "name": myName]
        if !myPhoto.isEmpty { packet["photo"] = myPhoto }
        _ = send(packet, to: id)
    }
    private func announce() {
        for peer in onlineIDs() { sendProfile(to: peer) }
    }
    private func flush(for id: String) {
        var remaining: [[String: Any]] = []
        for packet in pending {
            if packet["to"] as? String == id {
                if !send(packet, to: id) { remaining.append(packet) }
            } else { remaining.append(packet) }
        }
        pending = remaining
    }
    func message(to id: String, text: String, messageID: String) {
        guard id.range(of: "^\\d{7}$", options: .regularExpression) != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let packet: [String: Any] = ["type": "message", "id": String(messageID.prefix(64)),
             "from": myID, "to": id, "name": myName,
             "text": String(text.prefix(4000)), "ts": Date().timeIntervalSince1970 * 1000]
        if send(packet, to: id) { return }
        if pending.count < 100 { pending.append(packet) }
        connect(to: id)
        emit("messageStatus", ["id": messageID, "status": "waiting"])
    }
    func call(to id: String) {
        guard id.range(of: "^\\d{7}$", options: .regularExpression) != nil else { return }
        guard activeCall == nil else { emit("callState", ["state": "busy", "to": id]); return }
        activeCall = id
        let packet: [String: Any] = ["type": "call", "from": myID, "to": id, "name": myName]
        if !send(packet, to: id) {
            pending.append(packet)
            connect(to: id)
            emit("callState", ["state": "connecting", "to": id])
        } else {
            emit("callState", ["state": "ringing", "to": id])
        }
    }
    func acceptCall(from id: String) {
        activeCall = id
        _ = send(["type": "accept", "from": myID, "to": id], to: id)
        startAudio(with: id)
    }
    func declineCall(from id: String) {
        _ = send(["type": "decline", "from": myID, "to": id], to: id)
        if activeCall == id { endAudio(); activeCall = nil }
    }
    func hangup() {
        guard let id = activeCall else { return }
        _ = send(["type": "hangup", "from": myID, "to": id], to: id)
        endAudio(); activeCall = nil
        emit("callState", ["state": "ended", "to": id])
    }
    private func startAudio(with id: String) {
        endAudio()
        let audio = AiboCallAudio()
        audio.onAudio = { [weak self] data in
            self?.networkQueue.async {
                guard let self = self, self.activeCall == id else { return }
                _ = self.send(["type": "audio", "from": self.myID, "to": id,
                                "payload": data.base64EncodedString()], to: id, reliable: false)
            }
        }
        do {
            try audio.start()
            callAudio = audio
            emit("callState", ["state": "active", "to": id])
        } catch {
            emit("callState", ["state": "error", "to": id, "reason": "Microphone or audio playback unavailable"])
            _ = send(["type": "hangup", "from": myID, "to": id], to: id)
            activeCall = nil
        }
    }
    private func endAudio() {
        callAudio?.stop()
        callAudio = nil
    }
    func stopAll() {
        hangup()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        emitPeers()
    }

    // MARK: Browsing, connections, receive
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            let id = info?["id"] ?? String(peerID.displayName.dropFirst(5))
            guard id.range(of: "^\\d{7}$", options: .regularExpression) != nil,
                  id != self.myID else { return }
            self.discovered[id] = peerID
            self.emitPeers()
            if self.pending.contains(where: { ($0["to"] as? String) == id }) { self.connect(to: id) }
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            let id = String(peerID.displayName.dropFirst(5))
            self.discovered.removeValue(forKey: id)
            self.connecting.remove(id)
            self.emitPeers()
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.emit("peerError", ["message": "Nearby discovery unavailable"]) }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Anyone using the AiboOS nearby service may invite; users still choose who to message.
        invitationHandler(true, session)
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.emit("peerError", ["message": "Nearby advertising unavailable"]) }
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            let id = String(peerID.displayName.dropFirst(5))
            self.connecting.remove(id)
            if state == .connected {
                self.sendProfile(to: id)
                self.flush(for: id)
            }
            if state == .notConnected && self.activeCall == id {
                self.endAudio(); self.activeCall = nil
                self.emit("callState", ["state": "ended", "to": id])
            }
            self.emitPeers()
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = packet["type"] as? String,
              let sender = packet["from"] as? String,
              sender == String(peerID.displayName.dropFirst(5)),
              let destination = packet["to"] as? String,
              destination == myID else { return }
        DispatchQueue.main.async {
            switch type {
            case "profile":
                self.emit("peerProfile", ["id": sender,
                      "name": String((packet["name"] as? String ?? "").prefix(48)),
                      "photo": String((packet["photo"] as? String ?? "").prefix(25000))])
            case "message":
                guard let messageID = packet["id"] as? String,
                      let text = packet["text"] as? String, text.count <= 4000 else { return }
                self.emit("peerMessage", ["from": sender, "to": self.myID, "id": messageID,
                      "name": String((packet["name"] as? String ?? "").prefix(48)),
                      "text": text, "ts": packet["ts"] as? Double ?? Date().timeIntervalSince1970 * 1000])
                _ = self.send(["type": "ack", "from": self.myID, "to": sender, "id": messageID], to: sender)
            case "ack":
                if let id = packet["id"] as? String {
                    self.emit("messageStatus", ["id": id, "status": "delivered"])
                }
            case "call":
                self.emit("callIncoming", ["from": sender, "name": String((packet["name"] as? String ?? "").prefix(48))])
            case "accept":
                if self.activeCall == sender { self.startAudio(with: sender) }
            case "decline":
                if self.activeCall == sender {
                    self.endAudio(); self.activeCall = nil
                    self.emit("callState", ["state": "declined", "to": sender])
                }
            case "hangup":
                if self.activeCall == sender {
                    self.endAudio(); self.activeCall = nil
                    self.emit("callState", ["state": "ended", "to": sender])
                }
            case "audio":
                if self.activeCall == sender, let b64 = packet["payload"] as? String,
                   let audio = Data(base64Encoded: b64) { self.callAudio?.play(audio) }
            default: break
            }
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// Experimental near-field peer audio. 16 kHz mono PCM; not a phone-network call.
// Sound transmission works only while both apps remain open and connected.
final class AiboCallAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var outputFormat: AVAudioFormat?
    private var tapInstalled = false
    var onAudio: ((Data) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                         sampleRate: 16000, channels: 1, interleaved: false) else { return }
        outputFormat = output
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        let microphone = engine.inputNode
        let inputFormat = microphone.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let encoded = AVAudioFormat(commonFormat: .pcmFormatInt16,
                    sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: encoded) else {
            throw NSError(domain: "AiboCall", code: 2)
        }
        microphone.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] input, _ in
            let frames = AVAudioFrameCount(Double(input.frameLength) * 16000 / inputFormat.sampleRate + 256)
            guard let dst = AVAudioPCMBuffer(pcmFormat: encoded, frameCapacity: frames) else { return }
            var consumed = false
            var error: NSError?
            _ = converter.convert(to: dst, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, dst.frameLength > 0, let data = dst.int16ChannelData?[0] else { return }
            self?.onAudio?(Data(bytes: data, count: Int(dst.frameLength) * MemoryLayout<Int16>.size))
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
    }
    func play(_ data: Data) {
        guard let format = outputFormat, data.count > 1,
              let frame = AVAudioPCMBuffer(pcmFormat: format,
                         frameCapacity: AVAudioFrameCount(data.count / 2)),
              let floats = frame.floatChannelData?[0] else { return }
        frame.frameLength = frame.frameCapacity
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<min(samples.count, Int(frame.frameLength)) {
                floats[i] = Float(samples[i]) / 32768.0
            }
        }
        player.scheduleBuffer(frame, completionHandler: nil)
    }
    func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
