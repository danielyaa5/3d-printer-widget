import XCTest
@testable import PrintProgressCore

/// Real HTTP, TLS, Digest, RTP and hardware decode using a synthetic blue image.
final class CameraIntegrationTests: XCTestCase {
    private var server: Process!
    private var directory: URL!
    private var ports: [String: Int] = [:]
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraFixture-\(UUID())")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/camera_server.py")
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3",script.path,"--directory",directory.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.standardError
        try server.run()
        let ready = directory.appendingPathComponent("ready.json"), deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), server.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        ports = try JSONDecoder().decode([String:Int].self, from: Data(contentsOf: ready))
    }
    override func tearDownWithError() throws {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    func testMJPEGDiscoveryDecodeAndStopClosesSocket() async throws {
        let profile = PrinterProfile(name:"Fixture",kind:.moonraker,address:"http://127.0.0.1:\(ports["http"]!)")
        let source = try await PrinterCameraSource.resolve(profile)
        let frame = expectation(description:"decoded HTTP frame")
        frame.assertForOverFulfill = false
        let stream = MJPEGCameraStream(onFrame: { image in
            XCTAssertEqual(image.width,160); XCTAssertEqual(image.height,90); frame.fulfill()
        }, onError: { _ in XCTFail("Unexpected camera error") })
        stream.start(source)
        await fulfillment(of:[frame],timeout:5)
        stream.stop()
        try await Task.sleep(nanoseconds:300_000_000)
        let receipts = try String(contentsOf:directory.appendingPathComponent("receipts.jsonl"),encoding:.utf8)
        XCTAssertTrue(receipts.contains("http-closed"))
    }
    func testRTSPSDigestHardwareDecodePinBeforeCredentialsAndSocketClose() async throws {
        let profile = PrinterProfile(name:"Fixture",kind:.bambu,address:"127.0.0.1",serialNumber:"FIXTURE",credential:"fixture-password")
        let source = PrinterCameraSource(url:URL(string:"rtsps://127.0.0.1:\(ports["rtsp"]!)/streaming/live/1")!,headers:[:])
        let frame = expectation(description:"decoded RTSPS frame"), pin = expectation(description:"certificate persisted")
        frame.assertForOverFulfill = false
        let directory = directory!
        let stream = BambuCameraStream(profile:profile,source:source,onCertificate:{ fingerprint in
            XCTAssertEqual(fingerprint.count,64)
            let receipts = (try? String(contentsOf:directory.appendingPathComponent("receipts.jsonl"),encoding:.utf8)) ?? ""
            XCTAssertFalse(receipts.contains("describe"),"Credentials sent before the pin was saved")
            pin.fulfill()
        },onFrame:{ image in
            XCTAssertEqual(image.width,160); XCTAssertEqual(image.height,90); frame.fulfill()
        },onError:{ error in XCTFail("Unexpected camera error: \(error.localizedDescription)") })
        stream.start()
        await fulfillment(of:[pin,frame],timeout:8)
        stream.stop()
        try await Task.sleep(nanoseconds:300_000_000)
        let receipts = try String(contentsOf:directory.appendingPathComponent("receipts.jsonl"),encoding:.utf8)
        XCTAssertTrue(receipts.contains("play")); XCTAssertTrue(receipts.contains("rtsp-closed"))
    }
    func testChangedPinAndFailedPinPersistenceNeverSendCredentials() async throws {
        for changed in [true,false] {
            var profile = PrinterProfile(name:"Fixture",kind:.bambu,address:"127.0.0.1",serialNumber:"FIXTURE",credential:"fixture-password")
            if changed { profile.camera = PrinterCameraSettings(); profile.camera?.certificateFingerprint = String(repeating:"0",count:64) }
            let failed = expectation(description:"pairing rejected")
            let source = PrinterCameraSource(url:URL(string:"rtsps://127.0.0.1:\(ports["rtsp"]!)/streaming/live/1")!,headers:[:])
            let stream = BambuCameraStream(profile:profile,source:source,onCertificate:{ _ in
                if changed { XCTFail("Changed pin accepted") }
                throw PrinterError.keychain(-25308)
            },onFrame:{ _ in XCTFail("Untrusted camera produced a frame") },onError:{ _ in failed.fulfill() })
            stream.start(); await fulfillment(of:[failed],timeout:5); stream.stop()
        }
        let receipts = (try? String(contentsOf:directory.appendingPathComponent("receipts.jsonl"),encoding:.utf8)) ?? ""
        XCTAssertFalse(receipts.contains("describe"))
    }
    func testHTTPAuthenticationAndRedirectFailuresAreActionable() async throws {
        for path in ["denied","redirect"] {
            let failed = expectation(description:path)
            let source = PrinterCameraSource(url:URL(string:"http://127.0.0.1:\(ports["http"]!)/\(path)")!,headers:[:])
            let stream = MJPEGCameraStream(onFrame:{ _ in XCTFail("Unexpected frame") },onError:{ error in
                XCTAssertTrue(error is PrinterCameraError); failed.fulfill()
            })
            stream.start(source); await fulfillment(of:[failed],timeout:5); stream.stop()
        }
    }
}
