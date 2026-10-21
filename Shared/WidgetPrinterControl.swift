import Foundation
import CryptoKit
import AppIntents
import WidgetKit

/// A widget carries the job it displayed and an opaque connection revision,
/// never printer credentials. A fresh reading is required before any command.
struct WidgetControlContext: Codable, Identifiable {
    static var urlScheme: String {
        #if DEBUG && PRINT_PROGRESS_WIDGET_QA
        "printprogresswidgetqa"
        #else
        "printprogress"
        #endif
    }
    var id = UUID()
    var snapshot: PrinterSnapshot
    var revision: String

    init(profile: PrinterProfile, snapshot: PrinterSnapshot) throws {
        self.snapshot = snapshot
        self.snapshot.certificateFingerprint = nil
        self.snapshot.errorMessage = nil
        revision = try Self.revision(profile)
    }
    static func revision(_ profile: PrinterProfile) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(profile)).map { String(format: "%02x", $0) }.joined()
    }
    func validate(profile: PrinterProfile, now: Date = .now) throws {
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard profile.id == snapshot.id, profile.kind == snapshot.kind,
              try Self.revision(profile) == revision else { throw PrinterControlError.jobChanged }
        guard age >= -5, age <= 1800, !snapshot.isOffline, snapshot.refreshUnavailable != true else {
            throw PrinterControlError.refreshRequired
        }
    }
    var encoded: String {
        ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString()
    }
    static func decode(_ value: String) throws -> Self {
        guard value.utf8.count <= 16_384, let data = Data(base64Encoded: value) else {
            throw PrinterError.invalidResponse
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    var stopURL: URL? {
        var parts = URLComponents(); parts.scheme = Self.urlScheme; parts.host = "stop"
        parts.queryItems = [URLQueryItem(name: "context", value: encoded)]
        return parts.url
    }
    static func stopContext(from url: URL) throws -> Self? {
        guard url.scheme == Self.urlScheme, url.host == "stop" else { return nil }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "context" })?.value else { throw PrinterError.invalidResponse }
        return try decode(value)
    }
}

struct WidgetControlFeedback: Codable {
    var message: String
    var blockedUntil: Date?
    var createdAt = Date()
    func isBlocked(at date: Date = .now) -> Bool { (blockedUntil ?? .distantPast) > date }
    static func load(_ id: UUID) throws -> Self? {
        try SharedVault.read(Self.self, account: "widget-control.\(id.uuidString)")
    }
    static func save(_ value: Self, for id: UUID) throws {
        try SharedVault.write(value, account: "widget-control.\(id.uuidString)")
    }
}

struct WidgetControlDependencies {
    var profiles: () throws -> [PrinterProfile]
    var fetch: (PrinterProfile) async throws -> PrinterSnapshot
    var send: (PrinterCommand, PrinterProfile, PrinterSnapshot) async throws -> Void
    var save: (PrinterSnapshot) throws -> Void
    var feedback: (UUID) throws -> WidgetControlFeedback?
    var report: (UUID, WidgetControlFeedback) throws -> Void
    var claim: (UUID) throws -> Void
    var reload: () -> Void
    var now: () -> Date = Date.init

    static var live: Self {
        #if DEBUG && PRINT_PROGRESS_WIDGET_QA
        return WidgetControlFixture.dependencies
        #else
        return Self(profiles: SharedVault.profiles,
            fetch: { try await PrinterClient.fetch($0, timeout: 6) },
            send: { try await PrinterControl.perform($0, profile: $1, expected: $2, timeout: 10) },
            save: SharedVault.saveSnapshot, feedback: WidgetControlFeedback.load,
            report: { try WidgetControlFeedback.save($1, for: $0) }, claim: SharedVault.claimWidgetAction,
            reload: { WidgetCenter.shared.reloadAllTimelines() })
        #endif
    }
}

actor WidgetControlService {
    static let shared = WidgetControlService()
    private var busy: Set<UUID> = []

    func perform(_ command: PrinterCommand, context: WidgetControlContext,
                 dependencies: WidgetControlDependencies = .live) async throws {
        // Stop must go through the app's job-specific confirmation sheet.
        guard command != .stop else { throw PrinterControlError.rejected }
        let id = context.snapshot.id
        guard busy.insert(id).inserted else { throw PrinterControlError.busy }
        defer { busy.remove(id); dependencies.reload() }
        var requested = false
        do {
            guard let profile = try dependencies.profiles().first(where: { $0.id == id }) else {
                throw PrinterControlError.jobChanged
            }
            try context.validate(profile: profile, now: dependencies.now())
            guard try dependencies.feedback(id)?.isBlocked(at: dependencies.now()) != true else {
                throw PrinterControlError.busy
            }
            // Keychain's atomic add makes a rendered button single-use, even if
            // the system dispatches two intent instances or processes.
            try dependencies.claim(context.id)
            try dependencies.report(id, .init(message: "Sending \(command.title.lowercased())…",
                blockedUntil: dependencies.now().addingTimeInterval(30)))
            dependencies.reload()
            let current = try await dependencies.fetch(profile)
            try PrinterControl.validateSameJob(command, expected: context.snapshot, current: current, now: dependencies.now())
            guard try dependencies.profiles().first(where: { $0.id == id }) == profile else {
                throw PrinterControlError.jobChanged
            }
            try await dependencies.send(command, profile, current)
            requested = true
            // Acknowledgement is not status: retain only actual printer reports.
            let updated = try await dependencies.fetch(profile)
            guard try dependencies.profiles().first(where: { $0.id == id }) == profile else {
                throw PrinterControlError.jobChanged
            }
            try dependencies.save(updated)
            let confirmed = !updated.isOffline && (command == .pause ? updated.state == .paused : updated.state == .printing)
            try dependencies.report(id, .init(message: confirmed ? "Printer reports: \(updated.statusTitle.lowercased())." : "Requested. Waiting for printer status…",
                blockedUntil: confirmed ? nil : dependencies.now().addingTimeInterval(30)))
        } catch {
            let error = requested ? PrinterControlError.unconfirmed : error
            if error as? PrinterControlError != .busy {
                try? dependencies.report(id, .init(message: error.localizedDescription,
                    blockedUntil: dependencies.now().addingTimeInterval(30)))
            }
            throw error
        }
    }
}

struct WidgetPrintActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause or resume a print"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Displayed print") var context: String
    @Parameter(title: "Action") var command: String
    init() {}
    init(context: WidgetControlContext, command: PrinterCommand) {
        self.context = context.encoded; self.command = command.rawValue
    }
    func perform() async throws -> some IntentResult {
        guard let action = PrinterCommand(rawValue: command), action != .stop else { throw PrinterControlError.rejected }
        try await WidgetControlService.shared.perform(action, context: WidgetControlContext.decode(context))
        return .result()
    }
}
