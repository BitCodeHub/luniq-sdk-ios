import Foundation

/// Client for Luniq Intelligence A/B engine.
///
/// The backend does deterministic hashing (sha256(visitorId + experimentKey)),
/// so we could compute locally — but we call the server so it can also
/// enforce audience gating + persist exposure in one hop. Result is cached
/// in-memory per process so subsequent reads are O(1).
///
/// Usage:
///   Luniq.shared.variant(for: "checkout_button_color") { variant in
///       // render based on variant string ("control", "red", etc.)
///   }
final class Experiments {
    private let config: LuniqConfig
    private let identity: IdentityManager
    private let transport: HTTPTransport
    private var cache: [String: String] = [:]
    private let queue = DispatchQueue(label: "ai.luniq.sdk.experiments")

    init(config: LuniqConfig, identity: IdentityManager, transport: HTTPTransport) {
        self.config = config
        self.identity = identity
        self.transport = transport
    }

    func variant(for key: String, completion: @escaping (String) -> Void) {
        queue.async {
            if let cached = self.cache[key] {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            guard let visitorId = self.identity.visitorId else {
                DispatchQueue.main.async { completion("control") }
                return
            }
            let payload: [String: Any] = [
                "experimentKey": key,
                "visitorId": visitorId
            ]
            self.transport.postJSON(path: "/v1/sdk/experiments/assign", body: payload) { [weak self] resp in
                var variant = "control"
                if let resp = resp, let v = resp["variant"] as? String {
                    variant = v
                }
                self?.queue.async { self?.cache[key] = variant }
                DispatchQueue.main.async { completion(variant) }
            }
        }
    }

    /// Synchronous accessor — returns cached variant or "control" if not yet
    /// assigned. Prefer the async form for first read of a given key.
    func cachedVariant(for key: String) -> String {
        queue.sync { cache[key] ?? "control" }
    }
}
