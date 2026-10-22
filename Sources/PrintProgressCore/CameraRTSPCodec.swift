import Foundation
import CryptoKit

/// RTSP/1.0 and interleaved RTP framing (RFC 2326), limited to one H.264 track.
struct CameraRTSPCodec {
    enum Message {
        case response(Int, [String: String], Data)
        case packet(UInt8, Data)
    }
    static func next(_ buffer: inout Data) throws -> Message? {
        guard !buffer.isEmpty else { return nil }
        let bytes = [UInt8](buffer.prefix(4))
        if bytes[0] == 0x24 {
            guard bytes.count == 4 else { return nil }
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            guard buffer.count >= length + 4 else { return nil }
            let data = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(length + 4)
            return .packet(bytes[1], data)
        }
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count < 64 * 1024 else { throw PrinterCameraError.invalidStream }
            return nil
        }
        guard let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { throw PrinterCameraError.invalidStream }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, status[0] == "RTSP/1.0", let code = Int(status[1]) else { throw PrinterCameraError.invalidStream }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0, value <= 1024 * 1024 else { throw PrinterCameraError.invalidStream }
            length = value
        } else { length = 0 }
        let headerSize = buffer.distance(from: buffer.startIndex, to: separator.upperBound)
        guard buffer.count >= headerSize + length else { return nil }
        let body = Data(buffer.dropFirst(headerSize).prefix(length))
        buffer.removeFirst(headerSize + length)
        return .response(code, headers, body)
    }

    static func authorization(challenge: String, method: String, uri: String, password: String) throws -> String {
        if challenge.lowercased().hasPrefix("basic") {
            return "Basic " + Data("bblp:\(password)".utf8).base64EncodedString()
        }
        guard challenge.lowercased().hasPrefix("digest") else { throw PrinterCameraError.authentication }
        let pattern = #"([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]*)"|([^,\s]+))"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = challenge as NSString
        var fields: [String: String] = [:]
        for match in regex.matches(in: challenge, range: NSRange(location: 0, length: ns.length)) {
            let value = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            fields[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: value)
        }
        guard let realm = fields["realm"], let nonce = fields["nonce"],
              fields["algorithm"] == nil || fields["algorithm"]?.uppercased() == "MD5" else { throw PrinterCameraError.authentication }
        func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        let ha1 = md5("bblp:\(realm):\(password)"), ha2 = md5("\(method):\(uri)")
        var extra = "", response: String
        if let qop = fields["qop"] {
            guard qop.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "auth" }) else { throw PrinterCameraError.authentication }
            let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            response = md5("\(ha1):\(nonce):00000001:\(cnonce):auth:\(ha2)")
            extra = ", qop=auth, nc=00000001, cnonce=\"\(cnonce)\""
        } else { response = md5("\(ha1):\(nonce):\(ha2)") }
        func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        if let opaque = fields["opaque"] { extra += ", opaque=\"\(escaped(opaque))\"" }
        return "Digest username=\"bblp\", realm=\"\(escaped(realm))\", nonce=\"\(escaped(nonce))\", uri=\"\(escaped(uri))\", response=\"\(response)\"\(extra)"
    }
}

/// RFC 6184 single NAL, STAP-A and FU-A. Access units end at the RTP marker.
/// Packet loss discards the incomplete unit and waits for the next IDR frame.
struct CameraH264RTP {
    private var fragment = Data()
    private var unit: [Data] = []
    private var unitSize = 0
    private var sequence: UInt16?
    private var timestamp: UInt32?
    private var damaged = false
    private(set) var waitingForIDR = true

    mutating func append(_ packet: Data) throws -> [Data]? {
        let p = [UInt8](packet)
        guard p.count >= 12, p[0] >> 6 == 2 else { throw PrinterCameraError.invalidStream }
        var offset = 12 + Int(p[0] & 15) * 4
        guard offset <= p.count else { throw PrinterCameraError.invalidStream }
        if p[0] & 0x10 != 0 {
            guard offset + 4 <= p.count else { throw PrinterCameraError.invalidStream }
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0 {
            let padding = Int(p.last!)
            guard padding > 0, padding <= end - offset else { throw PrinterCameraError.invalidStream }
            end -= padding
        }
        guard offset < end else { throw PrinterCameraError.invalidStream }
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let stamp = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        if let timestamp, timestamp != stamp {
            if !unit.isEmpty || !fragment.isEmpty { waitingForIDR = true }
            unit = []; unitSize = 0; fragment = Data(); damaged = false
        }
        timestamp = stamp
        if let sequence, seq != sequence &+ 1 { damaged = true; waitingForIDR = true; fragment = Data() }
        sequence = seq
        let payload = Array(p[offset..<end]), type = payload[0] & 31
        switch type {
        case 1...23: add(Data(payload))
        case 24:
            var index = 1
            while index + 2 <= payload.count {
                let count = Int(payload[index]) << 8 | Int(payload[index + 1]); index += 2
                guard count > 0, index + count <= payload.count else { throw PrinterCameraError.invalidStream }
                add(Data(payload[index..<index + count])); index += count
            }
            guard index == payload.count else { throw PrinterCameraError.invalidStream }
        case 28:
            guard payload.count > 2 else { throw PrinterCameraError.invalidStream }
            if payload[1] & 0x80 != 0 { fragment = Data([(payload[0] & 0xe0) | (payload[1] & 31)]) }
            guard !fragment.isEmpty else { damaged = true; break }
            fragment.append(contentsOf: payload.dropFirst(2))
            if payload[1] & 0x40 != 0 { add(fragment); fragment = Data() }
        default: throw PrinterCameraError.unsupported
        }
        guard unitSize + fragment.count <= 8 * 1024 * 1024 else { throw PrinterCameraError.invalidStream }
        guard p[1] & 0x80 != 0 else { return nil }
        let result = unit
        defer { unit = []; unitSize = 0; fragment = Data(); damaged = false }
        guard !damaged, fragment.isEmpty else { waitingForIDR = true; return nil }
        if result.contains(where: { $0.first.map { $0 & 31 == 5 } ?? false }) { waitingForIDR = false }
        return waitingForIDR ? nil : result
    }
    private mutating func add(_ nal: Data) { unit.append(nal); unitSize += nal.count }
}
