import Foundation

enum WidgetTapDestination: String, Codable, CaseIterable, Identifiable {
    case companion, printProgress
    var id: String { rawValue }
    var title: String { self == .companion ? "Printer companion app" : "Print Progress" }
    static func load() throws -> Self {
        try SharedVault.read(Self.self, account: "widget-tap-destination") ?? .companion
    }
    func save() throws { try SharedVault.write(self, account: "widget-tap-destination") }
}

enum WidgetNavigation {
    static func url(printerID: UUID?) -> URL? {
        var parts = URLComponents()
        parts.scheme = WidgetControlContext.urlScheme
        parts.host = "open-printer"
        parts.queryItems = printerID.map { [URLQueryItem(name: "id", value: $0.uuidString)] }
        return parts.url
    }
    static func printerID(from url: URL) -> UUID? {
        guard url.scheme == WidgetControlContext.urlScheme, url.host == "open-printer",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        return UUID(uuidString: value)
    }
    static func companionURL(for kind: PrinterKind, destination: WidgetTapDestination) -> URL? {
        guard destination == .companion, kind == .bambu else { return nil }
        // App launch only. No documented Devices-tab route is available.
        return URL(string: "bambulab://")
    }
}
