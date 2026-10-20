import XCTest
@testable import PrintProgressCore

private final class CommandURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class PrinterControlTests: XCTestCase {
    let printer = PrinterProfile(name: "Workshop", kind: .moonraker, address: "http://printer.local")
    func reading(_ state: PrintState = .printing) -> PrinterSnapshot {
        PrinterSnapshot(profile: printer, state: state, progress: 0.4, jobName: "Planter", elapsedSeconds: 600, jobIdentifier: "planter.gcode")
    }

    func testStateAndFreshnessGatesPreventUnsafeActions() throws {
        try PrinterControl.validate(.pause, snapshot: reading())
        try PrinterControl.validate(.resume, snapshot: reading(.paused))
        for state in [PrintState.idle, .busy, .finished, .failed, .cancelled, .stopped, .unknown] {
            for command in PrinterCommand.allCases { XCTAssertThrowsError(try PrinterControl.validate(command, snapshot: reading(state))) }
        }
        XCTAssertThrowsError(try PrinterControl.validate(.resume, snapshot: reading()))
        XCTAssertThrowsError(try PrinterControl.validate(.pause, snapshot: reading(.paused)))
        for variant in 0..<5 {
            var sample = reading()
            switch variant {
            case 0: sample.isOffline = true
            case 1: sample.updatedAt = .distantPast
            case 2: sample.updatedAt = Date().addingTimeInterval(60)
            case 3: sample.refreshUnavailable = true
            default: sample.controlsUnavailable = true
            }
            XCTAssertThrowsError(try PrinterControl.validate(.pause, snapshot: sample))
        }
    }

    func testChangedOrRestartedJobIsRejected() throws {
        let expected = reading()
        for variant in 0..<6 {
            var current = expected
            switch variant {
            case 0: current.id = UUID()
            case 1: current.jobName = "Another job"
            case 2: current.jobIdentifier = "other/planter.gcode"
            case 3: current.progress = 0.01
            case 4: current.elapsedSeconds = 10
            default: current.state = .paused
            }
            XCTAssertThrowsError(try PrinterControl.validateSameJob(.pause, expected: expected, current: current))
        }
        var advanced = expected; advanced.progress = 0.42; advanced.elapsedSeconds = 620
        try PrinterControl.validateSameJob(.pause, expected: expected, current: advanced)
    }

    func testOlderCachedSnapshotsRemainDecodable() throws {
        let encoded = try JSONEncoder().encode(reading())
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["jobIdentifier", "controlJobID", "controlsUnavailable"] { old[key] = nil }
        let decoded = try JSONDecoder().decode(PrinterSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.controlJobID)
        XCTAssertEqual(decoded.state, .printing)
    }

    func testExplicitHTTPCommandsUseOnlyTheirDocumentedEndpoint() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CommandURLProtocol.self]
        defer { CommandURLProtocol.handler = nil }
        for kind in [PrinterKind.moonraker, .octoPrint, .prusaLink] {
            let profile = PrinterProfile(name: "Workshop", kind: kind, address: "http://printer.local/proxy", credential: "example")
            for command in PrinterCommand.allCases {
                for modern in kind == .prusaLink ? [false, true] : [false] {
                    var sample = PrinterSnapshot(profile: profile)
                    if modern { sample.controlJobID = 42 }
                    var calls = 0
                    CommandURLProtocol.handler = { request in
                        calls += 1
                        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "example")
                        if kind == .moonraker {
                            XCTAssertEqual(request.url?.path, "/proxy/printer/print/" + (command == .stop ? "cancel" : command.rawValue))
                            XCTAssertEqual(request.httpMethod, "POST")
                            return (200, #"{"result":"ok"}"#)
                        } else if modern {
                            XCTAssertEqual(request.url?.path, "/proxy/api/v1/job/42" + (command == .stop ? "" : "/" + command.rawValue))
                            XCTAssertEqual(request.httpMethod, command == .stop ? "DELETE" : "PUT")
                        } else {
                            XCTAssertEqual(request.url?.path, "/proxy/api/job")
                            XCTAssertEqual(request.httpMethod, "POST")
                            var data = request.httpBody ?? Data()
                            if data.isEmpty, let stream = request.httpBodyStream {
                                stream.open(); defer { stream.close() }
                                var bytes = [UInt8](repeating: 0, count: 1024)
                                while stream.hasBytesAvailable {
                                    let count = stream.read(&bytes, maxLength: bytes.count)
                                    if count <= 0 { break }
                                    data.append(contentsOf: bytes.prefix(count))
                                }
                            }
                            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
                            XCTAssertEqual(body["command"], command == .stop ? "cancel" : "pause")
                            XCTAssertEqual(body["action"], command == .stop ? nil : command.rawValue)
                            XCTAssertNotEqual(body["action"], "toggle")
                        }
                        return (204, "")
                    }
                    try await PrinterControl.sendHTTP(command, profile: profile, snapshot: sample, timeout: 1, configuration: config)
                    XCTAssertEqual(calls, 1)
                }
            }
        }
    }

    func testRejectedControlIsNotRetriedOrHiddenAsSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CommandURLProtocol.self]
        defer { CommandURLProtocol.handler = nil }
        for code in [401, 403, 409, 423] {
            var calls = 0
            CommandURLProtocol.handler = { _ in calls += 1; return (code, "") }
            do { try await PrinterControl.sendHTTP(.stop, profile: printer, snapshot: reading(), timeout: 1, configuration: config); XCTFail("Must reject") }
            catch { XCTAssertEqual(error as? PrinterControlError, .rejected) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testMQTTControlPayloadHasUniqueCorrelationAndNoGCode() throws {
        for command in PrinterCommand.allCases {
            var data = try MQTTCodec.printCommand(command, serial: "EXAMPLE", sequence: "23456")
            let frame = try XCTUnwrap(MQTTCodec.nextFrame(buffer: &data))
            let packet = try MQTTCodec.publication(frame)
            XCTAssertEqual(packet.topic, "device/EXAMPLE/request")
            let root = try TelemetryValue.json(packet.payload)
            XCTAssertEqual(TelemetryValue.object(root["print"]) as? [String: String],
                ["command": command.rawValue, "sequence_id": "23456", "param": ""])
        }
    }

    func testMalformedSuccessAndServerFailureRemainUnconfirmed() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CommandURLProtocol.self]
        defer { CommandURLProtocol.handler = nil }
        for (status, body) in [(200, "broken"), (500, "{}"), (200, #"{"unexpected":true}"#)] {
            var calls = 0
            CommandURLProtocol.handler = { _ in calls += 1; return (status, body) }
            do { try await PrinterControl.sendHTTP(.pause, profile: printer, snapshot: reading(), timeout: 1, configuration: config); XCTFail("Unknown outcome accepted") }
            catch { XCTAssertEqual(error as? PrinterControlError, .unconfirmed) }
            XCTAssertEqual(calls, 1)
        }
    }
}
