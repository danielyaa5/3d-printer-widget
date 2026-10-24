import XCTest
@testable import PrintProgressCore

final class CameraTests: XCTestCase {
    func testCustomRelayOverridesBuiltInBambuCameraWithoutPrinterCredentials() async throws {
        var profile = PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid", serialNumber: "FIXTURE", credential: "fictional")
        profile.camera = PrinterCameraSettings()
        profile.camera?.streamURL = "https://relay.invalid/camera.mjpg"
        let source = try await PrinterCameraSource.resolve(profile)
        XCTAssertEqual(source.url.absoluteString, "https://relay.invalid/camera.mjpg")
        XCTAssertTrue(source.headers.isEmpty)
        for unsupported in ["rtsp://relay.invalid/live", "rtsps://relay.invalid/live", "http://user:fictional@relay.invalid/live"] {
            profile.camera?.streamURL = unsupported
            do {
                _ = try await PrinterCameraSource.resolve(profile)
                XCTFail("Unsupported custom address was accepted")
            } catch { XCTAssertTrue(error is PrinterCameraError) }
        }
    }
    func testOldProfilesDecodeWithCameraOffAndSettingsRoundTrip() throws {
        let original = PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid", serialNumber: "FIXTURE", credential: "fictional")
        let data = try JSONEncoder().encode(original)
        var profile = try JSONDecoder().decode(PrinterProfile.self, from: data)
        XCTAssertNil(profile.camera)
        profile.camera = PrinterCameraSettings()
        profile.camera?.enabled = true
        profile.camera?.streamURL = "http://camera.invalid/stream"
        XCTAssertEqual(try JSONDecoder().decode(PrinterProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
    func testDiscoveryKeepsTransformsAndDoesNotLeakAPIKeyToCameraOrigin() throws {
        let profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://printer.invalid:7125", credential: "fictional-key")
        let data = Data(#"{"result":{"webcams":[{"enabled":false,"stream_url":"http://disabled.invalid"},{"enabled":true,"stream_url":"/webcam/?action=stream","rotation":90,"flip_vertical":true}]}}"#.utf8)
        let source = try PrinterCameraSource.moonraker(data, profile: profile)
        XCTAssertEqual(source.url.absoluteString, "http://printer.invalid/webcam/?action=stream")
        XCTAssertTrue(source.headers.isEmpty)
        XCTAssertEqual(source.rotation, 90); XCTAssertTrue(source.flipVertical)
        XCTAssertEqual(PrinterCameraSource.headers(profile, for: URL(string: "http://printer.invalid:7125/camera")!), ["X-Api-Key": "fictional-key"])
        XCTAssertTrue(PrinterCameraSource.headers(profile, for: URL(string: "http://other.invalid:7125/camera")!).isEmpty)
        XCTAssertThrowsError(try PrinterCameraSource.validatedHTTPURL("http://user:secret@camera.invalid/stream"))
        XCTAssertThrowsError(try PrinterCameraSource.validatedHTTPURL("file:///private/stream"))
    }
    func testRelativeCameraUsesAdvertisedFrontendPortWithoutAPIKey() throws {
        let profile = PrinterProfile(name: "Fixture", kind: .moonraker,
            address: "http://printer.invalid:7125", credential: "fictional-key")
        func source(_ stream: String, _ snapshot: String) throws -> PrinterCameraSource {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["webcams": [[
                "stream_url": stream, "snapshot_url": snapshot, "rotation": 180, "flip_horizontal": true
            ]]]])
            return try PrinterCameraSource.moonraker(data, profile: profile)
        }
        let discovered = try source("/webcam/?action=stream", "http://printer.invalid:4408/webcam/?action=snapshot")
        XCTAssertEqual(discovered.url.absoluteString, "http://printer.invalid:4408/webcam/?action=stream")
        XCTAssertTrue(discovered.headers.isEmpty)
        XCTAssertEqual(discovered.rotation, 180)
        XCTAssertTrue(discovered.flipHorizontal)
        for untrusted in ["http://other.invalid:4408/webcam/?action=snapshot",
                          "https://printer.invalid:4408/webcam/?action=snapshot",
                          "http://printer.invalid:4408/different/?action=snapshot",
                          "http://user:secret@printer.invalid:4408/webcam/?action=snapshot"] {
            XCTAssertEqual(try source("/webcam/?action=stream", untrusted).url.absoluteString,
                "http://printer.invalid/webcam/?action=stream")
        }
        XCTAssertEqual(try source("http://camera.invalid:8080/live", "http://printer.invalid:4408/live").url.absoluteString,
            "http://camera.invalid:8080/live")
    }
    func testJPEGFragmentsAndMultipleFrames() throws {
        var parser = CameraJPEGParser()
        XCTAssertTrue(try parser.append(Data([1,2,0xff])).isEmpty)
        XCTAssertTrue(try parser.append(Data([0xd8,3,4,0xff])).isEmpty)
        XCTAssertEqual(try parser.append(Data([0xd9,0xff,0xd8,5,0xff,0xd9])), [Data([0xff,0xd8,3,4,0xff,0xd9]), Data([0xff,0xd8,5,0xff,0xd9])])
        XCTAssertThrowsError(try parser.append(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)))
    }
    func testRTSPFragmentationAndInterleavedPackets() throws {
        var data = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 3\r\n\r\nab".utf8)
        XCTAssertNil(try CameraRTSPCodec.next(&data))
        data.append(contentsOf: [0x63,0x24,0,0,3,1,2,3])
        guard case .response(200, let headers, let body) = try CameraRTSPCodec.next(&data) else { return XCTFail() }
        XCTAssertEqual(headers["cseq"], "1"); XCTAssertEqual(body, Data("abc".utf8))
        guard case .packet(0, let packet) = try CameraRTSPCodec.next(&data) else { return XCTFail() }
        XCTAssertEqual(packet, Data([1,2,3])); XCTAssertTrue(data.isEmpty)
    }
    private func packet(_ payload: [UInt8], seq: UInt16, marker: Bool, timestamp: UInt8 = 1) -> Data {
        Data([0x80, marker ? 0xe0 : 0x60, UInt8(seq >> 8), UInt8(seq & 255),0,0,0,timestamp,0,0,0,1]+payload)
    }
    func testH264FragmentationLossAndIDRRecovery() throws {
        var rtp = CameraH264RTP()
        XCTAssertNil(try rtp.append(packet([0x7c,0x85,1,2],seq: 1,marker:false)))
        XCTAssertEqual(try rtp.append(packet([0x7c,0x45,3,4],seq:2,marker:true)), [Data([0x65,1,2,3,4])])
        XCTAssertNil(try rtp.append(packet([0x7c,0x81,1],seq:3,marker:false,timestamp:2)))
        XCTAssertNil(try rtp.append(packet([0x7c,0x41,2],seq:5,marker:true,timestamp:2)))
        XCTAssertNil(try rtp.append(packet([0x61,1],seq:6,marker:true,timestamp:3)))
        XCTAssertEqual(try rtp.append(packet([0x65,9],seq:7,marker:true,timestamp:4)), [Data([0x65,9])])
    }
    func testDigestHidesPasswordAndRejectsUnknownAlgorithm() throws {
        let header = try CameraRTSPCodec.authorization(challenge: "Digest realm=\"camera\", nonce=\"fixture-nonce\"", method: "DESCRIBE", uri: "rtsps://printer.invalid/stream", password: "fixture-password")
        XCTAssertTrue(header.contains("username=\"bblp\"")); XCTAssertTrue(header.contains("response=\""))
        XCTAssertFalse(header.contains("fixture-password"))
        XCTAssertThrowsError(try CameraRTSPCodec.authorization(challenge: "Digest realm=\"camera\", nonce=\"n\", algorithm=SHA-256", method: "PLAY", uri: "rtsps://printer.invalid", password: "fixture"))
    }
}
