import SwiftUI
import WidgetKit

/// The live app always uses Keychain. Injection keeps feature tests isolated from
/// saved printers and lets them exercise failures and in-flight request races.
struct ProgressStoreDependencies {
    var loadProfiles: () throws -> [PrinterProfile]
    var loadSnapshot: (UUID) throws -> PrinterSnapshot?
    var saveProfiles: ([PrinterProfile]) throws -> Void
    var saveSnapshot: (PrinterSnapshot) throws -> Void
    var deleteSnapshot: (UUID) throws -> Void
    var fetch: @Sendable (PrinterProfile) async throws -> PrinterSnapshot
    var reloadWidgets: () -> Void
    var now: () -> Date = Date.init
    var autoStart = true
    var verificationReports = true
    var isDemo = false

    static var live: Self {
        Self(loadProfiles: SharedVault.profiles, loadSnapshot: SharedVault.snapshot,
             saveProfiles: SharedVault.saveProfiles, saveSnapshot: SharedVault.saveSnapshot,
             deleteSnapshot: { try SharedVault.delete(account: "snapshot.\($0.uuidString)") },
             fetch: { try await PrinterClient.fetch($0) },
             reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    }

    static var demo: Self {
        Self(loadProfiles: { DemoData.profiles },
             loadSnapshot: { id in DemoData.snapshots().first { $0.id == id } },
             saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
             fetch: { profile in PrinterSnapshot(profile: profile) }, reloadWidgets: {},
             autoStart: false, verificationReports: false, isDemo: true)
    }
}

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var profiles: [PrinterProfile] = []
    @Published private(set) var snapshots: [UUID: PrinterSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    private var pollTask: Task<Void, Never>?
    private var lastPersisted: [UUID: Date] = [:]
    private var lastWidgetReload = Date.distantPast
    private let dependencies: ProgressStoreDependencies
    var isDemo: Bool { dependencies.isDemo }

    init(dependencies: ProgressStoreDependencies = .live) {
        self.dependencies = dependencies
        do {
            profiles = try dependencies.loadProfiles()
            #if DEBUG
            // Local development provisioning only. This file is never bundled or exported.
            if !dependencies.isDemo, let index = CommandLine.arguments.firstIndex(of: "--import-from-documents"),
               CommandLine.arguments.count > index + 1 {
                let filename = CommandLine.arguments[index + 1]
                if filename == (filename as NSString).lastPathComponent {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(filename)
                    let imported = try JSONDecoder().decode([PrinterProfile].self, from: Data(contentsOf: url))
                    profiles = try imported.map { try $0.validated() }
                    try SharedVault.saveProfiles(profiles)
                    try FileManager.default.removeItem(at: url)
                }
            }
            #endif
            for profile in profiles { snapshots[profile.id] = try dependencies.loadSnapshot(profile.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func start() {
        guard dependencies.autoStart, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
    }
    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh() async {
        if isDemo {
            for id in snapshots.keys { snapshots[id]?.updatedAt = dependencies.now() }
            return
        }
        guard !isRefreshing, !profiles.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let current = profiles
        let fetch = dependencies.fetch
        await withTaskGroup(of: (UUID, Result<PrinterSnapshot, Error>).self) { group in
            for profile in current {
                group.addTask {
                    do { return (profile.id, .success(try await fetch(profile))) }
                    catch { return (profile.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard let profile = profiles.first(where: { $0.id == id }),
                      current.first(where: { $0.id == id }) == profile else { continue }
                switch result {
                case .success(let snapshot):
                    let previous = snapshots[id]
                    snapshots[id] = snapshot
                    do {
                        if profile.certificateFingerprint == nil, let pin = snapshot.certificateFingerprint,
                           let index = profiles.firstIndex(where: { $0.id == id }) {
                            var pinned = profiles
                            pinned[index].certificateFingerprint = pin
                            try dependencies.saveProfiles(pinned)
                            profiles = pinned
                        }
                        // Persist immediately on a state change, otherwise at most once per minute.
                        if previous?.state != snapshot.state || previous?.isOffline != false
                            || dependencies.now().timeIntervalSince(lastPersisted[id] ?? .distantPast) >= 60 {
                            try dependencies.saveSnapshot(snapshot); lastPersisted[id] = dependencies.now()
                        }
                    } catch { errorMessage = error.localizedDescription }
                case .failure(let error):
                    if error is CancellationError { continue }
                    snapshots[id] = (snapshots[id] ?? PrinterSnapshot(profile: profile, updatedAt: .distantPast)).offline(error)
                    if let snapshot = snapshots[id] {
                        do { try dependencies.saveSnapshot(snapshot) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        if dependencies.now().timeIntervalSince(lastWidgetReload) >= 60 {
            dependencies.reloadWidgets(); lastWidgetReload = dependencies.now()
        }
        #if DEBUG
        if dependencies.verificationReports { writeVerificationReport() }
        #endif
    }

    func setDemoState(_ state: PrintState) {
        guard isDemo else { return }
        snapshots = Dictionary(uniqueKeysWithValues: DemoData.snapshots(state: state, date: dependencies.now()).map { ($0.id, $0) })
    }

    func save(_ profile: PrinterProfile, snapshot: PrinterSnapshot) throws {
        var profile = profile
        profile.certificateFingerprint = snapshot.certificateFingerprint ?? profile.certificateFingerprint
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        try dependencies.saveProfiles(updated)
        // Reflect the committed profile even if the optional cache write fails.
        profiles = updated; snapshots[profile.id] = snapshot
        do {
            try dependencies.saveSnapshot(snapshot)
            lastPersisted[profile.id] = dependencies.now()
        } catch { errorMessage = error.localizedDescription }
        dependencies.reloadWidgets()
        if dependencies.autoStart { start() }
    }
    func remove(_ profile: PrinterProfile) throws {
        let updated = profiles.filter { $0.id != profile.id }
        try dependencies.saveProfiles(updated)
        profiles = updated; snapshots[profile.id] = nil
        lastPersisted[profile.id] = nil
        // An orphaned cache is never displayed without its saved profile.
        do { try dependencies.deleteSnapshot(profile.id) }
        catch { errorMessage = error.localizedDescription }
        dependencies.reloadWidgets()
    }
    var activePrinter: PrinterSnapshot? {
        profiles.compactMap { snapshots[$0.id] }.first { !$0.isOffline && $0.state.isActive }
    }

    #if DEBUG
    private func writeVerificationReport() {
        // A local development check of the same data used by the visible cards.
        // No addresses, credentials, serial numbers, or print filenames are included.
        struct Reading: Encodable {
            let kind: PrinterKind
            let state: PrintState
            let progress: Double?
            let online: Bool
            let updatedAt: Date
            let error: String?
            let chamberTemperature: Double?
            let chamberTarget: Double?
            let printerErrorCode: UInt32?
        }
        let readings = profiles.compactMap { profile -> Reading? in
            guard let snapshot = snapshots[profile.id] else { return nil }
            return Reading(kind: profile.kind, state: snapshot.state, progress: snapshot.progress,
                           online: !snapshot.isOffline, updatedAt: snapshot.updatedAt, error: snapshot.errorMessage,
                           chamberTemperature: snapshot.chamberTemperature, chamberTarget: snapshot.chamberTarget,
                           printerErrorCode: snapshot.printerErrorCode)
        }
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(readings) {
            try? data.write(to: cache.appendingPathComponent("PrintProgress-verification.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if let verification = try? SharedVault.read(WidgetVerification.self, account: "widget-verification"),
           let data = try? encoder.encode(verification) {
            try? data.write(to: cache.appendingPathComponent("PrintProgress-widget-verification.json"), options: .atomic)
        }
    }
    #endif
}
