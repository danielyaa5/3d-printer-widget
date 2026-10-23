import Foundation

public enum PrinterCommand: String, CaseIterable, Sendable {
    case pause, resume, stop
    public var title: String {
        switch self { case .pause: return "Pause"; case .resume: return "Resume"; case .stop: return "Stop print" }
    }
    public var symbol: String {
        switch self { case .pause: return "pause.fill"; case .resume: return "play.fill"; case .stop: return "stop.fill" }
    }
    public func allows(_ state: PrintState) -> Bool {
        switch self {
        case .pause: return state == .printing
        case .resume: return state == .paused
        case .stop: return [.preparing, .printing, .paused].contains(state)
        }
    }
}

public enum PrinterControlError: LocalizedError, Equatable {
    case unsupported, refreshRequired, jobChanged, busy, unconfirmed, rejected, pairingRequired
    case bambuRejected(reason: String?)
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This connection supports monitoring only. Use the printer’s own controls."
        case .refreshRequired: return "Refresh this printer before using print controls."
        case .jobChanged: return "The print or its state changed. Check the latest reading before trying again."
        case .busy: return "A command is already in progress for this printer."
        case .unconfirmed: return "The command wasn’t confirmed. Check the printer before trying again; it may already have received it."
        case .rejected: return "The printer refused the command. Check its screen and control permissions. Bambu firmware may require LAN Only and Developer Mode; OctoPrint keys need Print permission."
        case .bambuRejected(let reason):
            if reason?.lowercased().contains("mqtt message verify failed") == true {
                return """
                Bambu rejected this command’s authorization. Pause, Resume, and Stop cannot work through this app’s current direct connection.

                To keep Bambu cloud and Handy camera access, use Bambu Handy or Bambu Studio for print controls. This is the recommended option.

                For direct third-party controls, Bambu requires LAN Only plus Developer Mode. LAN Only disables Bambu cloud features, including Handy access.

                The camera bridge supplies video only. It does not authorize printer commands. Controlling this printer from this app while keeping cloud access would need a supported authorized integration, which is not included.

                Printer response: mqtt message verify failed
                """
            }
            return "Bambu rejected this command. " + (reason.map { "Printer response: \($0). " } ?? "")
                + "Check the printer’s screen, or use Bambu Handy or Bambu Studio."
        case .pairingRequired: return "Reconnect and save this Bambu printer before using controls, so its certificate is trusted."
        }
    }
}

public enum PrinterControl {
    public static func supports(_ kind: PrinterKind) -> Bool {
        [.moonraker, .bambu, .octoPrint, .prusaLink, .creality, .sdcp].contains(kind)
    }

    public static func validate(_ command: PrinterCommand, snapshot: PrinterSnapshot, now: Date = Date()) throws {
        guard supports(snapshot.kind) else { throw PrinterControlError.unsupported }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard !snapshot.isOffline, snapshot.refreshUnavailable != true, age >= -5, age <= 60 else {
            throw PrinterControlError.refreshRequired
        }
        guard snapshot.controlsUnavailable != true, command.allows(snapshot.state),
              snapshot.jobIdentifier?.isEmpty == false || snapshot.jobName?.isEmpty == false else {
            throw PrinterControlError.jobChanged
        }
    }

    public static func validateSameJob(_ command: PrinterCommand, expected: PrinterSnapshot,
                                       current: PrinterSnapshot, now: Date = Date()) throws {
        try validate(command, snapshot: current, now: now)
        guard current.id == expected.id, current.kind == expected.kind,
              current.jobName == expected.jobName,
              current.jobIdentifier == expected.jobIdentifier,
              current.controlJobID == expected.controlJobID else { throw PrinterControlError.jobChanged }
        // Firmware without unique job IDs still supplies progress/elapsed time.
        // Reject a restarted file rather than acting on the next run of it.
        if let before = expected.progress, let after = current.progress, after + 0.001 < before {
            throw PrinterControlError.jobChanged
        }
        if let before = expected.elapsedSeconds, let after = current.elapsedSeconds, after + 2 < before {
            throw PrinterControlError.jobChanged
        }
    }

    /// One explicit action, never retried. Polling continues through fetch().
    public static func perform(_ command: PrinterCommand, profile: PrinterProfile,
                               expected: PrinterSnapshot, timeout: TimeInterval = 10) async throws {
        let profile = try profile.validated()
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw PrinterError.configuration("Invalid control timeout.") }
        guard profile.id == expected.id, profile.kind == expected.kind else { throw PrinterControlError.jobChanged }
        try validate(command, snapshot: expected)
        try Task.checkCancellation()
        if profile.kind == .bambu {
            guard profile.certificateFingerprint != nil else { throw PrinterControlError.pairingRequired }
            _ = try await BambuRequest(profile: profile, timeout: timeout, command: command, expected: expected).run()
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        let current = try await PrinterClient.fetch(profile, timeout: timeout)
        try validateSameJob(command, expected: expected, current: current)
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw PrinterError.timeout }
        if profile.kind.usesWebSocket {
            try await WebSocketPrinterClient.control(command, profile: profile, expected: current, timeout: remaining)
            return
        }
        try await sendHTTP(command, profile: profile, snapshot: current, timeout: remaining)
    }

    static func sendHTTP(_ command: PrinterCommand, profile: PrinterProfile, snapshot: PrinterSnapshot,
                         timeout: TimeInterval, configuration: URLSessionConfiguration = .ephemeral) async throws {
        let reader = PrinterHTTPReader(profile: profile, timeout: timeout, configuration: configuration)
        defer { reader.close() }
        let path: String, method: String, body: Data?
        switch profile.kind {
        case .moonraker:
            path = "printer/print/" + (command == .stop ? "cancel" : command.rawValue)
            method = "POST"; body = nil
        case .prusaLink where snapshot.controlJobID != nil:
            guard let id = snapshot.controlJobID, id >= 0 else { throw PrinterError.invalidResponse }
            path = "api/v1/job/\(id)" + (command == .stop ? "" : "/" + command.rawValue)
            method = command == .stop ? "DELETE" : "PUT"; body = nil
        case .octoPrint, .prusaLink:
            path = "api/job"; method = "POST"
            let payload = command == .stop ? ["command": "cancel"] : ["command": "pause", "action": command.rawValue]
            body = try JSONSerialization.data(withJSONObject: payload)
        default: throw PrinterControlError.unsupported
        }
        do {
            let response = try await reader.request(path, method: method, body: body, accepting: [200, 202, 204])
            if profile.kind == .moonraker {
                let result = try TelemetryValue.json(response)
                if result["error"] != nil { throw PrinterControlError.rejected }
                guard result["result"] as? String == "ok" else { throw PrinterControlError.unconfirmed }
            }
        } catch PrinterError.authentication { throw PrinterControlError.rejected }
        catch PrinterError.http(let code) where [400, 404, 405, 409, 423].contains(code) { throw PrinterControlError.rejected }
        catch let error as PrinterControlError { throw error }
        catch PrinterError.http(let code) where [301, 302, 303, 307, 308].contains(code) { throw PrinterError.http(code) }
        // A timeout, broken response, or server error can happen after a
        // mutation was applied. Never turn uncertainty into an automatic retry.
        catch { throw PrinterControlError.unconfirmed }
    }
}
