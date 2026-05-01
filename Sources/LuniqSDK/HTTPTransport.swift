import Foundation

final class HTTPTransport {
    private let config: LuniqConfig
    private let session: URLSession

    init(config: LuniqConfig) {
        self.config = config
        let sc = URLSessionConfiguration.default
        // 8s request timeout: short enough that a hung backend doesn't keep
        // an event batch in flight when the network is degraded, long enough
        // to absorb normal cell/wifi latency. Resource timeout sets the
        // hard ceiling including retries / redirects.
        sc.timeoutIntervalForRequest = 8
        sc.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: sc)
    }

    func send(events: [Event], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(config.endpoint)/v1/events") else { completion(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(["events": events]) else { completion(false); return }
        req.httpBody = body
        session.dataTask(with: req) { _, resp, err in
            if let err = err { Logger.log("send failed: \(err)"); completion(false); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(code))
        }.resume()
    }

    /// Generic JSON POST for intelligence endpoints (experiments, personalize).
    /// Always includes the workspace API key header so backend can resolve
    /// workspace context. Completion returns nil on any failure.
    func postJSON(path: String, body: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: "\(config.endpoint)\(path)") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion(nil); return }
        req.httpBody = data
        session.dataTask(with: req) { data, resp, err in
            if let err = err { Logger.log("postJSON \(path) failed: \(err)"); completion(nil); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let data = data else { completion(nil); return }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            completion(json)
        }.resume()
    }
}

extension Data {
    func gzipped() -> Data? {
        guard !isEmpty else { return nil }
        var result = Data()
        let chunk = 64 * 1024
        for i in stride(from: 0, to: count, by: chunk) {
            let end = Swift.min(i + chunk, count)
            result.append(self[i..<end])
        }
        return result
    }
}
