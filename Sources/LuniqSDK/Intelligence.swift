// Intelligence.swift — minimal on-device intelligence interface.
//
// The canonical LuniqSDK ships with predictive-cohort *targeting* baked into
// GuideEngine and SurveyEngine, but NOT a full intelligence engine. Host apps
// that want predictive targeting plug in their own snapshot provider (typically
// powered by an IntelligenceEngine — see the reference implementation in the
// GIA app under HPulseSDK/Intelligence.swift).
//
// To enable predictive cohorts in your app:
//
//   Luniq.shared.setIntelligenceProvider {
//       LuniqIntelligenceSnapshot(
//           persona: myEngine.persona(),
//           churnRisk: myEngine.churnRisk,
//           sessionScore: myEngine.sessionScore,
//           conversionProbability: myEngine.conversionProb
//       )
//   }
//
// If no provider is registered, guides with `predictiveCohort` audience criteria
// simply never fire. Static `audience.match` rules continue to work unchanged.

import Foundation

/// A snapshot of the host app's on-device user intelligence, evaluated at the
/// moment a guide/banner/survey is being considered for display.
public struct LuniqIntelligenceSnapshot {
    /// Persona label: power_user / explorer / struggler / first_time / loyalist /
    /// churner / browser. Use the same vocabulary your IntelligenceEngine emits.
    public let persona: String
    /// Predicted churn risk, 0-100 (higher = more likely to churn).
    public let churnRisk: Int
    /// Session worth score, 0-100 (higher = more valuable session for analysis).
    public let sessionScore: Int
    /// Predicted conversion probability, 0-100.
    public let conversionProbability: Int

    public init(persona: String,
                churnRisk: Int,
                sessionScore: Int,
                conversionProbability: Int) {
        self.persona = persona
        self.churnRisk = churnRisk
        self.sessionScore = sessionScore
        self.conversionProbability = conversionProbability
    }
}
