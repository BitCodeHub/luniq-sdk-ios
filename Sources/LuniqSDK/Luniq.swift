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
    internal var lastScreen: String = ""
    private var experiments: Experiments?
    private var personalizeClient: Personalize?
    private var decisionAgent: DecisionAgent?
    private var frustration: FrustrationDetector?
    private var errorCapture: ErrorCapture?
    private var networkCapture: NetworkCapture?
    private var intelligence: IntelligenceEngine?
    private let ioQueue = DispatchQueue(label: "ai.luniq.sdk.io", qos: .utility)

    // MARK: - Resilience state
    // Circuit breaker: after N consecutive flush failures we back off
    // exponentially (1, 2, 4, ... 300 s) so we don't hammer a degraded
    // backend. Reset on the first successful flush.
    private var consecFailures: Int = 0
    private var retryAfter: Date = .distantPast
    // Remote control: SDK refreshes this from /v1/sdk/config every 5 min.
    // Lets ops flip a kill switch or sample down a misbehaving customer
    // without an app store update.
    private var remoteEnabled: Bool = true
    private var remoteSample: Double = 1.0
    // Error reporting: at most one beacon per hour.
    private var errorWindowStart: Date = .distantPast
    private var errorWindowCount: Int = 0
    private var lastErrorBeacon: Date = .distantPast

    private static let kRemoteCfgEnabled = "luniq.remote.enabled"
    private static let kRemoteCfgSample = "luniq.remote.sample"
    private static let kRemoteCfgAt = "luniq.remote.at"
    private static let sdkVersion = "1.2.0"

    /// Optional navigation hook used by the test runner. Set this before
    /// calling Luniq.shared.start() to let regression tests drive your nav
    /// stack (e.g. push to a specific screen). Without it, navigate steps
    /// in tests are no-ops.
    @objc public var onTestNavigate: ((String) -> Void)?

    private var testRunner: LuniqTestRunner?

    private override init() { super.init() }

    @objc public func start(apiKey: String, endpoint: String, environment: String = "PRD") {
        start(config: LuniqConfig(apiKey: apiKey, endpoint: endpoint, environment: environment))
    }

    public func start(config: LuniqConfig) {
        self.config = config
        self.transport = HTTPTransport(config: config)
        self.guides = GuideEngine(config: config, track: { [weak self] n, p in self?.track(n, properties: p) })
        self.surveys = SurveyEngine(config: config, track: { [weak self] n, p in self?.track(n, properties: p) })
        self.replay = SessionReplay(config: config, identity: identity)
        self.feedback = FeedbackWidget(config: config, identity: identity)
        self.messenger = MessengerWidget(config: config, identity: identity, screenSource: { [weak self] in self?.lastScreen ?? "" })
        if let transport = self.transport {
            self.experiments = Experiments(config: config, identity: identity, transport: transport)
            self.personalizeClient = Personalize(config: config, identity: identity, transport: transport)
            self.decisionAgent = DecisionAgent(config: config, identity: identity,
                                                session: session, transport: transport)
        }
        self.autoCapture = AutoCaptureController(track: { [weak self] name, props in
            self?.track(name, properties: props)
        })
        self.frustration = FrustrationDetector(emit: { [weak self] n, p in
            self?.track(n, properties: p)
        })
        self.errorCapture = ErrorCapture(emit: { [weak self] n, p in
            self?.track(n, properties: p)
        })
        self.networkCapture = NetworkCapture(emit: { [weak self] n, p in
            self?.track(n, properties: p)
        })
        self.intelligence = IntelligenceEngine(emit: { [weak self] n, p in
            self?.track(n, properties: p)
        })
        queue.load()
        // Fire "app_open" on every foreground (warm starts) so guides/surveys
        // with onEvent="app_open" can trigger.
        session.onActive = { [weak self] wasNewSession in
            self?.track("app_open", properties: ["new_session": wasNewSession])
        }
        session.start()
        autoCapture?.install(enabled: config.autoCapture)
        errorCapture?.install()
        networkCapture?.install()
        // Auto-start session replay when autoCapture is on so every session
        // gets recorded without the app having to call startRecording().
        if config.autoCapture {
            replay?.start()
        }
        guides?.fetchGuides()
        // Cold-start: defer the first "app_open" until surveys are loaded so
        // triggers can actually match. UIApplication.didBecomeActive fires before
        // we get here on first launch, so we synthesize the open event ourselves.
        surveys?.fetchSurveys { [weak self] in
            self?.track("app_open", properties: ["new_session": true, "cold_start": true])
        }
        startFlushTimer()
        startContentRefreshTimer()
        loadCachedRemoteConfig()
        refreshRemoteConfig()
        // Test mode — only spins up if the API key explicitly says so. A
        // production key (lq_live_*) never enters this code path.
        if LuniqTestRunner.isTestKey(config.apiKey) {
            let runner = LuniqTestRunner(endpoint: config.endpoint, apiKey: config.apiKey, luniq: self)
            self.testRunner = runner
            runner.start()
        }
        Logger.log("Luniq started env=\(config.environment) autoCapture=\(config.autoCapture) replay=\(config.autoCapture)")
    }

    private func loadCachedRemoteConfig() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.kRemoteCfgEnabled) != nil {
            remoteEnabled = d.bool(forKey: Self.kRemoteCfgEnabled)
        }
        if d.object(forKey: Self.kRemoteCfgSample) != nil {
            remoteSample = max(0, min(1, d.double(forKey: Self.kRemoteCfgSample)))
        }
    }

    private func refreshRemoteConfig() {
        guard let config else { return }
        let urlString = "\(config.endpoint)/v1/sdk/config?key=\(config.apiKey)"
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        let s = URLSession(configuration: cfg)
        s.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            // Network error → keep previous values, retry in 10 min.
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 600) { [weak self] in
                    self?.refreshRemoteConfig()
                }
                return
            }
            if let enabled = obj["enabled"] as? Bool { self.remoteEnabled = enabled }
            if let sample = obj["sample"] as? Double { self.remoteSample = max(0, min(1, sample)) }
            let pollSecs = max(60, min(3600, (obj["pollSecs"] as? Int) ?? 300))
            let d = UserDefaults.standard
            d.set(self.remoteEnabled, forKey: Self.kRemoteCfgEnabled)
            d.set(self.remoteSample, forKey: Self.kRemoteCfgSample)
            d.set(Date(), forKey: Self.kRemoteCfgAt)
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(pollSecs)) { [weak self] in
                self?.refreshRemoteConfig()
            }
        }.resume()
    }

    private func recordSdkError(code: String, message: String) {
        let now = Date()
        if now.timeIntervalSince(errorWindowStart) > 3600 {
            errorWindowStart = now
            errorWindowCount = 0
        }
        errorWindowCount += 1
        guard now.timeIntervalSince(lastErrorBeacon) > 3600 else { return }
        lastErrorBeacon = now

        guard let config,
              let url = URL(string: "\(config.endpoint)/v1/sdk/error") else { return }
        let body: [String: Any] = [
            "sdk": "ios",
            "version": Self.sdkVersion,
            "code": code,
            "message": message,
            "count": errorWindowCount,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        req.httpBody = data
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req).resume()
    }

    @objc public func identify(visitorId: String, accountId: String? = nil, traits: [String: Any]? = nil) {
        identity.set(visitorId: visitorId, accountId: accountId, traits: traits ?? [:])
    }

    @objc public func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard let config else { return }
        if !config.enabled { return }
        // Honor remote kill switch + sample. The SDK keeps tracking locally
        // (enrichment, engines, intelligence) only when these allow it.
        if !remoteEnabled { return }
        if remoteSample < 1.0 && Double.random(in: 0..<1) >= remoteSample { return }
        var enriched = enrich(properties ?? [:])
        // AI-native enrichment: intent / sentiment / complexity / semantic_name
        enriched = intelligence?.enrich(name: eventName, props: enriched) ?? enriched
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
        // AI-native intelligence: update live profile + possibly fire nudges/churn
        intelligence?.observe(name: eventName, props: enriched)
        intelligence?.pushBreadcrumb(name: eventName, props: enriched)
        if eventName == "$error", let i = intelligence {
            var errEnriched = enriched
            if errEnriched["journey"] == nil { errEnriched["journey"] = i.journeySummary() }
            if errEnriched["persona"] == nil { errEnriched["persona"] = i.persona() }
        }
        // Feed frustration detector (rage/dead click) only for raw tap + screen events
        if eventName == "$tap" {
            let controlId = (enriched["id"] as? String) ?? (enriched["title"] as? String) ?? (enriched["control"] as? String) ?? "unknown"
            frustration?.recordTap(controlId: controlId, screen: screen ?? "")
        } else if eventName == "$screen" {
            frustration?.recordScreenChange()
        }
        // AI-native: feed the decision agent with every event; it throttles
        // internally and only calls the backend every N events.
        decisionAgent?.observe(eventName: eventName, properties: enriched)
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

    func currentConfig() -> LuniqConfig? { config }

    /// Register a SwiftUI view's frame as an "anchor" the engage runtime
    /// can target with a tooltip / coachmark guide. Called automatically
    /// by the .luniqAnchor(id) view modifier on every layout pass.
    private var anchorFrames: [String: CGRect] = [:]
    private let anchorFramesLock = NSLock()

    public func registerAnchorFrame(_ id: String, frame: CGRect) {
        anchorFramesLock.lock()
        let isFirstSighting = anchorFrames[id] == nil
        anchorFrames[id] = frame
        anchorFramesLock.unlock()
        // Phone home once per session per anchor so the dashboard can build a
        // human-friendly picker. Skipped on subsequent re-renders, which fire
        // many times during normal SwiftUI layout passes.
        if isFirstSighting && !id.isEmpty {
            track("$luniq_anchor_seen", properties: [
                "anchor": id,
                "screen": lastScreen,
            ])
        }
    }

    public func anchorFrame(for id: String) -> CGRect? {
        anchorFramesLock.lock(); defer { anchorFramesLock.unlock() }
        return anchorFrames[id]
    }

    /// Resolve a relative banner URL ("/v1/banners/image/abc") to absolute.
    func resolveBannerURL(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        guard let cfg = config else { return raw }
        let base = cfg.endpoint.hasSuffix("/") ? String(cfg.endpoint.dropLast()) : cfg.endpoint
        return base + (raw.hasPrefix("/") ? raw : "/" + raw)
    }

    /// Report a caught Swift error with optional context. Emits a $error event.
    public func reportError(_ error: Error, context: [String: Any] = [:]) {
        errorCapture?.report(error, context: context)
    }

    /// Live on-device user intelligence. Updated on every event.
    public func profile() -> PulseProfile? {
        intelligence?.profile()
    }

    /// Current predicted churn risk 0-100 (heuristic + pattern detection).
    @objc public func predictChurn() -> Int {
        intelligence?.predictedChurn() ?? 0
    }

    /// Current session worth score 0-100 — use to prioritize server-side AI analysis.
    @objc public func sessionScore() -> Int {
        intelligence?.sessionWorthScore() ?? 0
    }

    /// Subscribe to adaptive nudge decisions (show help, save offer, re-engagement).
    public func onNudge(_ fn: @escaping (PulseNudge) -> Void) {
        intelligence?.addListener(fn)
    }

    /// Real-time persona classification: power_user / explorer / struggler / first_time / loyalist / churner / browser.
    @objc public func persona() -> String { intelligence?.persona() ?? "browser" }

    /// AI-flavored natural-language summary of the user's recent journey.
    @objc public func journeySummary() -> String { intelligence?.journeySummary() ?? "" }

    /// 0-100 probability user completes their current goal (heuristic, real-time).
    @objc public func conversionProbability() -> Int { intelligence?.conversionProbability() ?? 0 }

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

    /// Show a persistent 💬 chat bubble pinned to the bottom-right of the
    /// host app, mirroring how Intercom/Crisp/Drift work on the web. Tapping
    /// it opens the messenger. Call once after `start()`. Hide later with
    /// `disableFloatingMessenger()`.
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

    /// A/B variant for the given experiment key. Async because the first
    /// call hits the server; subsequent calls with the same key are cached
    /// in-memory.
    public func variant(for experimentKey: String, completion: @escaping (String) -> Void) {
        guard let experiments = experiments else {
            DispatchQueue.main.async { completion("control") }
            return
        }
        experiments.variant(for: experimentKey, completion: completion)
    }

    /// Synchronous cached variant; returns "control" if not yet resolved.
    /// Safe to call from layout code.
    @objc public func cachedVariant(for experimentKey: String) -> String {
        experiments?.cachedVariant(for: experimentKey) ?? "control"
    }

    /// Ask the personalization engine whether to take an action right now
    /// (show guide, suppress survey, delay modal). Nil means no rule matched.
    public func personalize(event: String, context: [String: Any] = [:],
                             completion: @escaping ([String: Any]?) -> Void) {
        guard let client = personalizeClient else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        client.decide(event: event, context: context, completion: completion)
    }

    private func enrich(_ props: [String: Any]) -> [String: Any] {
        var out = props
        out["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        out["os_type"] = "IOS"
        out["brand"] = "H"
        out["env"] = config?.environment ?? "PRD"
        out["device_model"] = DeviceInfo.model
        out["device_os"] = UIDevice.current.systemVersion
        identity.traits.forEach { out[$0.key] = out[$0.key] ?? $0.value }
        return out
    }

    private func startFlushTimer() {
        ioQueue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.flushNow()
            self.startFlushTimer()
        }
    }

    private func startContentRefreshTimer() {
        ioQueue.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self else { return }
            self.guides?.fetchGuides()
            self.surveys?.fetchSurveys()
            self.startContentRefreshTimer()
        }
    }

    private func flushNow() {
        guard let transport else { return }
        // Circuit breaker — skip until the back-off window has elapsed.
        if Date() < retryAfter { return }
        let batch = queue.dequeueBatch(max: 200)
        if batch.isEmpty { return }
        transport.send(events: batch) { [weak self] success in
            guard let self else { return }
            if success {
                self.consecFailures = 0
                self.retryAfter = .distantPast
            } else {
                self.queue.requeue(batch)
                self.consecFailures += 1
                let exp = min(self.consecFailures - 1, 8)
                let backoff = min(300.0, pow(2.0, Double(exp)))
                self.retryAfter = Date().addingTimeInterval(backoff)
                self.recordSdkError(code: "ingest_failure", message: "send returned false")
            }
        }
    }
}
