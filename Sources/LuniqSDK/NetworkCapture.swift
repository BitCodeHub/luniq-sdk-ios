import Foundation

// Captures outbound HTTP traffic via a URLProtocol installed on the default
// URLSessionConfiguration. Emits $network_call with url, method, status,
// duration_ms, error. Skips requests to the Luniq backend itself so the
// SDK's own telemetry doesn't show up.
final class NetworkCapture {
    private let emit: (String, [String: Any]) -> Void
    private static var installed = false

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
    }

    func install() {
        guard !Self.installed else { return }
        Self.installed = true
        NetworkCaptureStore.emit = emit
        URLProtocol.registerClass(LuniqURLProtocol.self)
    }
}

enum NetworkCaptureStore {
    static var emit: ((String, [String: Any]) -> Void)?
    static let skipMarker = "ai.luniq.sdk.skip"
}

final class LuniqURLProtocol: URLProtocol, URLSessionDataDelegate {
    private var proxiedTask: URLSessionDataTask?
    private var session: URLSession?
    private var startedAt: Date?
    private var responseData = Data()
    private var responseStatus: Int = 0

    override class func canInit(with request: URLRequest) -> Bool {
        // Avoid recursion on our own retries
        if URLProtocol.property(forKey: NetworkCaptureStore.skipMarker, in: request) != nil { return false }
        // Only HTTP(S)
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        // Skip Luniq endpoint to avoid observing our own telemetry
        if let host = request.url?.host, let ep = Luniq.shared.currentConfig()?.endpoint,
           ep.contains(host) {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        startedAt = Date()
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: NetworkCaptureStore.skipMarker, in: mutable)
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.proxiedTask = session?.dataTask(with: mutable as URLRequest)
        self.proxiedTask?.resume()
    }

    override func stopLoading() {
        proxiedTask?.cancel()
        session?.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            responseStatus = http.statusCode
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let dur = Int((Date().timeIntervalSince(startedAt ?? Date())) * 1000)
        var props: [String: Any] = [
            "url":        request.url?.absoluteString ?? "",
            "host":       request.url?.host ?? "",
            "path":       request.url?.path ?? "",
            "method":     request.httpMethod ?? "GET",
            "status":     responseStatus,
            "duration_ms": dur,
            "size_bytes": responseData.count,
        ]
        if let error {
            props["error"] = (error as NSError).localizedDescription
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        NetworkCaptureStore.emit?("$network_call", props)
    }
}
