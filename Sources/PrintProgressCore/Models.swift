import Foundation

public struct PrinterCameraSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var streamURL = ""
    public var discoveredCameraID: String?
    public var certificateFingerprint: String?
    public var widgetSnapshotsEnabled: Bool?
    public var widgetSnapshotGeneration: UUID?
    public init() {}
}

public enum PrinterKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case moonraker, bambu, octoPrint, prusaLink, duet, creality, sdcp
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .moonraker: return "Klipper / Moonraker"
        case .bambu: return "Bambu Lab"
        case .octoPrint: return "OctoPrint"
        case .prusaLink: return "PrusaLink"
        case .duet: return "Duet / RepRapFirmware"
        case .creality: return "Creality K1 (native)"
        case .sdcp: return "Elegoo / SDCP v3"
        }
    }
    public var usesWebSocket: Bool { self == .creality || self == .sdcp }
}

/// These settings, including credentials and the certificate pin, belong in Keychain.
public struct PrinterProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PrinterKind
    public var address: String
    public var serialNumber: String
    public var credential: String
    public var certificateFingerprint: String?
    public var username: String?
    /// Optional for compatibility with profiles saved before camera support.
    public var camera: PrinterCameraSettings?

    public init(id: UUID = UUID(), name: String, kind: PrinterKind, address: String,
                serialNumber: String = "", credential: String = "", certificateFingerprint: String? = nil,
                username: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.serialNumber = serialNumber; self.credential = credential
        self.certificateFingerprint = certificateFingerprint
        self.username = username
    }

    public func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.serialNumber = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != .duet && !(kind == .prusaLink && username != nil) {
            copy.credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !copy.name.isEmpty else { throw PrinterError.configuration("Give this printer a name.") }
        if kind != .bambu {
            guard let url = URLComponents(string: copy.address),
                  (kind.usesWebSocket ? ["ws", "wss"] : ["http", "https"]).contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.url != nil else {
                throw PrinterError.configuration(kind.usesWebSocket
                    ? "Enter a full WebSocket address, such as ws://printer.local:\(kind == .sdcp ? "3030/websocket" : "9999")."
                    : "Enter a full printer server address, such as http://printer.local\(kind == .moonraker ? ":7125" : "").")
            }
            while copy.address.hasSuffix("/") { copy.address.removeLast() }
            if kind == .prusaLink, let username {
                copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard copy.username?.isEmpty == false, !copy.credential.isEmpty else {
                    throw PrinterError.configuration("Enter the local PrusaLink username and password.")
                }
            }
        } else {
            guard !copy.address.isEmpty,
                  !copy.address.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
                  !copy.address.contains(":") else {
                throw PrinterError.configuration("Enter the printer’s IP address or hostname, without http:// or a port.")
            }
            guard !copy.serialNumber.isEmpty,
                  copy.serialNumber.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw PrinterError.configuration("Enter the serial number from your printer’s settings.")
            }
            guard !copy.credential.isEmpty else { throw PrinterError.configuration("Enter the printer’s LAN access code.") }
        }
        return copy
    }
}

public enum PrintState: String, Codable, Sendable {
    case idle, busy, preparing, printing, paused, finished, cancelled, stopped, failed, unknown
    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .busy: return "Busy"
        case .preparing: return "Preparing"
        case .printing: return "Printing"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .cancelled: return "Cancelled"
        case .stopped: return "Stopped"
        case .failed: return "Needs attention"
        case .unknown: return "Unknown"
        }
    }
    public var isActive: Bool { [.preparing, .printing, .paused].contains(self) }
}

public enum PrinterConnectionIssue: String, Codable, Sendable {
    case localNetworkUnavailable, localNetworkAccessDenied
}

