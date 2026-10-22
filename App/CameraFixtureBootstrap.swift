#if DEBUG
import Foundation

/// Explicit, in-memory UI verification mode. Never imports or edits saved printers.
enum CameraFixtureBootstrap {
    static var dependencies: ProgressStoreDependencies? {
        let args = CommandLine.arguments
        guard args.contains("--ui-testing-camera") else { return nil }
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
            return args[index + 1]
        }
        guard let rawHTTP = value("--camera-http-port"), let http = UInt16(rawHTTP), http > 0,
              let rawRTSP = value("--camera-rtsp-port"), let rtsp = UInt16(rawRTSP), rtsp > 0 else { return nil }
        var printers = [PrinterProfile(name: "Test MJPEG", kind: .moonraker, address: "http://127.0.0.1:\(http)"),
                        PrinterProfile(name: "Test RTSPS", kind: .bambu, address: "127.0.0.1", serialNumber: "FIXTURE", credential: "fixture-password")]
        if let address = value("--camera-moonraker-address"), let url = try? PrinterCameraSource.validatedHTTPURL(address) {
            printers.insert(PrinterProfile(name: "Test Klipper", kind: .moonraker, address: url.absoluteString), at: 0)
        }
        let fixtures = printers
        var dependencies = ProgressStoreDependencies(loadProfiles: { fixtures },
            loadSnapshot: { id in fixtures.first(where: { $0.id == id }).map { PrinterSnapshot(profile: $0) } },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false)
        dependencies.cameraSource = { profile in
            if profile.kind == .bambu {
                return PrinterCameraSource(url: URL(string: "rtsps://127.0.0.1:\(rtsp)/streaming/live/1")!, headers: [:])
            }
            return try await PrinterCameraSource.resolve(profile)
        }
        return dependencies
    }
}
#endif
