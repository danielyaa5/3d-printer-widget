import Foundation
import Network

enum WebSocketPrinterClient {
    static func fetch(_ profile: PrinterProfile, timeout: TimeInterval) async throws -> PrinterSnapshot {
        guard let url = URL(string: profile.address), let host = url.host else { throw PrinterError.invalidResponse }
        let started = Date()
        var request: String?
        if profile.kind == .sdcp {
            // Unicast discovery to the entered printer only. No LAN scan or
            // multicast entitlement, and no device identity needs to be typed.
            let discovery = try TelemetryValue.json(await SDCPDiscovery(host: host, timeout: min(3, timeout / 2)).run())
            let details = TelemetryValue.object(discovery["Data"])
            guard let board = details["MainboardID"] as? String, !board.isEmpty else { throw PrinterError.invalidResponse }
            let message: [String: Any] = [
                "Id": discovery["Id"] as? String ?? "",
                "Data": ["Cmd": 0, "Data": [String: String](), "RequestID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                         "MainboardID": board, "TimeStamp": Int(Date().timeIntervalSince1970), "From": 0],
                "Topic": "sdcp/request/" + board,
            ]
            request = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        }
        let remaining = max(0.1, timeout - Date().timeIntervalSince(started))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = remaining
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = MQTTCodec.maximumPacketSize
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            deadline.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                socket.resume()
                if let request { try await socket.send(.string(request)) } // SDCP Cmd 0 requests status only.
                var creality = CrealityTelemetry()
                while true {
                    try Task.checkCancellation()
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    if profile.kind == .creality {
                        // The native K1 interface pushes a full report followed by deltas.
                        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { continue }
                        try creality.merge(data)
                        if creality.hasStatus { return try creality.snapshot(profile: profile) }
                    } else if let snapshot = try? SDCPTelemetry.parse(data, profile: profile) { return snapshot }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if Date().timeIntervalSince(started) >= timeout - 0.05 { throw PrinterError.timeout }
                throw error
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}

private final class SDCPDiscovery: @unchecked Sendable {
    let host: String
    let timeout: TimeInterval
    private let queue = DispatchQueue(label: "PrintProgress.SDCPDiscovery")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var deadline: DispatchWorkItem?
    private var completed = false
    private var cancelled = false
    init(host: String, timeout: TimeInterval) { self.host = host; self.timeout = timeout }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    if self.cancelled { self.finish(.failure(CancellationError())); return }
                    self.start()
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                if self.continuation != nil { self.finish(.failure(CancellationError())) }
            }
        }
    }
    private func start() {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 3000, using: .udp)
        self.connection = connection
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(PrinterError.timeout)) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.send(content: Data("M99999".utf8), completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish(.failure(error)) }
                })
                connection.receiveMessage { [weak self] data, _, _, error in
                    if let error { self?.finish(.failure(error)) }
                    else if let data { self?.finish(.success(data)) }
                    else { self?.finish(.failure(PrinterError.invalidResponse)) }
                }
            case .failed(let error): self.finish(.failure(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        deadline?.cancel(); deadline = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        continuation?.resume(with: result); continuation = nil
    }
}
