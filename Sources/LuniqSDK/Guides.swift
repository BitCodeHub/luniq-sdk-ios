import Foundation
import UIKit

public struct PulseGuide: Codable {
    public let id: String
    public let name: String
    public let kind: String          // tooltip | modal | slideout | banner
    public let trigger: [String: AnyCodable]
    public let audience: [String: AnyCodable]
    public let steps: [[String: AnyCodable]]
    public let variants: [PulseGuideVariant]?
}

/// One variant in a multi-variant guide. The autonomous variant picker selects
/// one per user using on-device intelligence.
public struct PulseGuideVariant: Codable {
    public let id: String
    public let label: String?
    public let weight: Double?
    public let audience: [String: AnyCodable]
    public let steps: [[String: AnyCodable]]
}

final class GuideEngine {
    private let config: LuniqConfig
    private let track: (String, [String: Any]) -> Void
    /// Closure returning a snapshot of on-device intelligence (persona, churn, session
    /// score, conversion probability). Used for predictive-cohort audience matching.
    /// Returns nil when intelligence isn't available (e.g. immediately after launch).
    private let intelligence: () -> LuniqIntelligenceSnapshot?
    private var guides: [PulseGuide] = []
    private var shownIds: Set<String> = []
    private let defaults = UserDefaults(suiteName: "ai.luniq.sdk") ?? .standard
    private let kShown = "luniq.guides.shown"

    init(config: LuniqConfig,
         track: @escaping (String, [String: Any]) -> Void,
         intelligence: @escaping () -> LuniqIntelligenceSnapshot? = { nil }) {
        self.config = config
        self.track = track
        self.intelligence = intelligence
        self.shownIds = Set(defaults.stringArray(forKey: kShown) ?? [])
    }

    func fetchGuides() {
        guard let url = URL(string: "\(config.endpoint)/v1/sdk/guides") else { return }
        var req = URLRequest(url: url)
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data else { return }
            let decoder = JSONDecoder()
            if let g = try? decoder.decode([PulseGuide].self, from: data) {
                DispatchQueue.main.async { self.guides = g }
            }
        }.resume()
    }

    func evaluate(eventName: String, screenName: String?, traits: [String: Any]) {
        DispatchQueue.main.async {
            for g in self.guides {
                if self.shownIds.contains(g.id) && (g.trigger["once"]?.value as? Bool ?? true) { continue }
                if !self.matchesTrigger(g, event: eventName, screen: screenName) { continue }
                if !self.matchesAudience(g, traits: traits) { continue }
                if !self.matchesPredictiveCohort(g) { continue }
                self.show(g)
                break
            }
        }
    }

    private func matchesTrigger(_ g: PulseGuide, event: String, screen: String?) -> Bool {
        if let onEvent = g.trigger["onEvent"]?.value as? String, onEvent == event { return true }
        if let onScreen = g.trigger["onScreen"]?.value as? String, onScreen == (screen ?? "") { return true }
        return false
    }

    private func matchesAudience(_ g: PulseGuide, traits: [String: Any]) -> Bool {
        guard let match = g.audience["match"]?.value as? [String: Any], !match.isEmpty else { return true }
        for (k, v) in match {
            if "\(traits[k] ?? "")" != "\(v)" { return false }
        }
        return true
    }

    /// Predictive-cohort matching — the AI-native targeting layer. The dashboard can
    /// configure audience.predictiveCohort with on-device intelligence dimensions:
    ///   - persona: ["power_user","explorer",...]   match if current persona is in list
    ///   - churnRisk: { min: 60, max: 100 }         match if predicted churn falls in band
    ///   - sessionScore: { min: 70 }                match on session worth band
    ///   - conversionProbability: { min: 50 }       match on predicted conversion
    /// Missing fields aren't constraints. Returns true when no predictiveCohort is set
    /// (so existing guides with only static audience.match continue to work unchanged).
    private func matchesPredictiveCohort(_ g: PulseGuide) -> Bool {
        guard let pc = g.audience["predictiveCohort"]?.value as? [String: Any], !pc.isEmpty else { return true }
        guard let snap = intelligence() else {
            // Intelligence not yet available — skip predictive guides until it warms up.
            return false
        }
        if let personas = pc["persona"] as? [String], !personas.isEmpty, !personas.contains(snap.persona) { return false }
        if !inBand(snap.churnRisk,             pc["churnRisk"])             { return false }
        if !inBand(snap.sessionScore,          pc["sessionScore"])          { return false }
        if !inBand(snap.conversionProbability, pc["conversionProbability"]) { return false }
        return true
    }

    private func inBand(_ value: Int, _ band: Any?) -> Bool {
        guard let b = band as? [String: Any] else { return true }
        if let mn = b["min"] as? Int, value < mn { return false }
        if let mx = b["max"] as? Int, value > mx { return false }
        return true
    }

    private func show(_ g: PulseGuide) {
        shownIds.insert(g.id)
        defaults.set(Array(shownIds), forKey: kShown)
        track("$guide_shown", ["guide_id": g.id, "guide_name": g.name])
        GuideRenderer.render(g, dismiss: { [weak self] reason in
            self?.track("$guide_\(reason)", ["guide_id": g.id, "guide_name": g.name])
        })
    }
}

