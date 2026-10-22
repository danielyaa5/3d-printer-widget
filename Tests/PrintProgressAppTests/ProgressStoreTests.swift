import XCTest

@MainActor
final class ProgressStoreTests: XCTestCase {
    private let printer = PrinterProfile(name: "Fixture", kind: .octoPrint, address: "http://printer.local")
    private var saved: [PrinterProfile] = []
    private var cache: [UUID: PrinterSnapshot] = [:]
    private var writes = 0
    private var reloads = 0
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func dependencies(fetch: @escaping @Sendable (PrinterProfile) async throws -> PrinterSnapshot) -> ProgressStoreDependencies {
        .init(loadProfiles: { self.saved }, loadSnapshot: { self.cache[$0] },
              saveProfiles: { self.saved = $0 },
              saveSnapshot: { self.cache[$0.id] = $0; self.writes += 1 },
              deleteSnapshot: { self.cache[$0] = nil }, fetch: fetch,
              reloadWidgets: { self.reloads += 1 }, now: { self.clock },
              autoStart: false, verificationReports: false)
    }

    func testSavedProfilesAndActualCachedTimestampsLoad() {
        saved = [printer]
        let old = PrinterSnapshot(profile: printer, state: .printing, progress: 0.4, updatedAt: clock)
        cache[printer.id] = old
        let store = ProgressStore(dependencies: dependencies { PrinterSnapshot(profile: $0) })
        XCTAssertEqual(store.profiles, [printer])
        XCTAssertEqual(store.snapshots[printer.id], old)
        XCTAssertEqual(writes, 0)
    }

    func testCameraTogglePersistsPerPrinterAndDefaultsOff() throws {
        let second = PrinterProfile(name: "Second", kind: .moonraker, address: "http://second.invalid")
        saved = [printer, second]
        let store = ProgressStore(dependencies: dependencies { PrinterSnapshot(profile: $0) })
        XCTAssertNil(store.profiles[0].camera)
        store.setCameraEnabled(true, for: printer.id)
        XCTAssertEqual(saved[0].camera?.enabled, true)
        XCTAssertNil(saved[1].camera)
        XCTAssertTrue(store.cameraSession(for: printer.id) === store.cameraSession(for: printer.id))
        store.setCameraEnabled(false, for: printer.id)
        XCTAssertEqual(saved[0].camera?.enabled, false)
        XCTAssertEqual(writes, 0, "Camera settings must not overwrite status timestamps")
    }

