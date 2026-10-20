import Foundation

/// Only status GETs and authentication GETs. No printer-control endpoints.
enum HTTPPrinterClient {
    static func fetch(_ profile: PrinterProfile, timeout: TimeInterval,
                      configuration: URLSessionConfiguration = .ephemeral) async throws -> PrinterSnapshot {
        let reader = PrinterHTTPReader(profile: profile, timeout: timeout, configuration: configuration)
        defer { reader.close() }
        switch profile.kind {
        case .octoPrint:
            return try await octoPrint(profile, reader: reader)
        case .prusaLink:
            // Prusa's legacy API documents API-key authentication, while v1
            // documents Digest. Prefer the API matching the chosen credentials.
            if profile.username == nil {
                do { return try await octoPrint(profile, reader: reader) }
                catch PrinterError.http(let code) where [404, 405].contains(code) { }
            }
            let status: Data
            do {
                status = try await reader.get("api/v1/status")
            } catch PrinterError.http(let status) where [404, 405].contains(status) {
                if profile.username == nil { throw PrinterError.http(status) }
                return try await octoPrint(profile, reader: reader)
            }
            // Job details add a filename; a missing job endpoint must not hide
            // valid printer telemetry or force a fallback to another API.
            let details: Data?
            do { details = try await reader.get("api/v1/job", accepting: [200, 204]) }
            catch PrinterError.http(404) { details = nil }
            return try PrusaLinkTelemetry.parse(status, jobData: details?.isEmpty == false ? details : nil, profile: profile)
        case .duet:
            return try await duet(profile, reader: reader)
        default: throw PrinterError.invalidResponse
        }
    }

    private static func octoPrint(_ profile: PrinterProfile, reader: PrinterHTTPReader) async throws -> PrinterSnapshot {
        let job = try await reader.get("api/job")
        let printer: Data?
        do { printer = try await reader.get("api/printer") }
        catch PrinterError.http(409) { printer = nil } // Host is online but its serial printer may be disconnected.
        return try OctoPrintTelemetry.parse(job, printerData: printer, profile: profile)
    }

    private static func duet(_ profile: PrinterProfile, reader: PrinterHTTPReader) async throws -> PrinterSnapshot {
        let password = profile.credential.isEmpty ? "reprap" : profile.credential
        var connection: [String: Any] = [:]
        var sbc = false
        do {
            connection = try TelemetryValue.json(await reader.get("rr_connect", query: [
                URLQueryItem(name: "password", value: password), URLQueryItem(name: "sessionKey", value: "yes")]))
            sbc = false
            guard TelemetryValue.number(connection["err"]) == 0 else {
                if TelemetryValue.number(connection["err"]) == 1 { throw PrinterError.authentication }
                throw PrinterError.configuration("The Duet has no free status sessions. Wait briefly and reconnect.")
            }
        } catch PrinterError.http(let code) where [404, 405].contains(code) {
            connection = try TelemetryValue.json(await reader.get("machine/connect", query: [URLQueryItem(name: "password", value: password)]))
            sbc = true
        }
        if let key = connection["sessionKey"], !(key is NSNull) { reader.sessionKey = String(describing: key) }
        // Old Duets share sessions by source IP. Disconnect only our uniquely
        // identified session, so a user's existing Duet Web Control stays signed in.
        func release() async {
            if reader.sessionKey != nil { _ = try? await reader.get(sbc ? "machine/disconnect" : "rr_disconnect", timeout: 2) }
        }
        do {
            let result: PrinterSnapshot
            if sbc {
                let model: Data
                do { model = try await reader.get("machine/model") }
                catch PrinterError.http(404) { model = try await reader.get("machine/status") }
                result = try DuetTelemetry.objectModel(model, profile: profile)
            } else {
                do {
                    let model = try await reader.get("rr_model", query: [URLQueryItem(name: "flags", value: "d99vn")])
                    result = try DuetTelemetry.objectModel(model, profile: profile)
                } catch PrinterError.http(let code) where [404, 405].contains(code) {
                    result = try DuetTelemetry.legacy(await reader.get("rr_status", query: [URLQueryItem(name: "type", value: "3")]), profile: profile)
                }
            }
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}

final class PrinterHTTPReader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let profile: PrinterProfile
    let timeout: TimeInterval
    private let deadline: Date
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    var sessionKey: String?

    init(profile: PrinterProfile, timeout: TimeInterval, configuration: URLSessionConfiguration) {
        self.profile = profile; self.timeout = timeout
        self.deadline = Date().addingTimeInterval(timeout)
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.urlCache = nil
        self.configuration.urlCredentialStorage = nil
        self.configuration.httpCookieStorage = nil
        self.configuration.timeoutIntervalForResource = timeout
    }
    func close() { session.invalidateAndCancel() }

    func get(_ path: String, query: [URLQueryItem] = [], accepting: Set<Int> = [200],
             timeout: TimeInterval? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard var components = URLComponents(string: profile.address + "/" + path) else { throw PrinterError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw PrinterError.invalidResponse }
        let remaining = min(timeout ?? self.timeout, deadline.timeIntervalSinceNow)
        guard remaining > 0 else { throw PrinterError.timeout }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: remaining)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if [.moonraker, .octoPrint].contains(profile.kind) || (profile.kind == .prusaLink && profile.username == nil) {
            if !profile.credential.isEmpty { request.setValue(profile.credential, forHTTPHeaderField: "X-Api-Key") }
        }
        if let sessionKey { request.setValue(sessionKey, forHTTPHeaderField: "X-Session-Key") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch where Task.isCancelled { throw CancellationError() }
        catch let error as URLError where error.code == .notConnectedToInternet { throw PrinterError.localNetworkUnavailable }
        catch let error as URLError where error.code == .timedOut { throw PrinterError.timeout }
        guard let http = response as? HTTPURLResponse else { throw PrinterError.invalidResponse }
        if [401, 403].contains(http.statusCode) { throw PrinterError.authentication }
        guard accepting.contains(http.statusCode) else { throw PrinterError.http(http.statusCode) }
        guard data.count <= MQTTCodec.maximumPacketSize else { throw PrinterError.invalidResponse }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest,
              profile.kind == .prusaLink, let username = profile.username,
              challenge.previousFailureCount == 0,
              let origin = URL(string: profile.address), challenge.protectionSpace.host == origin.host,
              challenge.protectionSpace.port == (origin.port ?? (origin.scheme == "https" ? 443 : 80)) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(user: username, password: profile.credential, persistence: .none))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let origin = URL(string: profile.address)
        // Never forward printer credentials or session keys to another origin.
        let sameOrigin = request.url?.host == origin?.host && request.url?.scheme == origin?.scheme
            && request.url?.port == origin?.port
        completionHandler(sameOrigin ? request : nil)
    }
}
