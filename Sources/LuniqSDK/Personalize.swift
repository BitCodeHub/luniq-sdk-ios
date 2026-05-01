import Foundation

/// Real-time decision client for the Luniq personalization engine.
///
/// On a meaningful event (screen change, CTA tap, error), the SDK can ask
/// the backend whether any rule should fire *right now* — e.g. show a
/// specific guide, suppress a survey, or delay a modal. Backend evaluates
/// workspace rules in priority order and returns the first match.
///
/// Results are cached for 60 seconds per (event, visitorId) to avoid a
/// network hop on every UI transition.
///
/// Usage:
///   Luniq.shared.personalize(event: "checkout_failed", context: ["attempts": 3]) { decision in
///       if let action = decision?["action"] as? [String: Any] {
///           // render guide / delay survey / etc.
///       }
///   }
final class Personalize {
    private let config: LuniqConfig
    private let identity: IdentityManager
    private let transport: HTTPTransport
    private var cache: [String: (at: Date, value: [String: Any])] = [:]
    private let queue = DispatchQueue(label: "ai.luniq.sdk.personalize")
    private let ttl: TimeInterval = 60

    init(config: LuniqConfig, identity: IdentityManager, transport: HTTPTransport) {
        self.config = config
        self.identity = identity
        self.transport = transport
    }

    func decide(event: String, context: [String: Any] = [:], completion: @escaping ([String: Any]?) -> Void) {
        let cacheKey = cacheKey(event: event, context: context)
        queue.async {
            if let cached = self.cache[cacheKey], Date().timeIntervalSince(cached.at) < self.ttl {
                DispatchQueue.main.async { completion(cached.value) }
                return
            }
            guard let visitorId = self.identity.visitorId else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let payload: [String: Any] = [
                "visitorId": visitorId,
                "event": event,
                "context": context
            ]
            self.transport.postJSON(path: "/v1/sdk/personalize", body: payload) { [weak self] resp in
                guard let self = self else { return }
                if let resp = resp, let matched = resp["matched"] as? Bool, matched {
                    self.queue.async {
                        self.cache[cacheKey] = (Date(), resp)
                    }
                    DispatchQueue.main.async { completion(resp) }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }
    }

    private func cacheKey(event: String, context: [String: Any]) -> String {
        let ctxKeys = context.keys.sorted().joined(separator: "|")
        return "\(event)::\(ctxKeys)"
    }
}
