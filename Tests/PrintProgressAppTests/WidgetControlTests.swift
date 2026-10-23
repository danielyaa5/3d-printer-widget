import XCTest

final class WidgetControlTests: XCTestCase {
    private let profile = PrinterProfile(name: "Workshop", kind: .moonraker, address: "http://printer.invalid:7125")
    private func snapshot(_ state: PrintState = .printing, date: Date = .now) -> PrinterSnapshot {
        PrinterSnapshot(profile: profile, state: state, progress: 0.4, jobName: "Planter", updatedAt: date, jobIdentifier: "planter.gcode")
    }
    private func dependencies(_ backend: WidgetBackend) -> WidgetControlDependencies {
        .init(profiles: { backend.profiles }, fetch: { _ in try backend.fetch() },
              send: { command, _, _ in try backend.send(command) }, save: { backend.saved = $0 },
              feedback: { _ in backend.feedback }, report: { _, value in backend.feedback = value },
              claim: { try backend.claim($0) }, reload: { backend.reloads += 1 })
    }
    func testOldWidgetRechecksSameJobAndUsesActualReportedState() async throws {
        let displayed = snapshot(date: Date().addingTimeInterval(-600))
        let backend = WidgetBackend(profile: profile, current: snapshot())
        let context = try WidgetControlContext(profile: profile, snapshot: displayed)
        try await WidgetControlService().perform(.pause, context: context, dependencies: dependencies(backend))
        XCTAssertEqual(backend.commands, [.pause])
        XCTAssertEqual(backend.saved?.state, .paused)
        XCTAssertNil(backend.feedback?.blockedUntil)
        XCTAssertGreaterThanOrEqual(backend.reloads, 2)
    }
    func testReusedRenderedButtonCannotResend() async throws {
        let backend = WidgetBackend(profile: profile, current: snapshot())
        backend.changesStatus = false
        let context = try WidgetControlContext(profile: profile, snapshot: snapshot())
        let service = WidgetControlService()
        try await service.perform(.pause, context: context, dependencies: dependencies(backend))
        backend.feedback = nil
        do { try await service.perform(.pause, context: context, dependencies: dependencies(backend)); XCTFail("Reused button sent twice") }
        catch { XCTAssertEqual(error as? PrinterControlError, .busy) }
        XCTAssertEqual(backend.commands, [.pause])
        XCTAssertEqual(backend.saved?.state, .printing, "Acknowledgement must not invent paused state")
    }
    func testChangedConnectionAndChangedJobNeverSend() async throws {
        for connection in [false, true] {
            let backend = WidgetBackend(profile: profile, current: snapshot())
            if connection { backend.profiles[0].credential = "fictional-replacement-key" }
            else { backend.current.jobIdentifier = "other.gcode" }
            do {
                try await WidgetControlService().perform(.pause, context: WidgetControlContext(profile: profile, snapshot: snapshot()), dependencies: dependencies(backend))
                XCTFail("Changed target accepted")
            } catch { XCTAssertEqual(error as? PrinterControlError, .jobChanged) }
            XCTAssertTrue(backend.commands.isEmpty)
        }
    }
    func testExpiredAndOfflineWidgetCannotSend() async throws {
        for offline in [false, true] {
            let backend = WidgetBackend(profile: profile, current: snapshot())
            var displayed = snapshot(date: Date().addingTimeInterval(offline ? 0 : -1801))
            if offline { displayed = displayed.offline(PrinterError.timeout) }
            do {
                try await WidgetControlService().perform(.pause, context: WidgetControlContext(profile: profile, snapshot: displayed), dependencies: dependencies(backend))
                XCTFail("Stale widget accepted")
            } catch { XCTAssertEqual(error as? PrinterControlError, .refreshRequired) }
            XCTAssertTrue(backend.commands.isEmpty)
        }
    }
    func testStopCannotBypassAppConfirmationViaIntentService() async throws {
        let backend = WidgetBackend(profile: profile, current: snapshot())
        do {
            try await WidgetControlService().perform(.stop, context: WidgetControlContext(profile: profile, snapshot: snapshot()), dependencies: dependencies(backend))
            XCTFail("Background Stop accepted")
        } catch { XCTAssertEqual(error as? PrinterControlError, .rejected) }
        XCTAssertTrue(backend.commands.isEmpty)
    }
    func testMissingAcknowledgementOrStatusNeverAutomaticallyRetries() async throws {
        for failAfterSend in [false, true] {
            let backend = WidgetBackend(profile: profile, current: snapshot())
            backend.failAfterSend = failAfterSend
            backend.sendFailure = failAfterSend ? nil : .unconfirmed
            do {
                try await WidgetControlService().perform(.pause, context: WidgetControlContext(profile: profile, snapshot: snapshot()), dependencies: dependencies(backend))
                XCTFail("Unconfirmed action reported success")
            } catch { XCTAssertEqual(error as? PrinterControlError, .unconfirmed) }
            XCTAssertEqual(backend.commands.count, 1)
            XCTAssertNil(backend.saved)
            XCTAssertTrue(backend.feedback?.isBlocked() == true)
        }
    }
    func testDefiniteRejectionShowsDetailsWithoutBlockingStopReview() async throws {
        for failure in [PrinterControlError.rejected, .bambuRejected(reason: "mqtt message verify failed")] {
            let backend = WidgetBackend(profile: profile, current: snapshot())
            backend.sendFailure = failure
            do {
                try await WidgetControlService().perform(.pause, context: WidgetControlContext(profile: profile, snapshot: snapshot()), dependencies: dependencies(backend))
                XCTFail("Rejected command succeeded")
            } catch { XCTAssertEqual(error as? PrinterControlError, failure) }
            XCTAssertEqual(backend.commands, [.pause])
            XCTAssertEqual(backend.current.state, .printing)
            XCTAssertEqual(backend.feedback?.failureTitle, "Pause failed · Details")
            XCTAssertEqual(backend.feedback?.message, failure.localizedDescription)
            XCTAssertNil(backend.feedback?.blockedUntil)
            XCTAssertGreaterThanOrEqual(backend.reloads, 2)
        }
    }
    func testControlDetailsLinkAndOldFeedbackCompatibility() throws {
        let id = UUID()
        let url = WidgetControlFeedback.detailsURL(for: id)
        XCTAssertEqual(WidgetControlFeedback.detailsPrinterID(from: url), id)
        XCTAssertNil(WidgetControlFeedback.detailsPrinterID(from: URL(string: "https://control-help?id=\(id)")!))
        XCTAssertNil(WidgetControlFeedback.detailsPrinterID(from: URL(string: "printprogress://control-help?id=invalid")!))
        XCTAssertNil(WidgetControlFeedback.detailsPrinterID(from: URL(string: "printprogress://control-help?id=\(id)&id=\(UUID())")!))
        let old = try JSONDecoder().decode(WidgetControlFeedback.self, from: Data(#"{"message":"Earlier feedback","createdAt":0}"#.utf8))
        XCTAssertNil(old.failureTitle)
        XCTAssertFalse(old.isBlocked())
    }
    func testStopDeepLinkRoundTripsJobAndContainsNoCredentials() throws {
        var protected = profile; protected.credential = "fictional-secret-key"
        let context = try WidgetControlContext(profile: protected, snapshot: snapshot())
        let decoded = try XCTUnwrap(WidgetControlContext.stopContext(from: XCTUnwrap(context.stopURL)))
        XCTAssertEqual(decoded.id, context.id)
        XCTAssertEqual(decoded.snapshot.jobIdentifier, "planter.gcode")
        XCTAssertFalse(String(data: try XCTUnwrap(Data(base64Encoded: context.encoded)), encoding: .utf8)!.contains("fictional-secret-key"))
        XCTAssertThrowsError(try WidgetControlContext.decode(String(repeating: "a", count: 17000)))
        XCTAssertNil(try WidgetControlContext.stopContext(from: URL(string: "printprogress://refresh")!))
    }
}

private final class WidgetBackend {
    var profiles: [PrinterProfile]
    var current: PrinterSnapshot
    var commands: [PrinterCommand] = []
    var claimed: Set<UUID> = []
    var feedback: WidgetControlFeedback?
    var saved: PrinterSnapshot?
    var reloads = 0
    var changesStatus = true
    var sendFailure: PrinterControlError?
    var failAfterSend = false
    init(profile: PrinterProfile, current: PrinterSnapshot) { profiles = [profile]; self.current = current }
    func fetch() throws -> PrinterSnapshot {
        if failAfterSend && !commands.isEmpty { throw PrinterError.timeout }
        return current
    }
    func send(_ command: PrinterCommand) throws {
        commands.append(command)
        if let sendFailure { throw sendFailure }
        if changesStatus { current.state = command == .pause ? .paused : .printing; current.updatedAt = .now }
    }
    func claim(_ id: UUID) throws {
        guard claimed.insert(id).inserted else { throw PrinterControlError.busy }
    }
}
