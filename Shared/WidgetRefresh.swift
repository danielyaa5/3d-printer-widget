import Foundation

struct WidgetRefreshRequest: Codable, Equatable {
    var printerIDs: Set<UUID>
    var cameraIDs: Set<UUID>

    var url: URL {
        var parts = URLComponents()
        parts.scheme = WidgetControlContext.urlScheme; parts.host = "refresh"
        parts.queryItems = printerIDs.sorted { $0.uuidString < $1.uuidString }.map { URLQueryItem(name: "printer", value: $0.uuidString) }
            + cameraIDs.sorted { $0.uuidString < $1.uuidString }.map { URLQueryItem(name: "camera", value: $0.uuidString) }
        return parts.url!
    }

    static func decode(_ url: URL) -> Self? {
        guard url.scheme == WidgetControlContext.urlScheme, url.host == "refresh",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var printers: Set<UUID> = [], cameras: Set<UUID> = []
        for item in parts.queryItems ?? [] {
            guard ["printer", "camera"].contains(item.name), let value = item.value, let id = UUID(uuidString: value) else { return nil }
            if item.name == "printer" { printers.insert(id) } else { cameras.insert(id) }
        }
        guard cameras.isSubset(of: printers) else { return nil }
        return Self(printerIDs: printers, cameraIDs: cameras)
    }
}

struct WidgetRefreshFeedback: Codable, Equatable {
    enum Phase: String, Codable { case refreshing, succeeded, failed }
    var request: WidgetRefreshRequest
    var phase: Phase
    var updatedAt: Date
    var expiresAt: Date { updatedAt.addingTimeInterval(phase == .refreshing ? 90 : 30) }
    var symbol: String {
        switch phase {
        case .refreshing: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }
    var label: String {
        switch phase {
        case .refreshing: return request.cameraIDs.isEmpty ? "Refreshing printer status" : "Capturing a new camera snapshot"
        case .succeeded: return request.cameraIDs.isEmpty ? "Printer status refreshed" : "Camera snapshot refreshed"
        case .failed: return "Refresh incomplete. Open app to retry."
        }
    }
    func applies(to target: WidgetRefreshRequest, at date: Date) -> Bool {
        date >= updatedAt && date < expiresAt && !target.printerIDs.isEmpty
            && target.printerIDs.isSubset(of: request.printerIDs) && target.cameraIDs.isSubset(of: request.cameraIDs)
    }
    static func load() throws -> Self? { try SharedVault.read(Self.self, account: "widget-refresh-feedback") }
    static func save(_ value: Self) throws { try SharedVault.write(value, account: "widget-refresh-feedback") }
}