public struct PrinterSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PrinterKind
    public var state: PrintState
    public var progress: Double?
    public var jobName: String?
    public var remainingSeconds: Double?
    public var elapsedSeconds: Double?
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var nozzleTemperature: Double?
    public var bedTemperature: Double?
    public var chamberTemperature: Double?
    public var chamberTarget: Double?
    public var printerErrorCode: UInt32?
    public var updatedAt: Date
    public var isOffline: Bool
    public var connectionIssue: PrinterConnectionIssue?
    public var errorMessage: String?
    public var certificateFingerprint: String?
    public var refreshUnavailable: Bool?
    public var jobIdentifier: String?
    public var controlJobID: Int?
    public var controlsUnavailable: Bool?

    public init(profile: PrinterProfile, state: PrintState = .unknown, progress: Double? = nil,
                jobName: String? = nil, remainingSeconds: Double? = nil, elapsedSeconds: Double? = nil,
                currentLayer: Int? = nil, totalLayers: Int? = nil, nozzleTemperature: Double? = nil,
                bedTemperature: Double? = nil, chamberTemperature: Double? = nil, chamberTarget: Double? = nil,
                printerErrorCode: UInt32? = nil,
                updatedAt: Date = Date(), isOffline: Bool = false,
                errorMessage: String? = nil, certificateFingerprint: String? = nil, refreshUnavailable: Bool? = nil,
                jobIdentifier: String? = nil, controlJobID: Int? = nil, controlsUnavailable: Bool? = nil) {
        id = profile.id; name = profile.name; kind = profile.kind; self.state = state
        self.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }; self.jobName = jobName
        self.remainingSeconds = remainingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.elapsedSeconds = elapsedSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.currentLayer = currentLayer; self.totalLayers = totalLayers
        func temperature(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && Int(exactly: $0.rounded()) != nil ? $0 : nil }
        }
        self.nozzleTemperature = temperature(nozzleTemperature); self.bedTemperature = temperature(bedTemperature)
        self.chamberTemperature = temperature(chamberTemperature); self.chamberTarget = temperature(chamberTarget)
        self.printerErrorCode = printerErrorCode
        self.updatedAt = updatedAt; self.isOffline = isOffline; self.errorMessage = errorMessage
        self.certificateFingerprint = certificateFingerprint
        self.refreshUnavailable = refreshUnavailable
        self.jobIdentifier = jobIdentifier; self.controlJobID = controlJobID
        self.controlsUnavailable = controlsUnavailable
    }

    public var percentageText: String {
        guard let progress, progress.isFinite else { return "—" }
        return "\(Int((min(1, max(0, progress)) * 100).rounded()))%"
    }
    public var statusTitle: String {
        if isOffline {
            switch connectionIssue {
            case .localNetworkAccessDenied: return "Local network access blocked"
            case .localNetworkUnavailable: return "Local network unavailable"
            case nil: return "Offline"
            }
        }
        return refreshUnavailable == true ? "Refresh needed" : state.title
    }
    public var hasJob: Bool { state.isActive || [.finished, .cancelled, .stopped, .failed].contains(state) }
    public var finishDate: Date? {
        guard !isOffline, refreshUnavailable != true, state == .printing || state == .preparing,
              let seconds = remainingSeconds, seconds.isFinite, seconds > 0,
              seconds < Date.distantFuture.timeIntervalSince(updatedAt) else { return nil }
        return updatedAt.addingTimeInterval(seconds)
    }
    public func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > 300 }
    public func offline(_ error: Error) -> Self {
        var copy = self; copy.isOffline = true; copy.errorMessage = error.localizedDescription
        switch error as? PrinterError {
        case .localNetworkAccessDenied: copy.connectionIssue = .localNetworkAccessDenied
        case .localNetworkUnavailable: copy.connectionIssue = .localNetworkUnavailable
        default: copy.connectionIssue = nil
        }
        return copy
    }
    public var chamberText: String? {
        guard let chamberTemperature, ProgressFormat.temperature(chamberTemperature) != "—" else { return nil }
        let current = ProgressFormat.temperature(chamberTemperature)
        if let target = chamberTarget, target > 0, ProgressFormat.temperature(target) != "—" {
            return current + " / " + ProgressFormat.temperature(target)
        }
        return current
    }
}

public enum PrinterError: LocalizedError, Equatable {
    case configuration(String), timeout, invalidResponse, authentication, certificateChanged, disconnected, localNetworkUnavailable, localNetworkAccessDenied
    case http(Int), keychain(Int32)

    private static var localNetworkRecovery: String {
        #if os(macOS)
        return "Open System Settings → Privacy & Security → Local Network. Enable Print Progress. If it is already enabled, turn it off and back on, then quit and reopen Print Progress."
        #else
        return "Open Settings → Privacy & Security → Local Network and enable Print Progress. If it is already enabled, turn it off and back on, then reopen Print Progress."
        #endif
    }

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .timeout: return "The printer didn’t respond. Check that it’s on and connected to the same network."
        case .invalidResponse: return "The printer returned an unreadable response. Check the address and printer type."
        case .authentication: return "The printer refused access. Check its connection credentials and permission to read status."
        case .certificateChanged: return "This printer’s certificate has changed. Verify the printer and its address, then edit the connection to trust it again."
        case .disconnected: return "The connection closed before the printer sent its status."
        case .localNetworkUnavailable:
            return "Check that this device and the printer are connected to the same local network. If they are, check Local Network access for Print Progress. " + Self.localNetworkRecovery
        case .localNetworkAccessDenied:
            return "Local network access for Print Progress is blocked. " + Self.localNetworkRecovery
        case .http(let code): return "The printer returned HTTP \(code). Check its address and API access."
        case .keychain(let code): return "Keychain is unavailable (\(code)). Open the app and unlock your device."
        }
    }
}

public enum ProgressFormat {
    public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 { return "< 1 min" }
        guard let minutes = Int(exactly: ceil(seconds / 60)) else { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
    public static func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite, let degrees = Int(exactly: value.rounded()) else { return "—" }
        return "\(degrees)°"
    }
    public static func jobName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let name = (raw as NSString).lastPathComponent
        for suffix in [".gcode.3mf", ".gcode", ".3mf"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