    func testCameraToggleKeychainFailureDoesNotEnableCamera() {
        saved = [printer]
        var deps = dependencies { PrinterSnapshot(profile: $0) }
        deps.saveProfiles = { _ in throw PrinterError.keychain(-25308) }
        let store = ProgressStore(dependencies: deps)
        store.setCameraEnabled(true, for: printer.id)
        XCTAssertNil(store.profiles[0].camera)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLockedKeychainShowsErrorWithoutPlaintextFallback() {
        var deps = dependencies { PrinterSnapshot(profile: $0) }
        deps.loadProfiles = { throw PrinterError.keychain(-25308) }
        let store = ProgressStore(dependencies: deps)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(writes, 0)
    }

    func testSaveEditAndRemoveArePersistedAndReloadWidgets() throws {
        let store = ProgressStore(dependencies: dependencies { PrinterSnapshot(profile: $0) })
        try store.save(printer, snapshot: PrinterSnapshot(profile: printer, state: .printing))
        var edited = printer; edited.name = "Renamed"
        try store.save(edited, snapshot: PrinterSnapshot(profile: edited, state: .paused))
        XCTAssertEqual(saved, [edited])
        XCTAssertEqual(store.profiles, [edited])
        XCTAssertEqual(store.snapshots[printer.id]?.name, "Renamed")
        try store.remove(edited)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(cache[printer.id])
        XCTAssertNil(store.snapshots[printer.id])
        XCTAssertEqual(reloads, 3)
    }

    func testProfileWriteFailureDoesNotPretendPrinterWasSaved() {
        var deps = dependencies { PrinterSnapshot(profile: $0) }
        deps.saveProfiles = { _ in throw PrinterError.keychain(-25308) }
        let store = ProgressStore(dependencies: deps)
        XCTAssertThrowsError(try store.save(printer, snapshot: PrinterSnapshot(profile: printer)))
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(reloads, 0)
    }

    func testCacheWriteFailureKeepsUIConsistentWithCommittedProfileAndReportsError() throws {
        var deps = dependencies { PrinterSnapshot(profile: $0) }
        deps.saveSnapshot = { _ in throw PrinterError.keychain(-25308) }
        let store = ProgressStore(dependencies: deps)
        try store.save(printer, snapshot: PrinterSnapshot(profile: printer))
        XCTAssertEqual(saved, [printer])
        XCTAssertEqual(store.profiles, saved)
        XCTAssertNotNil(store.errorMessage)
    }

    func testCacheDeletionFailureDoesNotResurrectRemovedProfile() throws {
        saved = [printer]
        var deps = dependencies { PrinterSnapshot(profile: $0) }
        deps.deleteSnapshot = { _ in throw PrinterError.keychain(-25308) }
        let store = ProgressStore(dependencies: deps)
        try store.remove(printer)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testOfflineRefreshKeepsLastObservedReadingAndRecovers() async {
        saved = [printer]
        let response = ResponseQueue()
        await response.append(.success(PrinterSnapshot(profile: printer, state: .printing, progress: 0.4, updatedAt: clock)))
        await response.append(.failure(PrinterError.timeout))
        await response.append(.success(PrinterSnapshot(profile: printer, state: .printing, progress: 0.5, updatedAt: clock.addingTimeInterval(30))))
        let store = ProgressStore(dependencies: dependencies { _ in try await response.next() })
        await store.refresh()
        let original = store.snapshots[printer.id]
        await store.refresh()
        XCTAssertEqual(store.snapshots[printer.id]?.updatedAt, original?.updatedAt)
        XCTAssertEqual(store.snapshots[printer.id]?.progress, 0.4)
        XCTAssertEqual(store.snapshots[printer.id]?.statusTitle, "Offline")
        XCTAssertNil(store.snapshots[printer.id]?.finishDate)
        await store.refresh()
        XCTAssertEqual(store.snapshots[printer.id]?.progress, 0.5)
        XCTAssertEqual(store.snapshots[printer.id]?.isOffline, false)
        XCTAssertNil(store.snapshots[printer.id]?.errorMessage)
        XCTAssertEqual(writes, 3)
    }

    func testStablePollingThrottlesCacheAndWidgetReloadsButStateChangesPersistImmediately() async {
        saved = [printer]
        let response = ResponseQueue()
        for state in [PrintState.printing, .printing, .paused, .paused] {
            await response.append(.success(PrinterSnapshot(profile: printer, state: state)))
        }
        let store = ProgressStore(dependencies: dependencies { _ in try await response.next() })
        await store.refresh()
        clock += 15
        await store.refresh()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reloads, 1)
        await store.refresh()
        XCTAssertEqual(writes, 2)
        clock += 61
        await store.refresh()
        XCTAssertEqual(writes, 3)
        XCTAssertEqual(reloads, 2)
    }

    func testCancellationDoesNotMarkPrinterOffline() async {
        saved = [printer]
        cache[printer.id] = PrinterSnapshot(profile: printer, state: .printing, updatedAt: clock)
        let original = cache[printer.id]
        let store = ProgressStore(dependencies: dependencies { _ in throw CancellationError() })
        await store.refresh()
        XCTAssertEqual(store.snapshots[printer.id], original)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(writes, 0)
    }

    func testConcurrentRefreshesAreCoalesced() async {
        saved = [printer]
        let gate = FetchGate()
        let store = ProgressStore(dependencies: dependencies { profile in try await gate.fetch(profile) })
        let first = Task { await store.refresh() }
        await gate.waitUntilStarted()
        XCTAssertTrue(store.isRefreshing)
        await store.refresh()
        await gate.finish()
        await first.value
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testRemovingPrinterDuringRefreshDiscardsLateResponse() async throws {
        saved = [printer]
        let gate = FetchGate()
        let store = ProgressStore(dependencies: dependencies { try await gate.fetch($0) })
        let refresh = Task { await store.refresh() }
        await gate.waitUntilStarted()
        try store.remove(printer)
        await gate.finish()
        await refresh.value
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.snapshots[printer.id])
        XCTAssertNil(cache[printer.id])
    }

    func testEditingConnectionDuringRefreshDiscardsOldEndpointResponse() async throws {
        saved = [printer]
        let gate = FetchGate()
        let store = ProgressStore(dependencies: dependencies { try await gate.fetch($0) })
        let refresh = Task { await store.refresh() }
        await gate.waitUntilStarted()
        var edited = printer; edited.address = "http://replacement.local"
        let newReading = PrinterSnapshot(profile: edited, state: .paused, progress: 0.8)
        try store.save(edited, snapshot: newReading)
        await gate.finish()
        await refresh.value
        XCTAssertEqual(store.snapshots[printer.id], newReading)
        XCTAssertEqual(saved, [edited])
    }

    func testCertificatePinIsPersistedFromVerifiedConnection() async {
        saved = [printer]
        let store = ProgressStore(dependencies: dependencies { profile in
            PrinterSnapshot(profile: profile, certificateFingerprint: String(repeating: "a", count: 64))
        })
        await store.refresh()
        XCTAssertEqual(saved.first?.certificateFingerprint, String(repeating: "a", count: 64))
    }

    func testDemoRefreshNeverUsesNetworkOrPersistenceAndKeepsSelectedState() async {
        var deps = ProgressStoreDependencies.demo
        deps.fetch = { _ in XCTFail("Demo must not contact a printer"); throw PrinterError.timeout }
        deps.saveProfiles = { _ in XCTFail("Demo must not save profiles") }
        deps.saveSnapshot = { _ in XCTFail("Demo must not save readings") }
        deps.reloadWidgets = { XCTFail("Demo must not replace live widgets") }
        deps.now = { self.clock }
        let store = ProgressStore(dependencies: deps)
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.profiles.count, 2)
        store.setDemoState(.paused)
        await store.refresh()
        let reading = store.snapshots[DemoData.profiles[0].id]
        XCTAssertEqual(reading?.state, .paused)
        XCTAssertEqual(reading?.progress, 0.64)
        XCTAssertEqual(reading?.updatedAt, clock)
        XCTAssertNil(reading?.finishDate)
        store.setDemoState(.finished)
        XCTAssertEqual(store.snapshots[DemoData.profiles[0].id]?.progress, 1)
    }

