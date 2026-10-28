import SwiftUI
import WidgetKit
import OSLog

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
    var cameraSource: @Sendable (PrinterProfile) async throws -> PrinterCameraSource = { try await PrinterCameraSource.resolve($0) }
    var discoverCameras: @Sendable (PrinterProfile) async throws -> [PrinterCameraChoice] = { try await PrinterCameraSource.discover($0) }
    var loadCameraSnapshot: (UUID) throws -> WidgetCameraSnapshot? = { _ in nil }
    var saveCameraSnapshot: (WidgetCameraSnapshot) throws -> Void = { _ in }
    var deleteCameraSnapshot: (UUID) throws -> Void = { _ in }
    var loadCameraStatus: (UUID) throws -> WidgetCameraStatus? = { _ in nil }
    var saveCameraStatus: (WidgetCameraStatus) throws -> Void = { _ in }
    var deleteCameraStatus: (UUID) throws -> Void = { _ in }
    var saveWidgetRefreshFeedback: (WidgetRefreshFeedback) throws -> Void = { _ in }
    var loadCaptureInterval: () throws -> Double = { 5 }
    var saveCaptureInterval: (Double) throws -> Void = { _ in }
    var loadActivity: () throws -> [UUID: Date] = { [:] }
    var saveActivity: ([UUID: Date]) throws -> Void = { _ in }
    var control: @Sendable (PrinterCommand, PrinterProfile, PrinterSnapshot) async throws -> Void = { _, _, _ in
        throw PrinterControlError.unsupported
    }

    static var live: Self {
        #if DEBUG && PRINT_PROGRESS_WIDGET_QA
        return WidgetControlFixture.storeDependencies
        #else
        Self(loadProfiles: SharedVault.profiles, loadSnapshot: SharedVault.snapshot,
             saveProfiles: SharedVault.saveProfiles, saveSnapshot: SharedVault.saveSnapshot,
             deleteSnapshot: { try SharedVault.delete(account: "snapshot.\($0.uuidString)") },
             fetch: { try await PrinterClient.fetch($0) },
             reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
             loadCameraSnapshot: SharedVault.cameraSnapshot, saveCameraSnapshot: SharedVault.saveCameraSnapshot,
             deleteCameraSnapshot: SharedVault.deleteCameraSnapshot,
             loadCameraStatus: SharedVault.cameraStatus, saveCameraStatus: SharedVault.saveCameraStatus,
             deleteCameraStatus: SharedVault.deleteCameraStatus,
             saveWidgetRefreshFeedback: WidgetRefreshFeedback.save,
             loadCaptureInterval: { try SharedVault.read(Double.self, account: "camera-capture-interval") ?? 5 },
             saveCaptureInterval: { try SharedVault.write($0, account: "camera-capture-interval") },
             loadActivity: { try SharedVault.read([UUID: Date].self, account: "printing-activity") ?? [:] },
             saveActivity: { try SharedVault.write($0, account: "printing-activity") },
             control: { try await PrinterControl.perform($0, profile: $1, expected: $2) })
        #endif
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
    @Published private(set) var printingActivity: [UUID: Date] = [:]
    var sortedProfiles: [PrinterProfile] {
        profiles.enumerated().sorted {
            let a = printingActivity[$0.element.id] ?? .distantPast
            let b = printingActivity[$1.element.id] ?? .distantPast
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    @Published private(set) var snapshots: [UUID: PrinterSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var controlMessages: [UUID: String] = [:]
    @Published private(set) var pendingControls: [UUID: PendingControl] = [:]
    struct PendingControl {
        let command: PrinterCommand
        var confirmationDeadline: Date?
    }
    private var controlTasks: [UUID: Task<Void, Error>] = [:]
    private var generations: [UUID: UInt] = [:]
    private var pollTask: Task<Void, Never>?
    private var widgetCameraPollTask: Task<Void, Never>?
    private var widgetCameraPollGeneration = UUID()
    private var lastPersisted: [UUID: Date] = [:]
    private var lastWidgetReload = Date.distantPast
    private let connectionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrintProgress", category: "PrinterConnection")
    private let dependencies: ProgressStoreDependencies
    private var cameraSessions: [UUID: CameraPreviewModel] = [:]
    private var widgetCameraTasks: [UUID: Task<Void, Never>] = [:]
    private var widgetCameraGenerations: [UUID: UUID] = [:]
    private var lastWidgetCameraAttempt: [UUID: Date] = [:]
    private var isRefreshingFromWidget = false
    @Published private(set) var widgetCameraDates: [UUID: Date] = [:]
    @Published private(set) var widgetCameraMessages: [UUID: String] = [:]
    @Published private(set) var widgetCameraConsecutiveFailures: [UUID: Int] = [:]
    @Published var cameraSetup: CameraSetupRequest?
    var isDemo: Bool { dependencies.isDemo }

    func discoverCameras(for id: UUID) async throws -> [PrinterCameraChoice] {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw PrinterCameraError.unavailable }
        let choices = try await dependencies.discoverCameras(profile)
        try Task.checkCancellation()
        guard profiles.first(where: { $0.id == id }) == profile else {
            throw PrinterError.configuration("The printer connection changed. Reopen camera setup and try again.")
        }
        return choices
    }

    func testCameraSource(for id: UUID, streamURL: String, discoveredCameraID: String? = nil) async throws -> WidgetCameraSnapshot {
        guard var profile = profiles.first(where: { $0.id == id }) else { throw PrinterCameraError.unavailable }
        let original = profile
        let address = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty { _ = try PrinterCameraSource.validatedHTTPURL(address) }
        if address == (profile.camera?.streamURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
           discoveredCameraID == profile.camera?.discoveredCameraID,
           profile.camera?.enabled == true || profile.camera?.widgetSnapshotsEnabled == true {
            let session = cameraSession(for: id)
            if session.failed { session.retry() }
            return try await session.captureWidgetSnapshot(profile: profile)
        }
        var camera = profile.camera ?? PrinterCameraSettings()
        camera.streamURL = address; camera.discoveredCameraID = address.isEmpty ? discoveredCameraID : nil; profile.camera = camera
        let probe = CameraPreviewModel(resolve: dependencies.cameraSource) { [weak self] fingerprint in
            guard let self, let current = self.profiles.first(where: { $0.id == id }),
                  current.address == original.address, current.credential == original.credential else { throw CancellationError() }
            if let pin = current.camera?.certificateFingerprint, pin != fingerprint { throw PrinterCameraError.certificateChanged }
            var updated = self.profiles
            guard let index = updated.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            var settings = updated[index].camera ?? PrinterCameraSettings()
            settings.certificateFingerprint = fingerprint; updated[index].camera = settings
            try self.dependencies.saveProfiles(updated)
            self.profiles = updated
        }
        defer { probe.stop() }
        return try await probe.captureWidgetSnapshot(profile: profile)
    }

    func configureCamera(for id: UUID, streamURL: String, widgetSnapshots: Bool, discoveredCameraID: String? = nil) throws {
        guard var profile = profiles.first(where: { $0.id == id }) else { throw PrinterCameraError.unavailable }
        let address = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty { _ = try PrinterCameraSource.validatedHTTPURL(address) }
        var camera = profile.camera ?? PrinterCameraSettings()
        if widgetSnapshots && camera.widgetSnapshotsEnabled != true { camera.widgetSnapshotGeneration = UUID() }
        camera.streamURL = address; camera.discoveredCameraID = address.isEmpty ? discoveredCameraID : nil
        camera.enabled = true; camera.widgetSnapshotsEnabled = widgetSnapshots
        profile.camera = camera
        try save(profile, snapshot: snapshots[id] ?? PrinterSnapshot(profile: profile))
        if widgetSnapshots { lastWidgetCameraAttempt[id] = nil; refreshWidgetCameraSnapshots() }
        else {
            widgetCameraTasks.removeValue(forKey: id)?.cancel(); widgetCameraGenerations[id] = nil
            widgetCameraDates[id] = nil; widgetCameraMessages[id] = nil
            widgetCameraConsecutiveFailures[id] = nil
            try dependencies.deleteCameraSnapshot(id)
            try dependencies.deleteCameraStatus(id)
        }
        updateWidgetCameraPolling()
    }

    func cameraSession(for id: UUID) -> CameraPreviewModel {
        if let session = cameraSessions[id] { return session }
        let session = CameraPreviewModel(resolve: dependencies.cameraSource, loadSnapshot: dependencies.loadCameraSnapshot) { [weak self] fingerprint in
            guard let self, let profile = self.profiles.first(where: { $0.id == id }),
                  profile.camera?.enabled == true || profile.camera?.widgetSnapshotsEnabled == true else {
                throw CancellationError()
            }
            if profile.camera?.certificateFingerprint == fingerprint { return }
            var updated = self.profiles
            guard let index = updated.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            var camera = updated[index].camera ?? PrinterCameraSettings()
            camera.certificateFingerprint = fingerprint; updated[index].camera = camera
            try self.dependencies.saveProfiles(updated)
            self.profiles = updated
        }
        cameraSessions[id] = session
        return session
    }

    func setCameraEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var updated = profiles
        var camera = updated[index].camera ?? PrinterCameraSettings()
        camera.enabled = enabled; updated[index].camera = camera
        do {
            try dependencies.saveProfiles(updated)
            profiles = updated
            if !enabled && updated[index].camera?.widgetSnapshotsEnabled != true { cameraSessions[id]?.stop() }
        } catch { errorMessage = error.localizedDescription }
    }

    func setWidgetSnapshotsEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var updated = profiles
        var camera = updated[index].camera ?? PrinterCameraSettings()
        camera.widgetSnapshotsEnabled = enabled; updated[index].camera = camera
        if enabled { updated[index].camera?.widgetSnapshotGeneration = UUID() }
        do {
            try dependencies.saveProfiles(updated)
            profiles = updated
            defer { updateWidgetCameraPolling(); dependencies.reloadWidgets() }
            if enabled {
                lastWidgetCameraAttempt[id] = nil
                refreshWidgetCameraSnapshots()
            } else {
                widgetCameraTasks.removeValue(forKey: id)?.cancel()
                widgetCameraGenerations[id] = nil
                widgetCameraDates[id] = nil; widgetCameraMessages[id] = nil
                widgetCameraConsecutiveFailures[id] = nil
                lastWidgetCameraAttempt[id] = nil
                cameraSessions[id]?.releaseSnapshotWarmth()
                try dependencies.deleteCameraSnapshot(id)
                try dependencies.deleteCameraStatus(id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    static let captureIntervals: [TimeInterval] = [3, 5, 10, 15, 30, 60]
    @Published private(set) var widgetCaptureInterval: TimeInterval = 5

    func setCaptureInterval(_ interval: TimeInterval) {
        guard Self.captureIntervals.contains(interval), interval != widgetCaptureInterval else { return }
        do {
            if !isDemo { try dependencies.saveCaptureInterval(interval) }
            widgetCaptureInterval = interval
            widgetCameraPollTask?.cancel(); widgetCameraPollTask = nil
            updateWidgetCameraPolling()
        } catch { errorMessage = error.localizedDescription }
    }

    func effectiveCaptureInterval(for id: UUID, state: PrintState) -> TimeInterval {
        let failures = widgetCameraConsecutiveFailures[id] ?? 0
        if failures > 0 {
            switch failures {
            case 1: return max(widgetCaptureInterval, 15)
            case 2: return 30
            case 3: return 60
            default: return 120
            }
        }
        if state == .finished || state == .idle {
            return max(widgetCaptureInterval, 60)
        }
        return widgetCaptureInterval
    }

    /// Use the selected capture interval with or without a visible preview.
    /// A user refresh can capture sooner, and captures never overlap.
    private func refreshWidgetCameraSnapshots(forceFor ids: Set<UUID> = [], capturedAfter: Date? = nil) {
        updateWidgetCameraPolling()
        guard !isDemo else { return }
        for profile in profiles where profile.camera?.widgetSnapshotsEnabled == true {
            let id = profile.id
            let state = snapshots[id]?.state ?? .unknown
            let interval = effectiveCaptureInterval(for: id, state: state)
            guard widgetCameraTasks[id] == nil,
                  ids.contains(id) || dependencies.now().timeIntervalSince(lastWidgetCameraAttempt[id] ?? .distantPast) >= interval else { continue }
            let generation = UUID()
            widgetCameraGenerations[id] = generation
            lastWidgetCameraAttempt[id] = dependencies.now()
            widgetCameraMessages[id] = "Capturing widget snapshot…"
            widgetCameraTasks[id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.widgetCameraGenerations[id] == generation {
                        self.widgetCameraTasks[id] = nil
                        self.lastWidgetCameraAttempt[id] = self.dependencies.now()
                    }
                }
                do {
                    let capture = try await self.cameraSession(for: id).captureWidgetSnapshot(profile: profile,
                        capturedAfter: ids.contains(id) ? capturedAfter : nil)
                    try Task.checkCancellation()
                    guard self.widgetCameraGenerations[id] == generation else { return }
                    guard let current = self.profiles.first(where: { $0.id == id }), current.camera?.widgetSnapshotsEnabled == true,
                          current.address == profile.address, current.credential == profile.credential,
                          current.camera?.widgetSnapshotGeneration == capture.generation,
                          current.camera?.streamURL == profile.camera?.streamURL,
                          current.camera?.discoveredCameraID == profile.camera?.discoveredCameraID else { return }
                    try self.dependencies.saveCameraSnapshot(capture)
                    let status = WidgetCameraStatus(printerID: id, isUnavailable: false, message: nil, updatedAt: self.dependencies.now())
                    try? self.dependencies.saveCameraStatus(status)
                    self.widgetCameraConsecutiveFailures[id] = 0
                    self.widgetCameraDates[id] = capture.capturedAt
                    self.widgetCameraMessages[id] = nil
                    self.dependencies.reloadWidgets()
                } catch is CancellationError { }
                catch {
                    guard self.widgetCameraGenerations[id] == generation else { return }
                    self.widgetCameraConsecutiveFailures[id, default: 0] += 1
                    let isFinished = state == .finished
                    let msg = isFinished
                        ? "Snapshot unavailable. Print finished; camera tunnel closed."
                        : "Snapshot unavailable. The widget will keep its last dated picture."
                    self.widgetCameraMessages[id] = msg
                    let statusMsg = isFinished ? "Print finished" : "Camera offline"
                    let status = WidgetCameraStatus(printerID: id, isUnavailable: true, message: statusMsg, updatedAt: self.dependencies.now())
                    try? self.dependencies.saveCameraStatus(status)
                    self.dependencies.reloadWidgets()
                }
            }
        }
    }

    func refreshFromWidget(_ request: WidgetRefreshRequest) async {
        guard !isDemo, !isRefreshingFromWidget else { return }
        let selected = profiles.filter { request.printerIDs.isEmpty || request.printerIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let cameraIDs = Set(selected.filter { $0.camera?.widgetSnapshotsEnabled == true
            && (request.printerIDs.isEmpty || request.cameraIDs.contains($0.id)) }.map(\.id))
        let target = WidgetRefreshRequest(printerIDs: Set(selected.map(\.id)), cameraIDs: cameraIDs)
        let startedAt = dependencies.now()
        isRefreshingFromWidget = true
        defer { isRefreshingFromWidget = false }
        func feedback(_ phase: WidgetRefreshFeedback.Phase) {
            do { try dependencies.saveWidgetRefreshFeedback(.init(request: target, phase: phase, updatedAt: dependencies.now())) }
            catch { errorMessage = error.localizedDescription }
            dependencies.reloadWidgets()
        }
        feedback(.refreshing)
        async let statusRefresh: Void = refresh()
        // Reuse an in-flight capture only if it delivers a frame after this tap.
        // Otherwise start one new bounded capture, even inside the background cadence.
        for id in cameraIDs { if let task = widgetCameraTasks[id] { await task.value } }
        let needed = cameraIDs.filter { (widgetCameraDates[$0] ?? .distantPast) < startedAt }
        refreshWidgetCameraSnapshots(forceFor: needed, capturedAfter: startedAt)
        for id in needed { if let task = widgetCameraTasks[id] { await task.value } }
        await statusRefresh
        let deadline = Date().addingTimeInterval(20)
        while isRefreshing && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var succeeded = !Task.isCancelled
        for original in selected {
            guard let current = profiles.first(where: { $0.id == original.id }),
                  current.address == original.address, current.credential == original.credential,
                  let snapshot = snapshots[original.id], !snapshot.isOffline, snapshot.updatedAt >= startedAt else {
                succeeded = false; continue
            }
            do { try dependencies.saveSnapshot(snapshot); lastPersisted[original.id] = dependencies.now() }
            catch { errorMessage = error.localizedDescription; succeeded = false }
            if cameraIDs.contains(original.id), current.camera?.widgetSnapshotsEnabled != true
                || current.camera?.widgetSnapshotGeneration != original.camera?.widgetSnapshotGeneration
                || current.camera?.streamURL != original.camera?.streamURL
                || current.camera?.discoveredCameraID != original.camera?.discoveredCameraID
                || (widgetCameraDates[original.id] ?? .distantPast) < startedAt {
                succeeded = false
            }
        }
        feedback(succeeded ? .succeeded : .failed)
    }

    private func updateWidgetCameraPolling() {
        guard dependencies.autoStart, pollTask != nil, !isDemo,
              profiles.contains(where: { $0.camera?.widgetSnapshotsEnabled == true }) else {
            widgetCameraPollGeneration = UUID()
            widgetCameraPollTask?.cancel(); widgetCameraPollTask = nil
            return
        }
        guard widgetCameraPollTask == nil else { return }
        let generation = UUID(); widgetCameraPollGeneration = generation
        widgetCameraPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.widgetCameraPollGeneration == generation else { return }
                self.refreshWidgetCameraSnapshots()
                let now = self.dependencies.now()
                let next = self.profiles.filter { $0.camera?.widgetSnapshotsEnabled == true }
                    .compactMap { profile in
                        let attempt = self.lastWidgetCameraAttempt[profile.id] ?? .distantPast
                        let state = self.snapshots[profile.id]?.state ?? .unknown
                        let interval = self.effectiveCaptureInterval(for: profile.id, state: state)
                        return attempt.addingTimeInterval(interval)
                    }.min() ?? now.addingTimeInterval(5)
                let delay = min(30, max(0.5, next.timeIntervalSince(now)))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    init(dependencies: ProgressStoreDependencies = .live) {
        self.dependencies = dependencies
        do {
            profiles = try dependencies.loadProfiles()
            let savedInterval = try dependencies.loadCaptureInterval()
            widgetCaptureInterval = Self.captureIntervals.contains(savedInterval) ? savedInterval : 5
            printingActivity = try dependencies.loadActivity()
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
            for profile in profiles where profile.camera?.widgetSnapshotsEnabled == true {
                if let image = try dependencies.loadCameraSnapshot(profile.id), image.generation == profile.camera?.widgetSnapshotGeneration {
                    widgetCameraDates[profile.id] = image.capturedAt
                }
                if let status = try? dependencies.loadCameraStatus(profile.id), status.isUnavailable {
                    widgetCameraMessages[profile.id] = status.message
                }
            }
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
        updateWidgetCameraPolling()
    }
    func stop() {
        widgetCameraPollGeneration = UUID()
        widgetCameraPollTask?.cancel(); widgetCameraPollTask = nil
        for task in widgetCameraTasks.values { task.cancel() }
        widgetCameraTasks = [:]
        widgetCameraGenerations = [:]
        for camera in cameraSessions.values { camera.stop() }
        pollTask?.cancel(); pollTask = nil
        for task in controlTasks.values { task.cancel() }
    }

    func commandEnabled(_ command: PrinterCommand, snapshot: PrinterSnapshot) -> Bool {
        guard pendingControls[snapshot.id] == nil else { return false }
        var snapshot = snapshot
        if isDemo { snapshot.updatedAt = dependencies.now() }
        return (try? PrinterControl.validate(command, snapshot: snapshot, now: dependencies.now())) != nil
    }

    func stopFromWidget(_ context: WidgetControlContext) async throws {
        guard !isDemo, let profile = profiles.first(where: { $0.id == context.snapshot.id }) else {
            throw PrinterControlError.jobChanged
        }
        try context.validate(profile: profile, now: dependencies.now())
        let current = try await dependencies.fetch(profile)
        try PrinterControl.validateSameJob(.stop, expected: context.snapshot, current: current, now: dependencies.now())
        guard profiles.first(where: { $0.id == profile.id }) == profile else { throw PrinterControlError.jobChanged }
        try await control(.stop, expected: current, expectedProfile: profile).get()
    }

    @discardableResult
    func control(_ command: PrinterCommand, expected: PrinterSnapshot, expectedProfile: PrinterProfile? = nil) async -> Result<Void, Error> {
        let id = expected.id
        guard pendingControls[id] == nil else { return .failure(PrinterControlError.busy) }
        guard let profile = profiles.first(where: { $0.id == id }) else { return .failure(PrinterControlError.jobChanged) }
        if let expectedProfile, expectedProfile != profile {
            controlMessages[id] = PrinterControlError.jobChanged.localizedDescription
            return .failure(PrinterControlError.jobChanged)
        }
        do {
            var validated = expected
            if isDemo { validated.updatedAt = dependencies.now() }
            try PrinterControl.validate(command, snapshot: validated, now: dependencies.now())
        } catch { controlMessages[id] = error.localizedDescription; return .failure(error) }
        if isDemo {
            snapshots[id]?.state = command == .pause ? .paused : command == .resume ? .printing : .cancelled
            if command == .stop { snapshots[id]?.remainingSeconds = nil }
            snapshots[id]?.updatedAt = dependencies.now()
            controlMessages[id] = "Demo only. No command sent."
            return .success(())
        }
        generations[id, default: 0] += 1
        let generation = generations[id]
        pendingControls[id] = PendingControl(command: command)
        controlMessages[id] = "Sending \(command.title.lowercased())…"
        let send = dependencies.control
        let task = Task { try await send(command, profile, expected) }
        controlTasks[id] = task
        var outcome: Result<Void, Error> = .success(())
        do {
            try await task.value
            guard profiles.contains(profile), generations[id] == generation else { return .failure(PrinterControlError.jobChanged) }
            pendingControls[id]?.confirmationDeadline = dependencies.now().addingTimeInterval(30)
            controlMessages[id] = "Requested. Waiting for printer status…"
        } catch {
            guard profiles.contains(profile), generations[id] == generation else { return .failure(PrinterControlError.jobChanged) }
            outcome = .failure(error)
            if error as? PrinterControlError == .unconfirmed {
                pendingControls[id]?.confirmationDeadline = dependencies.now().addingTimeInterval(30)
            } else { pendingControls[id] = nil }
            controlMessages[id] = error.localizedDescription
        }
        controlTasks[id] = nil
        await refresh()
        return outcome
    }

    func refresh() async {
        if isDemo {
            for id in snapshots.keys { snapshots[id]?.updatedAt = dependencies.now() }
            return
        }
        guard !isRefreshing, !profiles.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let current = profiles
        refreshWidgetCameraSnapshots()
        let refreshGenerations = generations
        let fetch = dependencies.fetch
        await withTaskGroup(of: (UUID, Result<PrinterSnapshot, Error>).self) { group in
            for profile in current {
                if let pending = pendingControls[profile.id], pending.confirmationDeadline == nil { continue }
                group.addTask {
                    do { return (profile.id, .success(try await fetch(profile))) }
                    catch { return (profile.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard let profile = profiles.first(where: { $0.id == id }),
                      current.first(where: { $0.id == id }) == profile,
                      refreshGenerations[id] == generations[id] else { continue }
                switch result {
                case .success(let snapshot):
                    let previous = snapshots[id]
                    if dependencies.verificationReports && (previous == nil || previous?.isOffline == true) {
                        connectionLog.notice("Printer connection restored (\(profile.kind.rawValue, privacy: .public)).")
                    }
                    snapshots[id] = snapshot
                    // Only verified printing activity affects ordering; reconnecting
                    // or repeatedly polling an idle printer must not promote it.
                    if !snapshot.isOffline && ((snapshot.state.isActive && (printingActivity[id] == nil ||
                         previous?.state != snapshot.state || previous?.jobIdentifier != snapshot.jobIdentifier)) ||
                        (previous?.state.isActive == true && previous?.state != snapshot.state)) {
                        printingActivity[id] = snapshot.updatedAt
                        do { try dependencies.saveActivity(printingActivity) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    if let pending = pendingControls[id], let deadline = pending.confirmationDeadline {
                        let confirmed: Bool
                        switch pending.command {
                        case .pause: confirmed = snapshot.state == .paused
                        case .resume: confirmed = snapshot.state == .printing
                        case .stop: confirmed = [.idle, .cancelled, .stopped, .finished, .failed].contains(snapshot.state)
                        }
                        if confirmed && !snapshot.isOffline {
                            pendingControls[id] = nil
                            controlMessages[id] = "Printer reports: \(snapshot.statusTitle.lowercased())."
                        } else if dependencies.now() >= deadline {
                            pendingControls[id] = nil
                            controlMessages[id] = PrinterControlError.unconfirmed.localizedDescription
                        }
                    }
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
                    let previous = snapshots[id]
                    let failed = (previous ?? PrinterSnapshot(profile: profile, updatedAt: .distantPast)).offline(error)
                    if dependencies.verificationReports && (previous?.isOffline != true || previous?.connectionIssue != failed.connectionIssue) {
                        connectionLog.notice("Printer connection unavailable (\(profile.kind.rawValue, privacy: .public)): \(failed.connectionIssue?.rawValue ?? "connectionFailed", privacy: .public).")
                    }
                    snapshots[id] = failed
                    if let deadline = pendingControls[id]?.confirmationDeadline, dependencies.now() >= deadline {
                        pendingControls[id] = nil
                        controlMessages[id] = PrinterControlError.unconfirmed.localizedDescription
                    }
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
        let previous = profiles.first(where: { $0.id == profile.id })
        let cameraChanged = previous.map { $0.address != profile.address || $0.credential != profile.credential || $0.camera?.streamURL != profile.camera?.streamURL || $0.camera?.discoveredCameraID != profile.camera?.discoveredCameraID } ?? false
        if cameraChanged, profile.camera?.widgetSnapshotsEnabled == true { profile.camera?.widgetSnapshotGeneration = UUID() }
        profile.certificateFingerprint = snapshot.certificateFingerprint ?? profile.certificateFingerprint
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        try dependencies.saveProfiles(updated)
        if cameraChanged {
            widgetCameraTasks.removeValue(forKey: profile.id)?.cancel()
            widgetCameraGenerations[profile.id] = nil
            cameraSessions.removeValue(forKey: profile.id)?.stop()
            widgetCameraDates[profile.id] = nil; lastWidgetCameraAttempt[profile.id] = nil
            widgetCameraConsecutiveFailures[profile.id] = nil
            do {
                try dependencies.deleteCameraSnapshot(profile.id)
                try dependencies.deleteCameraStatus(profile.id)
            } catch { errorMessage = error.localizedDescription }
        }
        invalidateControl(profile.id)
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
        invalidateControl(profile.id)
        profiles = updated; snapshots[profile.id] = nil
        widgetCameraTasks.removeValue(forKey: profile.id)?.cancel()
        widgetCameraGenerations[profile.id] = nil
        widgetCameraDates[profile.id] = nil; widgetCameraMessages[profile.id] = nil; lastWidgetCameraAttempt[profile.id] = nil
        widgetCameraConsecutiveFailures[profile.id] = nil
        do {
            try dependencies.deleteCameraSnapshot(profile.id)
            try dependencies.deleteCameraStatus(profile.id)
        } catch { errorMessage = error.localizedDescription }
        cameraSessions.removeValue(forKey: profile.id)?.stop()
        lastPersisted[profile.id] = nil
        // An orphaned cache is never displayed without its saved profile.
        do { try dependencies.deleteSnapshot(profile.id) }
        catch { errorMessage = error.localizedDescription }
        dependencies.reloadWidgets()
    }
    var activePrinter: PrinterSnapshot? {
        profiles.compactMap { snapshots[$0.id] }.first { !$0.isOffline && $0.state.isActive }
    }

    private func invalidateControl(_ id: UUID) {
        controlTasks[id]?.cancel(); controlTasks[id] = nil
        pendingControls[id] = nil; controlMessages[id] = nil
        generations[id, default: 0] += 1
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
            let cameraEnabled: Bool
            let widgetCameraEnabled: Bool
            let cameraFrames: Int
            let cameraViewers: Int
            let cameraLastFrameAt: Date?
            let widgetCameraCapturedAt: Date?
            let cameraFailed: Bool
            let sandboxContainerActive: Bool
        }
        let readings = profiles.compactMap { profile -> Reading? in
            guard let snapshot = snapshots[profile.id] else { return nil }
            return Reading(kind: profile.kind, state: snapshot.state, progress: snapshot.progress,
                           online: !snapshot.isOffline, updatedAt: snapshot.updatedAt, error: snapshot.errorMessage,
                           chamberTemperature: snapshot.chamberTemperature, chamberTarget: snapshot.chamberTarget,
                           printerErrorCode: snapshot.printerErrorCode,
                           cameraEnabled: profile.camera?.enabled == true,
                           widgetCameraEnabled: profile.camera?.widgetSnapshotsEnabled == true,
                           cameraFrames: cameraSessions[profile.id]?.receivedFrameCount ?? 0,
                           cameraViewers: cameraSessions[profile.id]?.activeViewerCount ?? 0,
                           cameraLastFrameAt: cameraSessions[profile.id]?.lastReceivedFrameAt,
                           widgetCameraCapturedAt: widgetCameraDates[profile.id],
                           cameraFailed: cameraSessions[profile.id]?.failed ?? false,
                           sandboxContainerActive: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
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
        if let verification = try? SharedVault.read(WidgetCameraVerification.self, account: "widget-camera-verification"),
           let data = try? encoder.encode(verification) {
            try? data.write(to: cache.appendingPathComponent("PrintProgress-widget-camera-verification.json"), options: .atomic)
        }
    }
    #endif
}
