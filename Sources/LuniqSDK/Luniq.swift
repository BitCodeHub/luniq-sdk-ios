import Foundation
import UIKit

@objc public final class Luniq: NSObject {

    @objc public static let shared = Luniq()

    internal var config: LuniqConfig?
    private let queue = EventQueue()
    private var transport: HTTPTransport?
    private var session = SessionManager()
    private var identity = IdentityManager()
    private var autoCapture: AutoCaptureController?
    private var guides: GuideEngine?
    private var surveys: SurveyEngine?
    private var replay: SessionReplay?
    private var feedback: FeedbackWidget?
    private var messenger: MessengerWidget?
    private var lastScreen: String = ""
    private let ioQueue = DispatchQueue(label: "ai.luniq.sdk.io", qos: .utility)

    private override init() { super.init() }

    @objc public func start(apiKey: String, endpoint: String, environment: String = "PRD") {
        start(config: LuniqConfig(apiKey: apiKey, endpoint: endpoint, environment: environment))
    }

    /// Optional on-device intelligence provider. Set this to enable predictive-cohort
    /// audience targeting (`audience.predictiveCohort` on guides/surveys/banners).
    /// See LuniqIntelligenceSnapshot.
    public var intelligenceProvider: (() -> LuniqIntelligenceSnapshot?)? = nil

    public func start(config: LuniqConfig) {
        self.config = config
        self.transport = HTTPTransport(config: config)
        let snap: () -> LuniqIntelligenceSnapshot? = { [weak self] in self?.intelligenceProvider?() }
        self.guides = GuideEngine(config: config, track: { [weak self] n, p in self?.track(n, properties: p) }, intelligence: snap)
        self.surveys = SurveyEngine(config: config, track: { [weak self] n, p in self?.track(n, properties: p) }, intelligence: snap)
        self.replay = SessionReplay(config: config, identity: identity)
        self.feedback = FeedbackWidget(config: config, identity: identity)
        self.messenger = MessengerWidget(config: config, identity: identity, screenSource: { [weak self] in self?.lastScreen ?? "" })
        self.autoCapture = AutoCaptureController(track: { [weak self] name, props in
            self?.track(name, properties: props)
        })
        queue.load()
        // Fire "app_open" on every foreground (warm starts) so guides/surveys
        // with onEvent="app_open" can trigger.
        session.onActive = { [weak self] wasNewSession in
            self?.track("app_open", properties: ["new_session": wasNewSession])
        }
        session.start()
        autoCapture?.install(enabled: config.autoCapture)
        guides?.fetchGuides()
        // Cold-start: defer the first "app_open" until surveys are loaded so
        // triggers can actually match. UIApplication.didBecomeActive fires before
        // we get here on first launch, so we synthesize the open event ourselves.
        surveys?.fetchSurveys { [weak self] in
            self?.track("app_open", properties: ["new_session": true, "cold_start": true])
        }
        startFlushTimer()
        Logger.log("Luniq started env=\(config.environment) autoCapture=\(config.autoCapture)")
    }

    @objc public func identify(visitorId: String, accountId: String? = nil, traits: [String: Any]? = nil) {
        identity.set(visitorId: visitorId, accountId: accountId, traits: traits ?? [:])
    }

    @objc public func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard let config else { return }
        if !config.enabled { return }
        let enriched = enrich(properties ?? [:])
        let event = Event(
            name: eventName,
            properties: enriched,
            timestamp: Date(),
            sessionId: session.currentId,
            visitorId: identity.visitorId,
            accountId: identity.accountId
        )
        ioQueue.async { [weak self] in
            self?.queue.enqueue(event)
        }
        // Fire engines (they run their own logic async on main)
        let screen = enriched["screen_name"] as? String
        guides?.evaluate(eventName: eventName, screenName: screen, traits: identity.traits)
        surveys?.evaluate(eventName: eventName, screenName: screen, traits: identity.traits)
        replay?.recordEvent(name: eventName, properties: enriched)
    }

    @objc public func screen(_ name: String, properties: [String: Any]? = nil) {
        var p = properties ?? [:]
        p["screen_name"] = name
        lastScreen = name
        track("$screen", properties: p)
    }

    @objc public func optOut(_ optedOut: Bool) {
        config?.enabled = !optedOut
    }

    @objc public func flush() {
        ioQueue.async { [weak self] in self?.flushNow() }
    }

    // Session replay controls
    @objc public func startRecording() { replay?.start() }
    @objc public func stopRecording() { replay?.stop() }

    // Feedback widget
    @objc public func showFeedback(_ kind: String = "idea") { feedback?.present(kind: kind) }

    /// Open the in-app messenger — chat-style UI where users send a message
    /// (issue / idea / question) and get an AI reply in real time. Conversations
    /// land in the dashboard's `/messages` inbox so the team can follow up.
    /// Optionally pre-populate the composer with text (e.g. from a "Help"
    /// button on a specific screen).
    @objc public func openMessenger(prefill: String = "") {
        messenger?.present(prefilledText: prefill)
    }

    /// Show a persistent 💬 chat bubble pinned to the bottom-right of the host
    /// app. Tapping it opens the messenger. Call once after `start()`.
    @objc public func enableFloatingMessenger() {
        messenger?.enableFloatingBubble()
    }

    @objc public func disableFloatingMessenger() {
        messenger?.disableFloatingBubble()
    }

    // Manually trigger a guide or survey fetch (after login e.g.)
    @objc public func refreshInApp() {
        guides?.fetchGuides()
        surveys?.fetchSurveys()
    }

    private func enrich(_ props: [String: Any]) -> [String: Any] {
        var out = props
        out["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        out["os_type"] = "IOS"
        out["env"] = config?.environment ?? "PRD"
        out["device_model"] = DeviceInfo.model
        out["device_os"] = UIDevice.current.systemVersion
        identity.traits.forEach { out[$0.key] = out[$0.key] ?? $0.value }
        return out
    }

    private func startFlushTimer() {
        ioQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.flushNow()
            self.startFlushTimer()
        }
    }

    private func flushNow() {
        guard let transport else { return }
        let batch = queue.dequeueBatch(max: 50)
        if batch.isEmpty { return }
        transport.send(events: batch) { [weak self] success in
            if !success { self?.queue.requeue(batch) }
        }
    }
}
