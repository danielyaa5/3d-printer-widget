import Foundation

/// The small MQTT 3.1.1 subset needed for a status subscription.
public enum MQTTCodec {
    public struct Frame: Equatable {
        public let header: UInt8
        public let body: Data
        public var type: UInt8 { header >> 4 }
    }
    public static let maximumPacketSize = 2 * 1024 * 1024

    public static func string(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= 65535 else { throw PrinterError.invalidResponse }
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes
    }
    public static func packet(_ header: UInt8, _ body: Data) -> Data {
        var length = body.count, result = Data([header])
        repeat {
            var byte = UInt8(length % 128); length /= 128
            if length > 0 { byte |= 0x80 }
            result.append(byte)
        } while length > 0
        return result + body
    }
    public static func connect(clientID: String, password: String) throws -> Data {
        packet(0x10, try string("MQTT") + Data([4, 0xC2, 0, 30])
               + string(clientID) + string("bblp") + string(password))
    }
    public static func subscribe(serial: String) throws -> Data {
        packet(0x82, try Data([0, 1]) + string("device/\(serial)/report") + Data([0]))
    }
    public static func requestStatus(serial: String) throws -> Data {
        // pushall requests telemetry only. It does not change the print or printer.
        packet(0x30, try string("device/\(serial)/request")
               + Data(#"{"pushing":{"sequence_id":"0","command":"pushall"}}"#.utf8))
    }
    public static func nextFrame(buffer: inout Data) throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let bytes = Array(buffer.prefix(5))
        var length = 0, multiplier = 1, offset = 1
        while true {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]; offset += 1
            length += Int(byte & 0x7F) * multiplier
            guard length <= maximumPacketSize else { throw PrinterError.invalidResponse }
            if byte & 0x80 == 0 { break }
            guard offset < 5 else { throw PrinterError.invalidResponse }
            multiplier *= 128
        }
        guard buffer.count >= offset + length else { return nil }
        let header = buffer[buffer.startIndex]
        let body = Data(buffer.dropFirst(offset).prefix(length))
        buffer = Data(buffer.dropFirst(offset + length))
        return Frame(header: header, body: body)
    }
    public static func publication(_ frame: Frame) throws -> (topic: String, payload: Data, acknowledgement: Data?) {
        guard frame.type == 3, frame.body.count >= 2 else { throw PrinterError.invalidResponse }
        let bytes = Array(frame.body)
        let topicLength = Int(bytes[0]) * 256 + Int(bytes[1])
        var offset = 2 + topicLength
        guard bytes.count >= offset,
              let topic = String(data: Data(bytes[2..<offset]), encoding: .utf8) else { throw PrinterError.invalidResponse }
        let qos = (frame.header >> 1) & 3
        var acknowledgement: Data?
        if qos == 1 {
            guard bytes.count >= offset + 2 else { throw PrinterError.invalidResponse }
            acknowledgement = packet(0x40, Data(bytes[offset..<(offset + 2)])); offset += 2
        } else if qos != 0 { throw PrinterError.invalidResponse }
        return (topic, Data(bytes.dropFirst(offset)), acknowledgement)
    }
}