    func testDemoStateCannotReplaceLiveProfiles() {
        saved = [printer]
        cache[printer.id] = PrinterSnapshot(profile: printer, state: .paused)
        let store = ProgressStore(dependencies: dependencies { PrinterSnapshot(profile: $0) })
        let original = store.snapshots
        store.setDemoState(.finished)
        XCTAssertEqual(store.profiles, [printer])
        XCTAssertEqual(store.snapshots, original)
    }

    func testFailedPinWriteDoesNotPretendPinWasCommitted() async {
        saved = [printer]
        var deps = dependencies { profile in
            PrinterSnapshot(profile: profile, certificateFingerprint: String(repeating: "a", count: 64))
        }
        deps.saveProfiles = { _ in throw PrinterError.keychain(-25308) }
        let store = ProgressStore(dependencies: deps)
        await store.refresh()
        XCTAssertNil(store.profiles.first?.certificateFingerprint)
        XCTAssertNil(saved.first?.certificateFingerprint)
        XCTAssertNotNil(store.errorMessage)
    }
}

private actor ResponseQueue {
    var responses: [Result<PrinterSnapshot, Error>] = []
    func append(_ response: Result<PrinterSnapshot, Error>) { responses.append(response) }
    func next() throws -> PrinterSnapshot { try responses.removeFirst().get() }
}

private actor FetchGate {
    var calls = 0
    var continuation: CheckedContinuation<PrinterSnapshot, Error>?
    var profile: PrinterProfile?
    func fetch(_ profile: PrinterProfile) async throws -> PrinterSnapshot {
        calls += 1; self.profile = profile
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish() {
        continuation?.resume(returning: PrinterSnapshot(profile: profile!, state: .printing, progress: 0.1))
        continuation = nil
    }
}
