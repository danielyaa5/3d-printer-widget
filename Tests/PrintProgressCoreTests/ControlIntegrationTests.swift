import XCTest
@testable import PrintProgressCore

/// Actual HTTP/Digest, TLS/MQTT and WebSocket/UDP exchanges with a loopback fixture.
final class ControlIntegrationTests: XCTestCase {
    private static var server: Process!
    private static var directory: URL!
    private static var ports: [String: Any] = [:]
    private static var startupError: Error?

    override class func setUp() {
        do {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrintControlTests-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/control_server.py")
            server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            server.arguments = ["python3", script.path, "--directory", directory.path]
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.standardError
            try server.run()
            let ready = directory.appendingPathComponent("ready.json"), deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: ready.path), server.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            ports = try TelemetryValue.json(Data(contentsOf: ready))
        } catch { startupError = error }
    }
    override class func tearDown() {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    override func setUp() async throws {
        if let error = Self.startupError { throw error }
        var request = URLRequest(url: url("reset")); request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.ports["http"]!)/\(path)")! }
    private func profile(_ kind: PrinterKind, path: String? = nil) -> PrinterProfile {
        PrinterProfile(name: "Fixture", kind: kind,
            address: kind == .bambu ? "127.0.0.1" : kind.usesWebSocket ? "ws://127.0.0.1:\(Self.ports["websocket"]!)/\(path ?? (kind == .creality ? "creality" : "control"))" : url(path ?? (kind == .moonraker ? "moonraker" : kind == .prusaLink ? "prusa" : "octo")).absoluteString,
            serialNumber: "FIXTURE", credential: "fixture-password", username: kind == .prusaLink && path != "legacy" ? "fixture-user" : nil)
    }
    private func metrics() async throws -> [String: Any] {
        try TelemetryValue.json(await URLSession.shared.data(from: url("metrics")).0)
    }
    private func cycle(_ printer: PrinterProfile) async throws {
        for (command, expectedState) in [(PrinterCommand.pause, PrintState.paused), (.resume, .printing), (.stop, .idle)] {
            let before = try await PrinterClient.fetch(printer)
            try await PrinterControl.perform(command, profile: printer, expected: before)
            let after = try await PrinterClient.fetch(printer)
            if command == .stop { XCTAssertTrue([.idle, .cancelled, .stopped].contains(after.state)) }
            else { XCTAssertEqual(after.state, expectedState) }
        }
    }
    func testHTTPPauseResumeStopIncludingRealDigestAndLegacyPrusa() async throws {
        for printer in [profile(.moonraker), profile(.octoPrint), profile(.prusaLink), profile(.prusaLink, path: "legacy")] {
            try await cycle(printer)
        }
        let value = try await metrics()
        XCTAssertEqual((value["commands"] as? [[String: Any]])?.count, 12)
        XCTAssertEqual(value["violations"] as? [String], [])
    }
    func testBambuPinsCertificateAndCorrelatesAcknowledgements() async throws {
        try XCTSkipUnless(Self.ports["mqtt"] as? Bool == true, "MQTT fixture port is occupied")
        var printer = profile(.bambu)
        printer.certificateFingerprint = try await PrinterClient.fetch(printer).certificateFingerprint
        try await cycle(printer)
        let value = try await metrics()
        XCTAssertEqual(value["violations"] as? [String], [])
    }
    func testSDCPChecksBoardRequestIDAndCommandInAcknowledgements() async throws {
        try XCTSkipUnless(Self.ports["sdcp"] as? Bool == true, "SDCP fixture port is occupied")
        try await cycle(profile(.sdcp))
        let value = try await metrics()
        XCTAssertEqual(value["violations"] as? [String], [])
    }
    func testNativeK1ControlsUseExplicitValuesAndWaitForReportedState() async throws {
        try await cycle(profile(.creality))
        let value = try await metrics()
        XCTAssertEqual(value["violations"] as? [String], [])
    }
    func testMismatchedMQTTAcknowledgementCannotConfirmCommand() async throws {
        try XCTSkipUnless(Self.ports["mqtt"] as? Bool == true, "MQTT fixture port is occupied")
        var printer = profile(.bambu); printer.credential = "wrong-ack"
        let first = try await PrinterClient.fetch(printer); printer.certificateFingerprint = first.certificateFingerprint
        do { try await PrinterControl.perform(.pause, profile: printer, expected: first, timeout: 2); XCTFail("Wrong acknowledgement accepted") }
        catch { XCTAssertEqual(error as? PrinterControlError, .unconfirmed) }
        let value = try await metrics()
        XCTAssertEqual((value["commands"] as? [[String: Any]])?.count, 1)
    }
    func testBambuRejectedControlDoesNotClaimSuccess() async throws {
        try XCTSkipUnless(Self.ports["mqtt"] as? Bool == true, "MQTT fixture port is occupied")
        var printer = profile(.bambu); printer.credential = "reject-control"
        let first = try await PrinterClient.fetch(printer); printer.certificateFingerprint = first.certificateFingerprint
        do { try await PrinterControl.perform(.pause, profile: printer, expected: first); XCTFail("Rejection accepted") }
        catch { XCTAssertEqual(error as? PrinterControlError, .rejected) }
    }
    func testChangedJobAndUnpairedBambuNeverSendControls() async throws {
        let printer = profile(.octoPrint)
        var expected = try await PrinterClient.fetch(printer); expected.jobIdentifier = "another-job.gcode"
        do { try await PrinterControl.perform(.stop, profile: printer, expected: expected); XCTFail("Changed job accepted") }
        catch { XCTAssertEqual(error as? PrinterControlError, .jobChanged) }
        let bambu = profile(.bambu)
        let unpaired = PrinterSnapshot(profile: bambu, state: .printing, jobName: "Fixture")
        do { try await PrinterControl.perform(.pause, profile: bambu, expected: unpaired); XCTFail("Unpaired printer accepted") }
        catch { XCTAssertEqual(error as? PrinterControlError, .pairingRequired) }
        let value = try await metrics()
        XCTAssertEqual(value["commands"] as? [[String: String]], [])
    }
    func testSameOriginAndCrossOriginMutationRedirectsAreNotFollowed() async throws {
        for path in ["redirect", "cross-redirect"] {
            let printer = profile(.octoPrint, path: path)
            let first = try await PrinterClient.fetch(printer)
            do { try await PrinterControl.perform(.pause, profile: printer, expected: first); XCTFail("Redirect accepted") }
            catch { XCTAssertEqual(error as? PrinterError, .http(307)) }
        }
        let value = try await metrics()
        XCTAssertEqual(value["violations"] as? [String], [])
    }
    func testTimedOutMutationIsNotRetried() async throws {
        let printer = profile(.octoPrint, path: "slow")
        let first = try await PrinterClient.fetch(printer)
        do { try await PrinterControl.perform(.pause, profile: printer, expected: first, timeout: 0.3); XCTFail("Timeout accepted") }
        catch { XCTAssertEqual(error as? PrinterControlError, .unconfirmed) }
        let value = try await metrics()
        XCTAssertEqual(value["commands"] as? [[String: String]], [["family": "slow", "action": "pause"]])
    }
}
