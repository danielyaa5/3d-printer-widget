import Foundation
import ImageIO
import CoreGraphics

public final class MJPEGCameraStream: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var parser = CameraJPEGParser()
    private var deadline: DispatchWorkItem?
    private var stopped = false
    private var lastOutput = Date.distantPast
    private let queue = OperationQueue()
    private let lock = NSLock()
    private let onFrame: @Sendable (CGImage) -> Void
    private let onError: @Sendable (Error) -> Void

    public init(onFrame: @escaping @Sendable (CGImage) -> Void, onError: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame; self.onError = onError
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    public func start(_ source: PrinterCameraSource) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, session == nil else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.urlCache = nil; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: source.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("multipart/x-mixed-replace,image/jpeg", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()
        armDeadline()
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; deadline?.cancel(); deadline = nil
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
    }
    private func fail(_ error: Error) {
        lock.lock()
        let report = !stopped
        lock.unlock()
        stop()
        if report { onError(error) }
    }
    /// Call while holding the lock. A stalled stream must not leave a frozen
    /// last frame looking live indefinitely.
    private func armDeadline() {
        deadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.fail(PrinterCameraError.timeout) }
        self.deadline = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); fail(PrinterCameraError.invalidStream); return }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            fail([401, 403].contains(http.statusCode) ? PrinterCameraError.authentication : PrinterCameraError.unavailable)
            return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime.contains("multipart") || mime == "image/jpeg" || mime == "application/octet-stream" else {
            completionHandler(.cancel); fail(PrinterCameraError.unsupported); return
        }
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            for jpeg in try parser.append(data) {
                if lastOutput != .distantPast, Date().timeIntervalSince(lastOutput) < 0.1 { continue }
                guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
                    throw PrinterCameraError.invalidStream
                }
                lastOutput = .now
                guard
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                lock.lock()
                let active = !stopped
                if active { armDeadline() }
                lock.unlock()
                if active { onFrame(image) }
            }
        } catch { fail(error) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        fail(error ?? PrinterCameraError.disconnected)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // Camera configuration must name its actual endpoint; redirects must not
        // leak API headers or silently switch from an encrypted stream.
        completionHandler(nil)
    }
    deinit { session?.invalidateAndCancel() }
}
