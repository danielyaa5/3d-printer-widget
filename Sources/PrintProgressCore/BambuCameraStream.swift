import Foundation
import Network
import Security
import CryptoKit
import CoreGraphics

/// Read-only local RTSPS video. No printer commands, cloud relay or recordings.
public final class BambuCameraStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PrintProgress.Camera.RTSPS")
    private let profile: PrinterProfile
    private let source: PrinterCameraSource
    private let onError: @Sendable (Error) -> Void
    private let onCertificate: @Sendable (String) async throws -> Void
    private var connection: NWConnection?
    private var decoder: CameraH264Decoder
    private var buffer = Data()
    private var rtp = CameraH264RTP()
    private var deadline: DispatchWorkItem?
    private var keepalive: DispatchWorkItem?
    private var stopped = false
    private var challenge: String?
    private var authRetries = 0
    private var sequence = 0
    private var pending: (method: String, uri: String, headers: [String: String])?
    private var sessionID: String?
    private var trackURL = ""
    private var videoChannel: UInt8 = 0
    private var verificationError: Error?
    private var pairingTask: Task<Void, Never>?

    public init(profile: PrinterProfile, source: PrinterCameraSource,
                onCertificate: @escaping @Sendable (String) async throws -> Void,
                onFrame: @escaping @Sendable (CGImage) -> Void, onError: @escaping @Sendable (Error) -> Void) {
        self.profile = profile; self.source = source; self.onCertificate = onCertificate
        self.onError = onError; decoder = CameraH264Decoder(onFrame: onFrame)
    }
    public func start() { queue.async { self.connect() } }
    public func stop() { queue.async { self.close() } }
    private func connect() {
        guard !stopped, connection == nil else { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            guard let self, !self.stopped else { complete(false); return }
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
                complete(false); return
            }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            if let pin = self.profile.camera?.certificateFingerprint, pin.lowercased() != fingerprint {
                self.verificationError = PrinterCameraError.certificateChanged; complete(false); return
            }
            // Persist the first-use pin before sending any credentials. Failure
            // to save in Keychain fails the connection, with no plaintext fallback.
            self.pairingTask = Task {
                do {
                    try await self.onCertificate(fingerprint)
                    self.queue.async { complete(!self.stopped) }
                } catch {
                    self.queue.async { self.verificationError = error; complete(false) }
                }
            }
        }, queue)
        let connection = NWConnection(host: .init(source.url.host ?? profile.address), port: .init(rawValue: UInt16(source.url.port ?? 322))!,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.request("DESCRIBE", uri: self.source.url.absoluteString, headers: ["Accept": "application/sdp"])
                self.receive()
            case .failed, .waiting: self.fail(self.verificationError ?? PrinterCameraError.timeout)
            case .cancelled: self.fail(PrinterCameraError.disconnected)
            default: break
            }
        }
        armDeadline()
        connection.start(queue: queue)
    }
    private func request(_ method: String, uri: String, headers: [String: String] = [:]) {
        guard !stopped else { return }
        sequence += 1
        pending = (method, uri, headers)
        var fields = headers
        fields["CSeq"] = String(sequence)
        fields["User-Agent"] = "PrintProgress"
        if let sessionID { fields["Session"] = sessionID }
        if let challenge {
            do { fields["Authorization"] = try CameraRTSPCodec.authorization(challenge: challenge, method: method, uri: uri, password: profile.credential) }
            catch { fail(error); return }
        }
        let text = "\(method) \(uri) RTSP/1.0\r\n" + fields.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail(PrinterCameraError.disconnected) }
        })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            do {
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 2 * 1024 * 1024 else { throw PrinterCameraError.invalidStream }
                while let message = try CameraRTSPCodec.next(&self.buffer) {
                    switch message {
                    case .packet(let channel, let packet):
                        if channel == self.videoChannel, let nals = try self.rtp.append(packet) {
                            try self.decoder.decode(nals); self.armDeadline()
                        }
                    case .response(let code, let headers, let body): try self.response(code, headers: headers, body: body)
                    }
                }
                if error != nil || complete { self.fail(self.verificationError ?? PrinterCameraError.disconnected) }
                else { self.receive() }
            } catch { self.fail(error) }
        }
    }
    private func response(_ code: Int, headers: [String: String], body: Data) throws {
        guard let pending, headers["cseq"] == String(sequence) else { throw PrinterCameraError.invalidStream }
        if code == 401, let challenge = headers["www-authenticate"], authRetries < 2 {
            self.challenge = challenge; authRetries += 1
            request(pending.method, uri: pending.uri, headers: pending.headers); return
        }
        guard code == 200 else { throw [401, 403].contains(code) ? PrinterCameraError.authentication : PrinterCameraError.disconnected }
        authRetries = 0; self.pending = nil
        switch pending.method {
        case "DESCRIBE":
            guard let sdp = String(data: body, encoding: .utf8) else { throw PrinterCameraError.invalidStream }
            let lines = sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var inVideo = false, videoLines: [String] = []
            for line in lines {
                if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video ") }
                if inVideo { videoLines.append(line) }
            }
            guard let mapping = videoLines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.uppercased().contains("H264/90000") }),
                  let payload = mapping.dropFirst("a=rtpmap:".count).split(separator: " ").first,
                  videoLines.first?.split(separator: " ").dropFirst(3).contains(payload) == true,
                  let control = videoLines.first(where: { $0.hasPrefix("a=control:") })?.dropFirst("a=control:".count) else { throw PrinterCameraError.unsupported }
            for line in videoLines where line.hasPrefix("a=fmtp:\(payload) ") {
                for field in line.components(separatedBy: ";") {
                    let field = field.trimmingCharacters(in: .whitespaces)
                    if let range = field.range(of: "sprop-parameter-sets=") {
                        try decoder.parameterSets(field[range.upperBound...].split(separator: ",").compactMap { Data(base64Encoded: String($0)) })
                    }
                }
            }
            let base = headers["content-base"] ?? source.url.absoluteString + "/"
            guard let baseURL = URL(string: base), let track = URL(string: String(control), relativeTo: baseURL)?.absoluteURL,
                  track.host == source.url.host, track.port == source.url.port,
                  ["rtsp", "rtsps"].contains(track.scheme ?? ""), track.user == nil, track.password == nil else { throw PrinterCameraError.invalidStream }
            trackURL = track.absoluteString
            request("SETUP", uri: trackURL, headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
        case "SETUP":
            guard let session = headers["session"]?.split(separator: ";").first, !session.isEmpty,
                  let transport = headers["transport"], transport.uppercased().contains("RTP/AVP/TCP") else { throw PrinterCameraError.unsupported }
            sessionID = String(session)
            if let part = transport.components(separatedBy: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interleaved=") }),
               let value = part.components(separatedBy: "=").last?.split(separator: "-").first, let channel = UInt8(value) { videoChannel = channel }
            request("PLAY", uri: source.url.absoluteString)
        case "PLAY": scheduleKeepalive()
        default: break
        }
    }
    private func scheduleKeepalive() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            if self.pending == nil { self.request("OPTIONS", uri: self.source.url.absoluteString) }
            self.scheduleKeepalive()
        }
        keepalive = item; queue.asyncAfter(deadline: .now() + 20, execute: item)
    }
    private func armDeadline() {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail(PrinterCameraError.timeout) }
        deadline = item; queue.asyncAfter(deadline: .now() + 15, execute: item)
    }
    private func fail(_ error: Error) { guard !stopped else { return }; close(); onError(error) }
    private func close() {
        guard !stopped else { return }
        stopped = true; deadline?.cancel(); keepalive?.cancel(); pairingTask?.cancel()
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        decoder.reset(); buffer = Data()
    }
}
