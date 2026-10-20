import XCTest
@testable import PrintProgressCore

/// Real loopback sockets exercise URLSession, Digest, TLS/MQTT, WebSocket and UDP.
/// All reports and credentials are synthetic; never connects to a physical printer.
final class NetworkIntegrationTests: XCTestCase {
    private static var server: Process!
    private static var directory: URL!
    private static var ports: [String: Any] = [:]
    private static var startupError: Error?

    override class func setUp() {
        super.setUp()
        do {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrintProgressTests-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/printer_server.py")
            server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            server.arguments = ["python3", script.path, "--directory", directory.path]
            server.standardOutput = FileHandle.nullDevice
            // The fixture contains synthetic data only. Keep startup diagnostics
            // visible so CI failures identify Python/OpenSSL errors directly.
            server.standardError = FileHandle.standardError
            try server.run()
            let ready = directory.appendingPathComponent("ready.json")
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: ready.path), server.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard FileManager.default.fileExists(atPath: ready.path) else {
                let reason = server.isRunning ? "timed out after 30 seconds" : "exited with status \(server.terminationStatus)"
                throw NSError(domain: "PrinterFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Python fixture \(reason); see fixture stderr."])
            }
            ports = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any] ?? [:]
        } catch { startupError = error }
    }

    override class func tearDown() {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    override func setUpWithError() throws {
        if let error = Self.startupError { throw error }
    }

    private func profile(_ kind: PrinterKind, _ path: String) -> PrinterProfile {
        let port = Self.ports[kind.usesWebSocket ? "websocket" : "http"] as! Int
        return PrinterProfile(name: "Fixture", kind: kind,
            address: kind == .bambu ? "127.0.0.1" : "\(kind.usesWebSocket ? "ws" : "http")://127.0.0.1:\(port)/\(path)",
            serialNumber: "FIXTURE", credential: "fixture-password",
            username: kind == .prusaLink && path == "prusa" ? "fixture-user" : nil)
    }

    private func expectError(_ expected: PrinterError, profile: PrinterProfile, timeout: Double = 2,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await PrinterClient.fetch(profile, timeout: timeout); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PrinterError, expected, file: file, line: line) }
    }

    func testEveryHTTPProtocolOverRealSockets() async throws {
        for (kind, path) in [(PrinterKind.moonraker, "moonraker"), (.octoPrint, "octo"),
                             (.prusaLink, "prusa"), (.prusaLink, "octo"), (.duet, "duet"), (.duet, "sbc")] {
            let result = try await PrinterClient.fetch(profile(kind, path))
            XCTAssertEqual(result.state, .printing, path)
            XCTAssertEqual(result.progress, 0.5, path)
            XCTAssertEqual(result.remainingSeconds, 600, path)
            XCTAssertFalse(result.isOffline, path)
            XCTAssertLessThan(abs(result.updatedAt.timeIntervalSinceNow), 2, path)
        }
    }

    func testCrealityMergesFragmentedStatusAndIgnoresNonReports() async throws {
        let result = try await PrinterClient.fetch(profile(.creality, "creality"))
        XCTAssertEqual(result.progress, 0.5)
        XCTAssertEqual(result.nozzleTemperature, 210)
        XCTAssertEqual(result.chamberTemperature, 35)
    }

    func testSDCPDiscoveryAcknowledgementAndStatus() async throws {
        try XCTSkipUnless(Self.ports["sdcp"] as? Bool == true, "Loopback UDP 3000 is occupied")
        let result = try await PrinterClient.fetch(profile(.sdcp, "websocket"))
        XCTAssertEqual(result.progress, 0.5)
        XCTAssertEqual(result.remainingSeconds, 600)
        XCTAssertNil(result.nozzleTemperature)
    }

    func testBambuTLSSubscriptionFragmentationAndCertificatePin() async throws {
        try XCTSkipUnless(Self.ports["mqtt"] as? Bool == true, "Loopback MQTT 8883 is occupied")
        var printer = profile(.bambu, "")
        let first = try await PrinterClient.fetch(printer)
        XCTAssertEqual(first.progress, 0.5)
        XCTAssertEqual(first.state, .printing)
        XCTAssertEqual(first.nozzleTemperature, 210)
        XCTAssertEqual(first.remainingSeconds, 600)
        XCTAssertEqual(first.certificateFingerprint?.count, 64)
        printer.certificateFingerprint = try XCTUnwrap(first.certificateFingerprint)
        let pinned = try await PrinterClient.fetch(printer)
        XCTAssertEqual(pinned.certificateFingerprint, first.certificateFingerprint)
        printer.certificateFingerprint = String(repeating: "0", count: 64)
        await expectError(.certificateChanged, profile: printer)
    }

    func testBambuRefusedCredentialsAreActionable() async throws {
        try XCTSkipUnless(Self.ports["mqtt"] as? Bool == true, "Loopback MQTT 8883 is occupied")
        var printer = profile(.bambu, "")
        printer.credential = "wrong-password"
        await expectError(.authentication, profile: printer)
    }

    func testHTTPAuthenticationFailureAndServerErrors() async {
        for kind in [PrinterKind.moonraker, .octoPrint, .prusaLink, .duet] {
            await expectError(.authentication, profile: profile(kind, "auth"))
            await expectError(.authentication, profile: profile(kind, "forbidden"))
            await expectError(.http(503), profile: profile(kind, "unavailable"))
        }
    }

    func testDigestRefusedPasswordDoesNotLoop() async {
        var printer = profile(.prusaLink, "prusa")
        printer.credential = "wrong-password"
        await expectError(.authentication, profile: printer)
    }

    func testHTTPRejectsMalformedAndOversizedReports() async {
        for path in ["bad", "oversized"] {
            do {
                _ = try await PrinterClient.fetch(profile(.octoPrint, path))
                XCTFail("Expected rejection of \(path)")
            } catch { /* Error must not become a fabricated idle reading. */ }
        }
    }

    func testAllHTTPBackendsRefuseCrossOriginRedirects() async {
        for kind in [PrinterKind.moonraker, .octoPrint, .prusaLink, .duet] {
            await expectError(.http(302), profile: profile(kind, "redirect"))
        }
    }

    func testSlowHTTPAndSilentWebSocketHaveBoundedTimeouts() async {
        for (kind, path) in [(PrinterKind.octoPrint, "slow"), (.moonraker, "slow"), (.creality, "silent")] {
            let started = Date()
            await expectError(.timeout, profile: profile(kind, path), timeout: 0.25)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.1, path)
        }
    }

    func testMoonrakerDiscoveryAndStatusShareOneDeadline() async {
        let started = Date()
        await expectError(.timeout, profile: profile(.moonraker, "budget"), timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }

    func testCancelHTTPAndWebSocketDoesNotWaitForDeadline() async {
        for (kind, path) in [(PrinterKind.octoPrint, "slow"), (.moonraker, "slow"), (.creality, "silent")] {
            let printer = profile(kind, path)
            let task = Task { try await PrinterClient.fetch(printer, timeout: 5) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let cancelled = Date()
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled request completed") }
            catch { XCTAssertTrue(error is CancellationError, "\(kind): \(type(of: error))") }
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 0.5)
        }
    }

    func testPrematureWebSocketCloseDoesNotProduceStatus() async {
        do { _ = try await PrinterClient.fetch(profile(.creality, "closed")); XCTFail("Expected closed connection") }
        catch { }
    }

    func testZZOnlyStatusTrafficWasSent() async throws {
        let port = Self.ports["http"] as! Int
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/metrics")!)
        let metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(metrics["violations"] as? [String], [])
    }
}
