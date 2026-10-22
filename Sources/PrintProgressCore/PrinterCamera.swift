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
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let cameras = result["webcams"] as? [[String: Any]],
              let camera = cameras.first(where: { ($0["enabled"] as? Bool) != false && ($0["stream_url"] as? String)?.isEmpty == false }),
              let address = camera["stream_url"] as? String,
              var base = URLComponents(string: profile.address) else { throw PrinterCameraError.unavailable }
        // Moonraker's relative webcam URLs refer to the web frontend, not its
        // API port (commonly 7125). Absolute camera URLs keep their explicit port.
        if base.port == 7125 { base.port = nil }
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
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { throw PrinterCameraError.invalidStream }
        var frames: [Data] = []
        while let start = buffer.range(of: Data([0xff, 0xd8])) {
            if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start.lowerBound) }
            guard let end = buffer.range(of: Data([0xff, 0xd9]), in: buffer.index(buffer.startIndex, offsetBy: 2)..<buffer.endIndex) else { break }
            frames.append(Data(buffer[buffer.startIndex..<end.upperBound]))
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        return frames
    }
}
