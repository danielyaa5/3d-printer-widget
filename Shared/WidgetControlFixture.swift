#if DEBUG && PRINT_PROGRESS_WIDGET_QA
import Foundation
import WidgetKit
import CoreGraphics

/// Compiled only into the separately identified local widget QA build. Its
/// control backend never uses a network client and refuses production bundle IDs.
enum WidgetControlFixture {
    static var profile: PrinterProfile {
        var value = PrinterProfile(id: UUID(uuidString: "BEB7D1B1-6A83-4000-9000-000000000001")!,
            name: "Widget Test", kind: .moonraker, address: "http://printer.invalid:7125")
        value.camera = PrinterCameraSettings()
        value.camera?.widgetSnapshotsEnabled = (try? SharedVault.read(Bool.self, account: "widget-qa-camera-enabled")) != false
        value.camera?.widgetSnapshotGeneration = UUID(uuidString: "BEB7D1B1-6A83-4000-9000-000000000002")!
        return value
    }
    struct Receipt: Codable { var command: String; var at: Date }
    struct Report: Codable {
        var receipts: [Receipt]
        var state: PrintState
        var feedback: WidgetControlFeedback?
        var stopURL: URL?
        var generatedAt = Date()
    }

    static func checkIsolation() throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("org.example.printprogresswidgetqa.") == true else {
            throw PrinterError.configuration("Widget QA is only allowed in its separate test app.")
        }
    }
    static func prepare(reset: Bool = false) throws {
        try checkIsolation()
        if reset { try SharedVault.delete(account: "widget-qa-camera-enabled") }
        if try reset || SharedVault.profiles().isEmpty {
            try SharedVault.saveProfiles([profile])
            try SharedVault.saveSnapshot(PrinterSnapshot(profile: profile, state: .printing, progress: 0.64,
                jobName: "Test planter", remainingSeconds: 2520, currentLayer: 128, totalLayers: 200,
                nozzleTemperature: 220, bedTemperature: 60, chamberTemperature: 42, chamberTarget: 45,
                jobIdentifier: "widget-test.gcode"))
            try SharedVault.write([Receipt](), account: "widget-qa-receipts")
            try SharedVault.delete(account: "widget-qa-reject-controls")
            try SharedVault.delete(account: "widget-control.\(profile.id.uuidString)")
            // A wide synthetic picture exercises camera-widget hit regions.
            guard let canvas = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PrinterError.invalidResponse }
            canvas.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.7, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            guard let image = canvas.makeImage() else { throw PrinterError.invalidResponse }
            try SharedVault.saveCameraSnapshot(WidgetCameraSnapshot.capture(image, printerID: profile.id,
                capturedAt: .now, generation: profile.camera?.widgetSnapshotGeneration))
        }
    }
    static func reading(_ profile: PrinterProfile) throws -> PrinterSnapshot {
        try prepare()
        guard profile == Self.profile, var value = try SharedVault.snapshot(for: profile.id) else {
            throw PrinterControlError.jobChanged
        }
        value.updatedAt = .now
        return value
    }

    /// A visibly different, deterministic photo for checking the real widget's
    /// bitmap replacement. This uses only the isolated QA Keychain namespace.
    static func saveTestPhoto(step: Int) throws {
        try checkIsolation()
        guard (0...999).contains(step),
              let canvas = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PrinterError.invalidResponse }
        canvas.setFillColor(step.isMultiple(of: 2)
            ? CGColor(red: 0.1, green: 0.5, blue: 0.7, alpha: 1)
            : CGColor(red: 0.9, green: 0.35, blue: 0.05, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        if step > 0 {
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            let x = step.isMultiple(of: 2) ? 460 : 100
            canvas.fill(CGRect(x: x, y: 100, width: 80, height: 160))
        }
        guard let image = canvas.makeImage() else { throw PrinterError.invalidResponse }
        try SharedVault.saveCameraSnapshot(WidgetCameraSnapshot.capture(image, printerID: profile.id,
            capturedAt: .now, generation: profile.camera?.widgetSnapshotGeneration))
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func send(_ command: PrinterCommand, profile: PrinterProfile, expected: PrinterSnapshot) throws {
        try checkIsolation()
        var current = try reading(profile)
        try PrinterControl.validateSameJob(command, expected: expected, current: current)
        if try SharedVault.read(Bool.self, account: "widget-qa-reject-controls") == true {
            throw PrinterControlError.bambuRejected(reason: "mqtt message verify failed")
        }
        current.state = command == .pause ? .paused : command == .resume ? .printing : .cancelled
        if command == .stop { current.remainingSeconds = nil }
        current.updatedAt = .now
        try SharedVault.saveSnapshot(current)
        var receipts = try SharedVault.read([Receipt].self, account: "widget-qa-receipts") ?? []
        receipts.append(Receipt(command: command.rawValue, at: .now))
        try SharedVault.write(receipts, account: "widget-qa-receipts")
    }
    static var dependencies: WidgetControlDependencies {
        .init(profiles: { try prepare(); return [profile] }, fetch: { try reading($0) },
            send: { try send($0, profile: $1, expected: $2) }, save: SharedVault.saveSnapshot,
            feedback: WidgetControlFeedback.load, report: { try WidgetControlFeedback.save($1, for: $0) },
            claim: SharedVault.claimWidgetAction, reload: { WidgetCenter.shared.reloadAllTimelines() })
    }
    static func widgetData() -> (snapshots: [PrinterSnapshot], message: String?, controls: [UUID: WidgetControlContext], feedback: [UUID: WidgetControlFeedback]) {
        do {
            let value = try reading(profile)
            return ([value], nil, [profile.id: try WidgetControlContext(profile: profile, snapshot: value)],
                [profile.id: try WidgetControlFeedback.load(profile.id)].compactMapValues { $0 })
        } catch { return ([], error.localizedDescription, [:], [:]) }
    }
    static func exportIfRequested() throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--widget-qa-report"),
              CommandLine.arguments.count > index + 1 else { return }
        try checkIsolation()
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        guard url.pathComponents.contains(where: { $0.hasSuffix(".noindex") }), url.pathExtension == "json" else {
            throw PrinterError.configuration("QA reports require an ignored .noindex folder.")
        }
        let snapshot = try reading(profile)
        let report = Report(receipts: try SharedVault.read([Receipt].self, account: "widget-qa-receipts") ?? [],
                            state: snapshot.state,
                            feedback: try WidgetControlFeedback.load(profile.id),
                            stopURL: try WidgetControlContext(profile: profile, snapshot: snapshot).stopURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
    }
}
#endif
