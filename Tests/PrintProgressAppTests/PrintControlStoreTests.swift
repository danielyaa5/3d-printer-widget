import XCTest

@MainActor
final class PrintControlStoreTests: XCTestCase {
    let profile = PrinterProfile(name: "Workshop", kind: .moonraker, address: "http://printer.local")
    var now = Date()
    private func reading(_ state: PrintState = .printing) -> PrinterSnapshot {
        PrinterSnapshot(profile: profile, state: state, progress: 0.4, jobName: "Planter", updatedAt: now, jobIdentifier: "fixture.gcode")
    }
    private func store(_ backend: ControlBackend) -> ProgressStore {
        let initial = reading()
        return ProgressStore(dependencies: .init(loadProfiles: { [self.profile] }, loadSnapshot: { _ in initial },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { _ in await backend.reading }, reloadWidgets: {}, now: { self.now }, autoStart: false,
            verificationReports: false, control: { command, _, _ in try await backend.send(command) }))
    }

    func testAnAcceptedCommandDoesNotInventPausedStatusOrAllowDuplicates() async throws {
        let backend = ControlBackend(reading())
        let model = store(backend)
        let expected = try XCTUnwrap(model.snapshots[profile.id])
        await model.control(.pause, expected: expected)
        XCTAssertEqual(model.snapshots[profile.id]?.state, .printing)
        XCTAssertNotNil(model.pendingControls[profile.id])
        await model.control(.pause, expected: expected)
        let count = await backend.commands.count
        XCTAssertEqual(count, 1)
        await backend.report(reading(.paused))
        await model.refresh()
        XCTAssertEqual(model.snapshots[profile.id]?.state, .paused)
        XCTAssertNil(model.pendingControls[profile.id])
        XCTAssertTrue(model.commandEnabled(.resume, snapshot: model.snapshots[profile.id]!))
    }

    func testPendingCommandExpiresWithoutAutomaticResend() async {
        let backend = ControlBackend(reading())
        let active = store(backend)
        await active.control(.pause, expected: reading())
        now += 31
        await active.refresh()
        XCTAssertNil(active.pendingControls[profile.id])
        let count = await backend.commands.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(active.controlMessages[profile.id], PrinterControlError.unconfirmed.localizedDescription)
    }

    func testRejectionKeepsTheActualStateAndMakesTheFailureVisible() async {
        let backend = ControlBackend(reading()); await backend.fail(.rejected)
        let model = store(backend)
        await model.control(.pause, expected: reading())
        XCTAssertEqual(model.snapshots[profile.id]?.state, .printing)
        XCTAssertNil(model.pendingControls[profile.id])
        XCTAssertEqual(model.controlMessages[profile.id], PrinterControlError.rejected.localizedDescription)
    }

    func testRemovingOrEditingPrinterCancelsItsPendingCommand() async throws {
        for edit in [false, true] {
            let backend = ControlBackend(reading()); await backend.hold()
            let model = store(backend)
            let action = Task { await model.control(.pause, expected: reading()) }
            await backend.waitUntilStarted()
            if edit {
                var replacement = profile; replacement.address = "http://replacement.local"
                try model.save(replacement, snapshot: reading(.paused))
            } else { try model.remove(profile) }
            await backend.release()
            await action.value
            XCTAssertNil(model.pendingControls[profile.id])
            XCTAssertNil(model.controlMessages[profile.id])
            XCTAssertEqual(model.snapshots[profile.id]?.state, edit ? .paused : nil)
        }
    }

    func testDemoControlsOnlyChangeTheSelectedFictionalPrinter() async throws {
        var deps = ProgressStoreDependencies.demo
        deps.control = { _, _, _ in XCTFail("Demo sent a live control") }
        deps.fetch = { _ in XCTFail("Demo made a network request"); throw PrinterError.invalidResponse }
        deps.saveSnapshot = { _ in XCTFail("Demo changed shared widgets") }
        let model = ProgressStore(dependencies: deps)
        let first = DemoData.profiles[0].id, second = DemoData.profiles[1].id
        await model.control(.pause, expected: try XCTUnwrap(model.snapshots[first]))
        XCTAssertEqual(model.snapshots[first]?.state, .paused)
        XCTAssertEqual(model.snapshots[second]?.state, .printing)
        await model.control(.resume, expected: try XCTUnwrap(model.snapshots[first]))
        XCTAssertEqual(model.snapshots[first]?.state, .printing)
        await model.control(.stop, expected: try XCTUnwrap(model.snapshots[first]))
        XCTAssertEqual(model.snapshots[first]?.state, .cancelled)
        XCTAssertNil(model.snapshots[first]?.remainingSeconds)
        XCTAssertEqual(model.snapshots[second]?.state, .printing)
    }

    func testWidgetStopRechecksTheDisplayedJobBeforeSending() async throws {
        let backend = ControlBackend(reading())
        let model = store(backend)
        let context = try WidgetControlContext(profile: profile, snapshot: reading())
        try await model.stopFromWidget(context)
        let commands = await backend.commands
        XCTAssertEqual(commands, [.stop])
    }

    func testWidgetStopKeepsRejectionAndUncertainOutcomeVisibleToConfirmation() async throws {
        for failure in [PrinterControlError.rejected, .unconfirmed, .pairingRequired] {
            let backend = ControlBackend(reading())
            await backend.fail(failure)
            let model = store(backend)
            let context = try WidgetControlContext(profile: profile, snapshot: reading())
            do {
                try await model.stopFromWidget(context)
                XCTFail("Stop confirmation must not dismiss after a failed command")
            } catch { XCTAssertEqual(error as? PrinterControlError, failure) }
            XCTAssertEqual(model.snapshots[profile.id]?.state, .printing)
            let commands = await backend.commands
            XCTAssertEqual(commands, [.stop], "An uncertain command must not be retried")
        }
    }

    func testWidgetStopRejectsReplacedJobAndEditedConnection() async throws {
        for editConnection in [false, true] {
            let backend = ControlBackend(reading())
            let model = store(backend)
            let context = try WidgetControlContext(profile: profile, snapshot: reading())
            if editConnection {
                var edited = profile; edited.address = "http://replacement.invalid"
                try model.save(edited, snapshot: reading())
            } else {
                var changed = reading(); changed.jobIdentifier = "new-job.gcode"
                await backend.report(changed)
            }
            do { try await model.stopFromWidget(context); XCTFail("Changed target accepted") }
            catch { XCTAssertEqual(error as? PrinterControlError, .jobChanged) }
            let commands = await backend.commands
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testConfirmationCannotTargetAConnectionEditedBeforeSending() async throws {
        let backend = ControlBackend(reading())
        let active = store(backend)
        var replacement = profile
        replacement.address = "http://replacement.local"
        try active.save(replacement, snapshot: reading())
        await active.control(.stop, expected: reading(), expectedProfile: profile)
        let count = await backend.commands.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(active.controlMessages[profile.id], PrinterControlError.jobChanged.localizedDescription)
    }
}

private actor ControlBackend {
    var reading: PrinterSnapshot
    var commands: [PrinterCommand] = []
    var failure: PrinterControlError?
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ reading: PrinterSnapshot) { self.reading = reading }
    func report(_ value: PrinterSnapshot) { reading = value }
    func fail(_ error: PrinterControlError) { failure = error }
    func hold() { held = true }
    func send(_ command: PrinterCommand) async throws {
        commands.append(command)
        if held { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        if let failure { throw failure }
    }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
