#if DEBUG && PRINT_PROGRESS_WIDGET_QA
import Foundation
import WidgetKit

/// Compiled only into the separately identified local widget QA build. Its
/// control backend never uses a network client and refuses production bundle IDs.
enum WidgetControlFixture {
    static let profile = PrinterProfile(id: UUID(uuidString: "BEB7D1B1-6A83-4000-9000-000000000001")!,
        name: "Widget Test", kind: .moonraker, address: "http://printer.invalid:7125")
    struct Receipt: Codable { var command: String; var at: Date }
    struct Report: Codable {
        var receipts: [Receipt]
        var state: PrintState
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
        if try reset || SharedVault.profiles().isEmpty {
            try SharedVault.saveProfiles([profile])
            try SharedVault.saveSnapshot(PrinterSnapshot(profile: profile, state: .printing, progress: 0.64,
                jobName: "Test planter", remainingSeconds: 2520, currentLayer: 128, totalLayers: 200,
                nozzleTemperature: 220, bedTemperature: 60, chamberTemperature: 42, chamberTarget: 45,
                jobIdentifier: "widget-test.gcode"))
            try SharedVault.write([Receipt](), account: "widget-qa-receipts")
            try SharedVault.delete(account: "widget-control.\(profile.id.uuidString)")
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
    static func send(_ command: PrinterCommand, profile: PrinterProfile, expected: PrinterSnapshot) throws {
        try checkIsolation()
        var current = try reading(profile)
        try PrinterControl.validateSameJob(command, expected: expected, current: current)
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
                            stopURL: try WidgetControlContext(profile: profile, snapshot: snapshot).stopURL)
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
    }
}
#endif
