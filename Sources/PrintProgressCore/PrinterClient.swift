import Foundation
import Network
import Security
import CryptoKit

public enum PrinterClient {
    public static func fetch(_ profile: PrinterProfile, timeout: TimeInterval = 10) async throws -> PrinterSnapshot {
        let profile = try profile.validated()
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw PrinterError.configuration("Use a connection timeout between 0 and 300 seconds.")
        }
        switch profile.kind {
        case .moonraker: return try await moonraker(profile, timeout: timeout)
        case .bambu: return try await BambuRequest(profile: profile, timeout: timeout).run()
        case .octoPrint, .prusaLink, .duet:
            return try await HTTPPrinterClient.fetch(profile, timeout: timeout)
        case .creality, .sdcp:
            return try await WebSocketPrinterClient.fetch(profile, timeout: timeout)
        }
    }

    private static func moonraker(_ profile: PrinterProfile, timeout: TimeInterval) async throws -> PrinterSnapshot {
        let reader = PrinterHTTPReader(profile: profile, timeout: timeout, configuration: .ephemeral)
        defer { reader.close() }
        var objects = ["print_stats", "display_status", "virtual_sdcard", "extruder", "heater_bed"]
        do {
            let discovery = try await reader.get("printer/objects/list")
            objects.append(contentsOf: try MoonrakerTelemetry.chamberObjects(from: discovery))
        } catch PrinterError.http(let code) where [404, 405].contains(code) {
            // Older hosts may not expose optional chamber discovery.
        }
        try Task.checkCancellation()
        let data = try await reader.get("printer/objects/query",
            query: objects.map { URLQueryItem(name: $0, value: nil) })
        return try MoonrakerTelemetry.parse(data, profile: profile)
    }
}

/// One bounded status request. No camera connection, control commands, or background service.
final class BambuRequest: @unchecked Sendable {
    private let profile: PrinterProfile
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "PrintProgress.BambuRequest")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<PrinterSnapshot, Error>?
    private var buffer = Data()
    private var telemetry = BambuTelemetry()
    private var deadline: DispatchWorkItem?
    private var completed = false
    private var cancelled = false
    private var fingerprint: String?
    private var verificationError: Error?
    private let command: PrinterCommand?
    private let expected: PrinterSnapshot?
    private let sequence = String(Int.random(in: 20_000...29_999))
    private var commandSent = false

    init(profile: PrinterProfile, timeout: TimeInterval, command: PrinterCommand? = nil, expected: PrinterSnapshot? = nil) {
        self.profile = profile; self.timeout = timeout; self.command = command; self.expected = expected
    }

    func run() async throws -> PrinterSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    if self.cancelled { self.finish(.failure(CancellationError())); return }
                    self.start()
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                if self.continuation != nil { self.finish(.failure(CancellationError())) }
            }
        }
    }

    private func start() {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            guard let self else { complete(false); return }
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificates = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let certificate = certificates.first else {
                self.verificationError = PrinterError.invalidResponse; complete(false); return
            }
            let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02x", $0) }.joined()
            // Bambu uses a device-local certificate. Trust it on the initial LAN pairing,
            // then require the exact certificate on every subsequent connection.
            if let pinned = self.profile.certificateFingerprint, pinned.lowercased() != hash {
                self.verificationError = PrinterError.certificateChanged; complete(false); return
            }
            self.fingerprint = hash
            complete(true)
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(profile.address), port: 8883,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.completed else { return }
            switch state {
            case .ready:
                do {
                    self.send(try MQTTCodec.connect(clientID: "progress-" + UUID().uuidString.prefix(16), password: self.profile.credential))
                    self.receive()
                } catch { self.finish(.failure(error)) }
            case .failed(let error): self.finish(.failure(self.verificationError ?? self.connectionError(error)))
            case .waiting(let error): self.finish(.failure(self.connectionError(error)))
            case .cancelled: self.finish(.failure(PrinterError.disconnected))
            default: break
            }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.failure(self.commandSent ? PrinterControlError.unconfirmed : PrinterError.timeout))
        }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        connection.start(queue: queue)
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failure(error)) }
        })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.completed else { return }
            if let data { self.buffer.append(data) }
            do {
                while let frame = try MQTTCodec.nextFrame(buffer: &self.buffer) {
                    try self.handle(frame)
                    if self.completed { return }
                }
                guard self.buffer.count <= MQTTCodec.maximumPacketSize + 5 else { throw PrinterError.invalidResponse }
            } catch { self.finish(.failure(error)); return }
            if let error { self.finish(.failure(error)) }
            else if isComplete { self.finish(.failure(PrinterError.disconnected)) }
            else { self.receive() }
        }
    }
    private func handle(_ frame: MQTTCodec.Frame) throws {
        switch frame.type {
        case 2:
            guard frame.body.count == 2 else { throw PrinterError.invalidResponse }
            guard frame.body[frame.body.startIndex + 1] == 0 else { throw PrinterError.authentication }
            send(try MQTTCodec.subscribe(serial: profile.serialNumber))
        case 9:
            guard frame.body.count >= 3, frame.body.last != 0x80 else { throw PrinterError.authentication }
            send(try MQTTCodec.requestStatus(serial: profile.serialNumber))
        case 3:
            let publication = try MQTTCodec.publication(frame)
            if let acknowledgement = publication.acknowledgement { send(acknowledgement) }
            guard publication.topic == "device/\(profile.serialNumber)/report" else { return }
            if commandSent, let command {
                let root = try TelemetryValue.json(publication.payload)
                let reply = TelemetryValue.object(root["print"])
                // Unrelated status reports and another client's acknowledgements
                // cannot make our control request appear successful.
                guard reply["command"] as? String == command.rawValue,
                      String(describing: reply["sequence_id"] ?? "") == sequence else { return }
                guard let result = (reply["result"] as? String)?.lowercased() else { return }
                if ["fail", "failed", "error"].contains(result) { throw PrinterControlError.rejected }
                guard result == "success" else { return }
                finish(.success(try telemetry.snapshot(profile: profile)))
                return
            }
            try telemetry.merge(publication.payload)
            if telemetry.hasStatus {
                var snapshot = try telemetry.snapshot(profile: profile)
                snapshot.certificateFingerprint = fingerprint
                if let command, let expected {
                    try PrinterControl.validateSameJob(command, expected: expected, current: snapshot)
                    try Task.checkCancellation()
                    commandSent = true
                    send(try MQTTCodec.printCommand(command, serial: profile.serialNumber, sequence: sequence))
                } else { finish(.success(snapshot)) }
            }
        default: break
        }
    }
    private func finish(_ result: Result<PrinterSnapshot, Error>) {
        guard !completed, let continuation else { return }
        completed = true; deadline?.cancel(); deadline = nil
        self.continuation = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        // TLS can report a socket error before the state-change callback. Preserve
        // the actionable certificate mismatch instead of exposing an SSL code.
        if case .failure(let error) = result, !(error is CancellationError), let verificationError {
            continuation.resume(throwing: verificationError)
        } else if case .failure(let error) = result, commandSent, !(error is PrinterControlError) {
            continuation.resume(throwing: PrinterControlError.unconfirmed)
        } else {
            continuation.resume(with: result)
        }
    }
    private func connectionError(_ error: NWError) -> Error {
        if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
            return PrinterError.localNetworkAccessDenied
        }
        if case .posix(let code) = error, [.ENETDOWN, .EACCES, .EPERM].contains(code) {
            return PrinterError.localNetworkUnavailable
        }
        return error
    }
}
