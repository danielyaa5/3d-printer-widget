import Foundation
import CoreGraphics

public enum PrinterCameraError: LocalizedError {
    case unavailable, disconnected, unsupported, invalidStream, authentication, timeout, certificateChanged
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "No camera found. Set a Custom Camera URL in Edit connection."
        case .disconnected: return "Camera disconnected. Check the connection and try again."
        case .unsupported: return "This camera format isn’t supported. Use an HTTP MJPEG stream."
        case .invalidStream: return "The camera returned an unreadable video stream."
        case .authentication: return "The camera rejected the saved access code."
        case .timeout: return "Camera unavailable. Check the address and local video settings, or set a Custom Camera URL in Edit connection."
        case .certificateChanged: return "The camera certificate changed. Verify the printer, then trust its replacement certificate in Edit connection."
        }
    }
}

public struct PrinterCameraChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let streamURL: String
    public let discoveredCameraID: String?
    public init(id: String, name: String, streamURL: String = "", discoveredCameraID: String? = nil) {
        self.id = id; self.name = name; self.streamURL = streamURL; self.discoveredCameraID = discoveredCameraID
    }
}

public struct PrinterCameraSource: Sendable {
    public let url: URL
    public let headers: [String: String]
    public var rotation = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public static func resolve(_ profile: PrinterProfile) async throws -> Self {
        if let address = profile.camera?.streamURL, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = try validatedHTTPURL(address)
            return Self(url: url, headers: headers(profile, for: url))
        }
        if profile.kind == .bambu {
            guard let url = URL(string: "rtsps://\(profile.address):322/streaming/live/1") else {
                throw PrinterCameraError.unavailable
            }
            return Self(url: url, headers: [:])
        }
        guard profile.kind == .moonraker else { throw PrinterCameraError.unavailable }
        let reader = PrinterHTTPReader(profile: profile, timeout: 10, configuration: .ephemeral)
        defer { reader.close() }
        let data = try await reader.get("server/webcams/list")
        return try moonraker(data, profile: profile)
    }

    /// Read-only discovery scoped to the selected printer. A listed connection
    /// is not a successful picture test, and discovery never changes settings.
    public static func discover(_ profile: PrinterProfile) async throws -> [PrinterCameraChoice] {
        var choices: [PrinterCameraChoice] = []
        if profile.kind == .moonraker {
            let reader = PrinterHTTPReader(profile: profile, timeout: 10, configuration: .ephemeral)
            defer { reader.close() }
            choices = try moonrakerChoices(await reader.get("server/webcams/list"), profile: profile).map(\.choice)
        } else if profile.kind == .bambu {
            choices.append(.init(id: "bambu-local", name: "Direct local camera"))
        }
        if let address = profile.camera?.streamURL, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = try validatedHTTPURL(address)
            choices.append(.init(id: "saved-custom", name: "Saved custom or bridge camera", streamURL: url.absoluteString))
        }
        return choices
    }

    public static func validatedHTTPURL(_ address: String) throws -> URL {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, let url = parts.url else { throw PrinterCameraError.unsupported }
        return url
    }

    static func headers(_ profile: PrinterProfile, for url: URL) -> [String: String] {
        // Never forward the printer API key to a separate camera server, another
        // port, or a downgraded HTTP connection.
        guard let origin = URL(string: profile.address), origin.host == url.host,
              origin.scheme == url.scheme, effectivePort(origin) == effectivePort(url),
              [.moonraker, .octoPrint].contains(profile.kind), !profile.credential.isEmpty else { return [:] }
        return ["X-Api-Key": profile.credential]
    }
    private static func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }

    static func moonraker(_ data: Data, profile: PrinterProfile) throws -> Self {
        let choices = try moonrakerChoices(data, profile: profile)
        let requestedID = profile.camera?.discoveredCameraID
        guard let selected = choices.first(where: { requestedID == nil || $0.choice.id == requestedID }) else {
            throw PrinterCameraError.unavailable
        }
        return selected.source
    }

    static func moonrakerChoices(_ data: Data, profile: PrinterProfile) throws -> [(choice: PrinterCameraChoice, source: Self)] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let cameras = result["webcams"] as? [[String: Any]] else { throw PrinterCameraError.unavailable }
        var seen: Set<String> = []
        return cameras.enumerated().compactMap { index, camera in
            guard camera["enabled"] as? Bool != false,
                  let source = try? moonrakerSource(camera, profile: profile) else { return nil }
            let uid = (camera["uid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = uid?.isEmpty == false ? "moonraker:" + uid! : "stream:" + source.url.absoluteString
            guard seen.insert(id).inserted else { return nil }
            let name = (camera["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let choice = PrinterCameraChoice(id: id, name: name?.isEmpty == false ? String(name!.prefix(80)) : "Camera \(index + 1)", discoveredCameraID: id)
            return (choice, source)
        }
    }

    private static func moonrakerSource(_ camera: [String: Any], profile: PrinterProfile) throws -> Self {
        guard let address = camera["stream_url"] as? String, !address.isEmpty,
              var base = URLComponents(string: profile.address) else { throw PrinterCameraError.unavailable }
        // Moonraker's relative webcam URLs refer to the web frontend, not its
        // API port (commonly 7125). Absolute camera URLs keep their explicit port.
        if base.port == 7125 { base.port = nil }
        // Some frontends run on a separate port (including rooted K1 printers).
        // When the same camera advertises an absolute snapshot endpoint on the
        // printer with the same path, use that origin for its relative stream.
        // Do not guess a port or borrow another camera server's credentials.
        if let stream = URLComponents(string: address), stream.scheme == nil, stream.host == nil,
           let snapshotAddress = camera["snapshot_url"] as? String,
           let snapshot = try? validatedHTTPURL(snapshotAddress),
           snapshot.host == base.host, snapshot.scheme == base.scheme,
           let defaultOrigin = base.url,
           let relative = URL(string: address, relativeTo: defaultOrigin)?.absoluteURL,
           relative.path == snapshot.path,
           var cameraOrigin = URLComponents(url: snapshot, resolvingAgainstBaseURL: false) {
            cameraOrigin.path = "/"; cameraOrigin.query = nil; cameraOrigin.fragment = nil
            base = cameraOrigin
        }
        guard let origin = base.url, let resolved = URL(string: address, relativeTo: origin)?.absoluteURL else {
            throw PrinterCameraError.unavailable
        }
        let url = try validatedHTTPURL(resolved.absoluteString)
        var source = Self(url: url, headers: headers(profile, for: url))
        source.rotation = [0, 90, 180, 270].contains(camera["rotation"] as? Int ?? 0) ? camera["rotation"] as? Int ?? 0 : 0
        source.flipHorizontal = camera["flip_horizontal"] as? Bool ?? false
        source.flipVertical = camera["flip_vertical"] as? Bool ?? false
        return source
    }
}

/// Bounded JPEG extraction across arbitrary network chunks. No camera bytes are cached.
struct CameraJPEGParser {
    private var buffer = Data()
    private var hasStart = false
    private var searchOffset = 0
    private static let startMarker = Data([0xff, 0xd8])
    private static let endMarker = Data([0xff, 0xd9])

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { throw PrinterCameraError.invalidStream }
        var frames: [Data] = []
        while !buffer.isEmpty {
            if !hasStart {
                let searchStart = buffer.index(buffer.startIndex, offsetBy: searchOffset)
                guard let start = buffer.range(of: Self.startMarker, in: searchStart..<buffer.endIndex) else {
                    searchOffset = max(0, buffer.count - 1)
                    break
                }
                if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start.lowerBound) }
                hasStart = true
                searchOffset = 2
            }
            let searchStart = buffer.index(buffer.startIndex, offsetBy: searchOffset)
            guard let end = buffer.range(of: Self.endMarker, in: searchStart..<buffer.endIndex) else {
                // Revisit only the trailing byte, in case a JPEG marker spans
                // network chunks. Rescanning the whole partial image makes
                // fragmented camera streams increasingly expensive.
                searchOffset = max(2, buffer.count - 1)
                break
            }
            frames.append(Data(buffer[buffer.startIndex..<end.upperBound]))
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            hasStart = false
            searchOffset = 0
        }
        return frames
    }
}
