//
//  DecisionAgent.swift
//  GIA — Luniq SDK (AI-native in-session intervention)
//
//  Every N observed events (default 8), posts the recent trail + identity
//  to the Luniq backend's /v1/sdk/decide endpoint. The server runs an
//  LLM over the trail and may return:
//    { action: "show_guide",   guideId: "..." }
//    { action: "show_survey",  surveyId: "..." }
//    { action: "show_feedback" }
//    { action: "nothing" }
//
//  This is the AI-native differentiation vs. PM-authored trigger rules —
//  the backend reasons about user state in natural language and picks the
//  intervention that fits RIGHT NOW.
//

import Foundation
import UIKit

final class DecisionAgent {
    private let config: LuniqConfig
    private let identity: IdentityManager
    private let session: SessionManager
    private let transport: HTTPTransport

    private let queue = DispatchQueue(label: "ai.luniq.sdk.decide")
    private var trail: [[String: Any]] = []
    private var eventsSinceDecision = 0
    private let interval = 8           // call backend every 8 events
    private let trailCap = 30          // most-recent events carried
    private var cooldownUntil: Date = .distantPast
    // In-flight guard: if a decide call is already in flight, don't start
    // another one even if the event-count threshold is crossed again.
    // Without this, two rapid bursts of events can each reset the counter
    // and fire concurrent /v1/sdk/decide calls, both returning
    // "show_feedback" before either has set the post-call cooldown — which
    // is why users sometimes see the feedback modal pop up twice.
    private var inFlight = false

    init(config: LuniqConfig,
         identity: IdentityManager,
         session: SessionManager,
         transport: HTTPTransport) {
        self.config = config
        self.identity = identity
        self.session = session
        self.transport = transport
    }

    func observe(eventName: String, properties: [String: Any]) {
        queue.async {
            let entry: [String: Any] = [
                "t": Int(Date().timeIntervalSince1970 * 1000),
                "n": eventName,
                "s": properties["screen_name"] as? String ?? "",
            ]
            self.trail.append(entry)
            if self.trail.count > self.trailCap {
                self.trail.removeFirst(self.trail.count - self.trailCap)
            }
            self.eventsSinceDecision += 1
            if self.eventsSinceDecision >= self.interval,
               !self.inFlight,
               Date() >= self.cooldownUntil,
               self.identity.visitorId != nil {
                self.eventsSinceDecision = 0
                self.inFlight = true
                // Set cooldown immediately on send (not on response) so even
                // if the backend takes seconds to reply, no second decision
                // call can race past it.
                self.cooldownUntil = Date().addingTimeInterval(60)
                self.callBackend()
            }
        }
    }

    private func callBackend() {
        let payload: [String: Any] = [
            "visitorId": identity.visitorId ?? "",
            "accountId": identity.accountId ?? "",
            "sessionId": session.currentId,
            "trail":     trail,
            "traits":    identity.traits,
        ]
        transport.postJSON(path: "/v1/sdk/decide", body: payload) { [weak self] resp in
            guard let self = self else { return }
            // Always release the in-flight guard, regardless of outcome.
            self.queue.async { self.inFlight = false }
            guard let resp = resp,
                  let action = resp["action"] as? String,
                  action != "nothing" else { return }
            self.render(action: action, payload: resp)
        }
    }

    private func render(action: String, payload: [String: Any]) {
        // Each branch renders synchronously on main.
        DispatchQueue.main.async {
            switch action {
            case "show_guide":
                // Re-fetch guides so the targeted one is cached, then let
                // GuideEngine's evaluate() pick it up on the next event.
                Luniq.shared.refreshInApp()
            case "show_survey":
                Luniq.shared.refreshInApp()
            case "show_feedback":
                Luniq.shared.showFeedback("idea")
            default:
                break
            }
            // Always track the decision so PMs can see which users were
            // touched and what the agent chose.
            Luniq.shared.track("decision_agent_fired", properties: [
                "action": action,
                "guideId": payload["guideId"] as? String ?? "",
                "surveyId": payload["surveyId"] as? String ?? "",
                "reason": payload["reason"] as? String ?? "",
            ])
        }
    }
}