enum GuideRenderer {
    static func render(_ guide: PulseGuide, dismiss: @escaping (String) -> Void) {
        guard let step = guide.steps.first else { return }
        switch guide.kind {
        case "modal": renderModal(guide: guide, step: step, dismiss: dismiss)
        case "banner": renderBanner(guide: guide, step: step, dismiss: dismiss)
        case "slideout": renderSlideout(guide: guide, step: step, dismiss: dismiss)
        case "tooltip": renderTooltip(guide: guide, step: step, dismiss: dismiss)
        default: renderModal(guide: guide, step: step, dismiss: dismiss)
        }
    }

    private static func topVC() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    private static func title(_ step: [String: AnyCodable]) -> String { (step["title"]?.value as? String) ?? "" }
    private static func body(_ step: [String: AnyCodable]) -> String { (step["body"]?.value as? String) ?? "" }
    private static func cta(_ step: [String: AnyCodable]) -> String { (step["cta"]?.value as? String) ?? "OK" }

    private static func renderModal(guide: PulseGuide, step: [String: AnyCodable], dismiss: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title(step), message: body(step), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: cta(step), style: .default, handler: { _ in dismiss("completed") }))
        alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler: { _ in dismiss("dismissed") }))
        topVC()?.present(alert, animated: true)
    }

    private static func renderBanner(guide: PulseGuide, step: [String: AnyCodable], dismiss: @escaping (String) -> Void) {
        guard let vc = topVC() else { return }
        let banner = UIView(frame: .zero)
        banner.backgroundColor = UIColor(red: 0.15, green: 0.40, blue: 0.95, alpha: 1)
        banner.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel(); label.text = body(step); label.textColor = .white; label.numberOfLines = 2
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        vc.view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 56),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            UIView.animate(withDuration: 0.3, animations: { banner.alpha = 0 }) { _ in
                banner.removeFromSuperview()
                dismiss("completed")
            }
        }
    }

    private static func renderSlideout(guide: PulseGuide, step: [String: AnyCodable], dismiss: @escaping (String) -> Void) {
        guard let vc = topVC() else { return }
        let card = UIView(); card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14; card.layer.shadowOpacity = 0.18; card.layer.shadowRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        let t = UILabel(); t.text = title(step); t.font = .systemFont(ofSize: 17, weight: .semibold)
        let b = UILabel(); b.text = body(step); b.numberOfLines = 0; b.font = .systemFont(ofSize: 14)
        let btn = UIButton(type: .system); btn.setTitle(cta(step), for: .normal)
        btn.setTitleColor(.white, for: .normal); btn.backgroundColor = .systemBlue
        btn.layer.cornerRadius = 8; btn.contentEdgeInsets = .init(top: 10, left: 18, bottom: 10, right: 18)
        [t, b, btn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }
        vc.view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            t.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            t.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            t.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            b.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 8),
            b.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            b.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            btn.topAnchor.constraint(equalTo: b.bottomAnchor, constant: 14),
            btn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            btn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        card.transform = CGAffineTransform(translationX: 0, y: 200); card.alpha = 0
        UIView.animate(withDuration: 0.35) { card.transform = .identity; card.alpha = 1 }
        if #available(iOS 14.0, *) {
            btn.addAction(UIAction { _ in
                UIView.animate(withDuration: 0.2, animations: { card.alpha = 0 }) { _ in
                    card.removeFromSuperview(); dismiss("completed")
                }
            }, for: .touchUpInside)
        }
    }

    private static func renderTooltip(guide: PulseGuide, step: [String: AnyCodable], dismiss: @escaping (String) -> Void) {
        // Tooltips need an anchor; fall back to slideout if none provided
        renderSlideout(guide: guide, step: step, dismiss: dismiss)
    }
}
