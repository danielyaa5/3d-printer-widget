import XCTest
@testable import PrintProgressCore

final class MQTTTests: XCTestCase {
    func testFragmentedFrameStaysBufferedUntilComplete() throws {
        let packet = MQTTCodec.packet(0x30, Data(repeating: 1, count: 300))
        var buffer = Data(packet.prefix(100))
        XCTAssertNil(try MQTTCodec.nextFrame(buffer: &buffer))
        buffer.append(packet.dropFirst(100))
        let frame = try XCTUnwrap(MQTTCodec.nextFrame(buffer: &buffer))
        XCTAssertEqual(frame.body.count, 300)
        XCTAssertTrue(buffer.isEmpty)
    }
    func testMultiplePacketsInOneRead() throws {
        var buffer = Data([0x20, 2, 0, 0, 0xD0, 0])
        XCTAssertEqual(try MQTTCodec.nextFrame(buffer: &buffer)?.type, 2)
        XCTAssertEqual(try MQTTCodec.nextFrame(buffer: &buffer)?.type, 13)
        XCTAssertNil(try MQTTCodec.nextFrame(buffer: &buffer))
    }
    func testQoSOnePublicationAcknowledgesPacketIdentifier() throws {
        let body = try MQTTCodec.string("device/DEMO/report") + Data([0, 12]) + Data(#"{"print":{}}"#.utf8)
        var bytes = MQTTCodec.packet(0x32, body)
        let frame = try XCTUnwrap(MQTTCodec.nextFrame(buffer: &bytes))
        let publication = try MQTTCodec.publication(frame)
        XCTAssertEqual(publication.topic, "device/DEMO/report")
        XCTAssertEqual(publication.payload, Data(#"{"print":{}}"#.utf8))
        XCTAssertEqual(publication.acknowledgement, Data([0x40, 2, 0, 12]))
    }
    func testMalformedLengthAndTruncatedTopicRejected() throws {
        var badLength = Data([0x30, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try MQTTCodec.nextFrame(buffer: &badLength))
        var badTopic = MQTTCodec.packet(0x30, Data([0, 10, 1]))
        let frame = try XCTUnwrap(MQTTCodec.nextFrame(buffer: &badTopic))
        XCTAssertThrowsError(try MQTTCodec.publication(frame))
    }
    func testUnicodeUsesByteCount() throws {
        let string = try MQTTCodec.string("文")
        XCTAssertEqual(Array(string.prefix(2)), [0, 3])
        XCTAssertEqual(string.count, 5)
    }
    func testStatusRequestHasNoPrinterControlCommand() throws {
        var bytes = try MQTTCodec.requestStatus(serial: "DEMO")
        let frame = try XCTUnwrap(MQTTCodec.nextFrame(buffer: &bytes))
        let publication = try MQTTCodec.publication(frame)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: publication.payload) as? [String: [String: String]])
        XCTAssertEqual(root, ["pushing": ["sequence_id": "0", "command": "pushall"]])
    }
}
