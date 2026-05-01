import Foundation

/// Native, on-device user intelligence. Updated on every event; zero roundtrip
/// to the server. Exposes a public snapshot via Luniq.shared.profile().
///
///   - engagementScore: 0-100, how engaged is this user
///   - churnRisk:       0-100, how likely to abandon the current session
///   - frustrationLevel:0-100, current UX friction
///   - sessionWorth:    0-100, should server-side AI prioritize this session
///
/// Also classifies each event with intent / sentiment / complexity /
/// semantic_name heuristically, and emits $nudge_triggered / $churn_predicted
/// when appropriate.
public struct PulseProfile: Codable {
    public var engagementScore:  Int
    public var churnRisk:        Int
    public var frustrationLevel: Int
    public var sessionWorth:     Int
    public var featureMastery:   [String: Int]
}

public struct PulseNudge {
    public let kind:   String   // "help_offer" | "save_offer" | "reengagement_prompt"
    public let reason: String
    public let screen: String
}

final class IntelligenceEngine {
    private var engagement: Double = 50
    private var churn:      Double = 0
    private var frustration:Double = 0
    private var worth:      Double = 0
    private var mastery:    [String: Int] = [:]
    private var patterns:   [String] = []
    private var tapCount = 0, screenCount = 0, errorCount = 0, rageCount = 0, deadCount = 0
    private var lastScreen = ""
    private var lastTapAt  = Date.distantPast
    private var lastNudgeAt = Date.distantPast
    private var lastProfileEmitAt = Date.distantPast
    private var churnEmitted = false
    private let lock = NSRecursiveLock()
    private let emit: (String, [String: Any]) -> Void
    private var nudgeListeners: [(PulseNudge) -> Void] = []

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
    }

    func addListener(_ fn: @escaping (PulseNudge) -> Void) {
        lock.lock(); defer { lock.unlock() }
        nudgeListeners.append(fn)
    }

    func profile() -> PulseProfile {
        lock.lock(); defer { lock.unlock() }
        return PulseProfile(
            engagementScore:  Int(engagement.rounded()),
            churnRisk:        Int(churn.rounded()),
            frustrationLevel: Int(frustration.rounded()),
            sessionWorth:     Int(worth.rounded()),
            featureMastery:   mastery
        )
    }

    func predictedChurn() -> Int { Int(churn.rounded()) }
    func sessionWorthScore() -> Int { Int(worth.rounded()) }

    /// Real-time persona classification.
    func persona() -> String {
        lock.lock(); defer { lock.unlock() }
        if rageCount >= 2 || errorCount >= 3 || frustration >= 60 { return "struggler" }
        if engagement >= 80 && screenCount >= 8 { return "power_user" }
        if screenCount <= 2 && tapCount <= 5 { return "first_time" }
        if churn >= 60 { return "churner" }
        if engagement >= 60 && mastery.count >= 4 { return "loyalist" }
        if tapCount > screenCount * 3 { return "explorer" }
        return "browser"
    }

    /// Heuristic P(completes current goal) 0-100.
    func conversionProbability() -> Int {
        lock.lock(); defer { lock.unlock() }
        var base: Double = 50
        base += min(engagement - 50, 30)
        base -= min(frustration * 0.6, 30)
        base -= min(churn * 0.4, 30)
        base += min(Double(screenCount) * 1.5, 20)
        if errorCount > 0 { base -= 15 }
        if rageCount  > 0 { base -= 20 }
        return max(0, min(100, Int(base.rounded())))
    }

    // --- Smart breadcrumbs ring buffer ---
    private var breadcrumbs: [(Date, String, String, String)] = []
    func pushBreadcrumb(name: String, props: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let screen = (props["screen_name"] as? String) ?? ""
        let sem = (props["semantic_name"] as? String) ?? ""
        breadcrumbs.append((Date(), name, screen, sem))
        if breadcrumbs.count > 20 { breadcrumbs.removeFirst(breadcrumbs.count - 20) }
    }
    func journeySummary() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let first = breadcrumbs.first else { return "" }
        return breadcrumbs.map { c in
            let sec = Int(c.0.timeIntervalSince(first.0))
            let label = c.3.isEmpty ? c.1.replacingOccurrences(of: "$", with: "") : c.3
            return "\(label)\(c.2.isEmpty ? "" : " on \(c.2)") (\(sec)s)"
        }.joined(separator: " → ").prefix(800).description
    }

    /// Core update, called from Luniq.track on every event.
    func observe(name: String, props: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()

        switch name {
        case "$screen":
            screenCount += 1
            let sn = (props["screen_name"] as? String) ?? ""
            lastScreen = sn
            mastery[sn, default: 0] += 1
            engagement = clamp(engagement + 1, 0, 100)
        case "$tap":
            tapCount += 1
            lastTapAt = now
            engagement = clamp(engagement + 0.3, 0, 100)
        case "$rage_click":
            rageCount += 1
            frustration = clamp(frustration + 25, 0, 100)
            churn = clamp(churn + 12, 0, 100)
            engagement = clamp(engagement - 5, 0, 100)
        case "$dead_click":
            deadCount += 1
            frustration = clamp(frustration + 10, 0, 100)
            churn = clamp(churn + 4, 0, 100)
        case "$error":
            errorCount += 1
            frustration = clamp(frustration + 15, 0, 100)
            churn = clamp(churn + 8, 0, 100)
        case "$guide_completed", "$survey_completed":
            engagement = clamp(engagement + 8, 0, 100)
            churn = clamp(churn - 5, 0, 100)
        default: break
        }

        // Natural decay
        let sinceTap = lastTapAt.timeIntervalSince1970 > 0 ? now.timeIntervalSince(lastTapAt) / 60.0 : 0
        if sinceTap > 1 { frustration = clamp(frustration - 5 * sinceTap, 0, 100) }

        // Pattern buffer
        patterns.append(name)
        if patterns.count > 8 { patterns.removeFirst(patterns.count - 8) }

        // Session worth
        let depth = Double(screenCount) + Double(tapCount) * 0.2
        worth = clamp(min(depth, 50) + Double(errorCount) * 10 + Double(rageCount) * 12 + frustration * 0.3, 0, 100)

        // Periodic profile snapshot (every 30s max)
        if now.timeIntervalSince(lastProfileEmitAt) > 30 {
            lastProfileEmitAt = now
            emit("$profile_snapshot", [
                "engagement_score":  Int(engagement.rounded()),
                "churn_risk":        Int(churn.rounded()),
                "frustration_level": Int(frustration.rounded()),
                "session_worth":     Int(worth.rounded()),
                "screens_visited":   screenCount,
                "taps":              tapCount,
                "errors":            errorCount,
                "rage_clicks":       rageCount,
            ])
        }

        // Predictive churn — one-shot per session
        if churn >= 70 && !churnEmitted && isAbandonPattern(patterns) {
            churnEmitted = true
            emit("$churn_predicted", [
                "confidence": Int(churn.rounded()),
                "reason":     abandonReason(),
                "screen_name": lastScreen,
            ])
        }

        // Adaptive nudges
        maybeFireNudge(now: now)
    }

    /// Client-side enrichment added to every event's properties.
    func enrich(name: String, props: [String: Any]) -> [String: Any] {
        var out = props
        out["intent"]     = out["intent"]     ?? classifyIntent(name: name, props: props)
        out["sentiment"]  = out["sentiment"]  ?? classifySentiment(name: name, props: props)
        out["complexity"] = out["complexity"] ?? classifyComplexity(name: name, props: props)
        if let sem = inferSemanticName(name: name, props: props), out["semantic_name"] == nil {
            out["semantic_name"] = sem
        }
        return out
    }

    // MARK: - classifiers (heuristic)

    private func classifyIntent(name: String, props: [String: Any]) -> String {
        let text = ((props["text"] as? String) ?? (props["title"] as? String) ?? "").lowercased()
        if name == "$error" || name == "$rage_click" || name == "$dead_click" { return "troubleshoot" }
        if text.contains(anyOf: ["buy", "cart", "checkout", "purchase", "pay"]) { return "purchase" }
        if text.contains(anyOf: ["help", "support", "faq", "contact"]) { return "support" }
        if text.contains(anyOf: ["settings", "profile", "account", "manage"]) { return "configure" }
        if text.contains(anyOf: ["search", "find", "explore", "browse"]) { return "explore" }
        return "browse"
    }

    private func classifySentiment(name: String, props: [String: Any]) -> String {
        if name == "$rage_click" || name == "$error" { return "negative" }
        if name == "$guide_completed" || name == "$survey_completed" { return "positive" }
        let text = ((props["text"] as? String) ?? "").lowercased()
        if text.contains(anyOf: ["love", "great", "awesome", "thanks", "complete"]) { return "positive" }
        if text.contains(anyOf: ["cancel", "skip", "close", "back", "no"]) { return "negative" }
        return "neutral"
    }

    private func classifyComplexity(name: String, props: [String: Any]) -> String {
        if name == "$error" { return "complex" }
        let text = (props["text"] as? String) ?? ""
        if text.count > 40 { return "complex" }
        if text.count > 12 { return "medium" }
        return "simple"
    }

    private func inferSemanticName(name: String, props: [String: Any]) -> String? {
        guard name == "$tap" else { return nil }
        let text = ((props["text"] as? String) ?? (props["title"] as? String) ?? "").lowercased()
        if text.contains(anyOf: ["submit", "confirm", "place order", "checkout", "pay"]) { return "form_submit" }
        if text.contains(anyOf: ["buy", "purchase", "add to cart"]) { return "purchase_intent" }
        if text.contains(anyOf: ["sign up", "create account", "register"]) { return "signup_intent" }
        if text.contains(anyOf: ["log in", "sign in", "login"]) { return "login_intent" }
        if text.contains(anyOf: ["delete", "remove", "cancel"]) { return "destructive_action" }
        if text.contains(anyOf: ["help", "support", "faq"]) { return "help_seek" }
        if text.contains(anyOf: ["search", "find"]) { return "search_intent" }
        return nil
    }

    private func isAbandonPattern(_ seq: [String]) -> Bool {
        guard seq.count >= 3 else { return false }
        let last3 = seq.suffix(3).joined(separator: ",")
        return last3.contains("rage") || last3.contains("error") || last3.contains("dead_click")
    }
    private func abandonReason() -> String {
        if rageCount  >= 2 { return "repeated_rage_clicks" }
        if errorCount >= 2 { return "multiple_errors" }
        if deadCount  >= 3 { return "unresponsive_ui" }
        if frustration > 60 { return "high_frustration" }
        return "abandon_pattern"
    }

    private func maybeFireNudge(now: Date) {
        guard now.timeIntervalSince(lastNudgeAt) > 30 else { return }
        let n: PulseNudge?
        if frustration >= 60 {
            n = PulseNudge(kind: "help_offer", reason: "high_frustration", screen: lastScreen)
        } else if churn >= 75 {
            n = PulseNudge(kind: "save_offer", reason: "churn_risk", screen: lastScreen)
        } else if engagement < 20 && screenCount > 3 {
            n = PulseNudge(kind: "reengagement_prompt", reason: "low_engagement", screen: lastScreen)
        } else {
            n = nil
        }
        guard let nudge = n else { return }
        lastNudgeAt = now
        for listener in nudgeListeners { listener(nudge) }
        emit("$nudge_triggered", [
            "nudge_kind": nudge.kind,
            "reason":     nudge.reason,
            "screen_name": nudge.screen,
        ])
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        return min(max(v, lo), hi)
    }
}

private extension String {
    func contains(anyOf needles: [String]) -> Bool {
        for n in needles { if self.contains(n) { return true } }
        return false
    }
}
