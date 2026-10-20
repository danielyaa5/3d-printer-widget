import XCTest
@testable import PrintProgressCore

private final class StatusURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw PrinterError.invalidResponse }
            let (code, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class HTTPPrinterTests: XCTestCase {
    private func fetch(_ kind: PrinterKind, digest: Bool = true, _ handler: @escaping (URLRequest) throws -> (Int, String)) async throws -> PrinterSnapshot {
        StatusURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Monitoring must never issue printer control requests")
            return try handler(request)
        }
        defer { StatusURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusURLProtocol.self]
        let profile = PrinterProfile(name: "Workshop", kind: kind, address: "http://printer.local/proxy", credential: "example",
                                     username: kind == .prusaLink && digest ? "local-user" : nil)
        return try await HTTPPrinterClient.fetch(profile, timeout: 1, configuration: configuration)
    }
    func testOctoPrintReadOnlyPathsAndAPIKeyPreserveProxyPrefix() async throws {
        var paths: [String] = []
        let reading = try await fetch(.octoPrint) { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "example")
            switch request.url!.path {
            case "/proxy/api/job": return (200, #"{"state":"Printing","progress":{"completion":25,"printTimeLeft":60}}"#)
            case "/proxy/api/printer": return (200, #"{"temperature":{"tool0":{"actual":210}}}"#)
            default: XCTFail("Unexpected endpoint"); return (404, "{}")
            }
        }
        XCTAssertEqual(paths, ["/proxy/api/job", "/proxy/api/printer"])
        XCTAssertEqual(reading.progress, 0.25)
        XCTAssertEqual(reading.nozzleTemperature, 210)
    }
    func testOctoPrintDisconnected409KeepsReportedOfflineStatus() async throws {
        let reading = try await fetch(.octoPrint) { request in
            request.url!.path.hasSuffix("/job") ? (200, #"{"state":"Offline","progress":{}}"#) : (409, "{}")
        }
        XCTAssertTrue(reading.isOffline)
    }
    func testPrusaEmptyJobIsValidAndDoesNotLoseTemperatures() async throws {
        let reading = try await fetch(.prusaLink) { request in
            request.url!.path.hasSuffix("/status") ? (200, #"{"printer":{"state":"IDLE","temp_nozzle":25}}"#) : (204, "")
        }
        XCTAssertEqual(reading.state, .idle)
        XCTAssertEqual(reading.nozzleTemperature, 25)
    }
    func testPrusaAPIKeyUsesTheDocumentedLegacyAPI() async throws {
        let reading = try await fetch(.prusaLink, digest: false) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "example")
            switch request.url!.path {
            case "/proxy/api/job": return (200, #"{"state":"Printing","progress":{"completion":20}}"#)
            case "/proxy/api/printer": return (200, "{}")
            default: XCTFail("API key mode should use the legacy API first"); return (404, "")
            }
        }
        XCTAssertEqual(reading.progress, 0.2)
    }
    func testPrusaMissingJobDoesNotDiscardModernStatus() async throws {
        let reading = try await fetch(.prusaLink) { request in
            request.url!.path.hasSuffix("/status") ? (200, #"{"printer":{"state":"PRINTING"},"job":{"progress":10}}"#) : (404, "")
        }
        XCTAssertEqual(reading.state, .printing)
        XCTAssertEqual(reading.progress, 0.1)
    }
    func testPrusaFallsBackToLegacyOnlyWhenModernAPIIsAbsent() async throws {
        var paths: [String] = []
        let reading = try await fetch(.prusaLink) { request in
            paths.append(request.url!.path)
            switch request.url!.path {
            case "/proxy/api/v1/status": return (404, "")
            case "/proxy/api/job": return (200, #"{"state":"Operational","progress":{}}"#)
            case "/proxy/api/printer": return (200, #"{"temperature":{"bed":{"actual":25}}}"#)
            default: return (404, "")
            }
        }
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(reading.bedTemperature, 25)
    }
    func testAuthenticationFailureDoesNotTryOtherInterfaces() async {
        var calls = 0
        do {
            _ = try await fetch(.prusaLink) { _ in calls += 1; return (403, "") }
            XCTFail("Authentication must fail")
        } catch { XCTAssertEqual(error as? PrinterError, .authentication) }
        XCTAssertEqual(calls, 1)
    }
    func testDuetUniqueSessionIsReleasedAndLegacyIPSessionIsNotDisconnected() async throws {
        for unique in [false, true] {
            var paths: [String] = []
            _ = try await fetch(.duet) { request in
                let path = request.url!.path; paths.append(path)
                switch path {
                case "/proxy/rr_connect":
                    XCTAssertTrue(request.url!.query!.contains("sessionKey=yes"))
                    return (200, unique ? #"{"err":0,"sessionKey":42}"# : #"{"err":0}"#)
                case "/proxy/rr_model":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session-Key"), unique ? "42" : nil)
                    return (200, #"{"result":{"state":{"status":"idle"}}}"#)
                case "/proxy/rr_disconnect":
                    XCTAssertTrue(unique); XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session-Key"), "42")
                    return (200, #"{"err":0}"#)
                default: XCTFail("Unexpected endpoint"); return (404, "")
                }
            }
            XCTAssertEqual(paths.count, unique ? 3 : 2)
        }
    }
    func testDuetOldFirmwareFallsBackToStatusWithoutSendingGcode() async throws {
        let reading = try await fetch(.duet) { request in
            switch request.url!.path {
            case "/proxy/rr_connect": return (200, #"{"err":0}"#)
            case "/proxy/rr_model": return (404, "")
            case "/proxy/rr_status": return (200, #"{"status":"P","fractionPrinted":50}"#)
            default: XCTFail("Unexpected endpoint"); return (404, "")
            }
        }
        XCTAssertEqual(reading.progress, 0.5)
    }
    func testDuetSBCUsesItsOwnSessionAndObjectModel() async throws {
        let reading = try await fetch(.duet) { request in
            switch request.url!.path {
            case "/proxy/rr_connect": return (404, "")
            case "/proxy/machine/connect": return (200, #"{"sessionKey":"example-session"}"#)
            case "/proxy/machine/model":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session-Key"), "example-session")
                return (200, #"{"state":{"status":"paused"},"job":{"file":{"size":100},"filePosition":50}}"#)
            case "/proxy/machine/disconnect": return (200, "{}")
            default: XCTFail("Unexpected endpoint"); return (404, "")
            }
        }
        XCTAssertEqual(reading.state, .paused)
        XCTAssertEqual(reading.progress, 0.5)
        XCTAssertNil(reading.finishDate)
    }
}
