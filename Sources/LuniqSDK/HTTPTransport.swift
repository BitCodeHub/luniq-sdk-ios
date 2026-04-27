import Foundation

final class HTTPTransport {
    private let config: LuniqConfig
    private let session: URLSession

    init(config: LuniqConfig) {
        self.config = config
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 15
        sc.timeoutIntervalForResource = 30
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
