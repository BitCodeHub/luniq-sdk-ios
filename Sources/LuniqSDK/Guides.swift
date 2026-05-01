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

    public init(id: String, name: String, kind: String,
                trigger: [String: AnyCodable], audience: [String: AnyCodable],
                steps: [[String: AnyCodable]], variants: [PulseGuideVariant]? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.trigger = trigger; self.audience = audience
        self.steps = steps; self.variants = variants
    }
}

/// A single variant of a multi-variant guide. The autonomous variant picker (in
/// GuideEngine) selects one per user based on the variant's audience criteria
/// (predictiveCohort + match) at render time. AI-native: no manual A/B setup;
/// the SDK picks the variant most likely to fit the current user's persona.
public struct PulseGuideVariant: Codable {
    public let id: String
    public let label: String?               // human-friendly label, e.g. "Concise"
    public let weight: Double?              // optional — defaults to 1.0 among matching variants
    public let audience: [String: AnyCodable]
    public let steps: [[String: AnyCodable]]
}

final class GuideEngine {
    private let config: LuniqConfig
    private let track: (String, [String: Any]) -> Void
    private var guides: [PulseGuide] = []
    private var shownIds: Set<String> = []
    private let defaults = UserDefaults(suiteName: "ai.luniq.sdk") ?? .standard
    // Versioned key — bumped to v2 to invalidate prior cache entries that
    // were written by the old show() flow (which marked a guide as shown
    // before the modal actually presented). Reading from a fresh slot
    // means we don't carry over false-positive "shown" claims that block
    // the actual render forever.
    private let kShown = "luniq.guides.shown.v4"
    private var recentEvents: [(event: String, screen: String?, traits: [String: Any])] = []
    private let recentMax = 20
    // Currently visible guide IDs — prevents stacking when "once" is false
    private var visibleIds: Set<String> = []
    // Per-session shown — prevents re-rendering the same guide repeatedly even with once=false
    private var sessionShown: Set<String> = []

    init(config: LuniqConfig, track: @escaping (String, [String: Any]) -> Void) {
        self.config = config
        self.track = track
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
                DispatchQueue.main.async {
                    self.guides = g
                    self.replayRecentEvents()
                }
            }
        }.resume()
    }

    func evaluate(eventName: String, screenName: String?, traits: [String: Any]) {
        DispatchQueue.main.async {
            self.recentEvents.append((eventName, screenName, traits))
            if self.recentEvents.count > self.recentMax {
                self.recentEvents.removeFirst(self.recentEvents.count - self.recentMax)
            }
            Logger.log("Guides.evaluate event=\(eventName) screen=\(screenName ?? "-") guides_count=\(self.guides.count) visibleIds=\(self.visibleIds.count) shownIds=\(self.shownIds.count) sessionShown=\(self.sessionShown.count)")
            if !self.visibleIds.isEmpty { return }
            for g in self.guides {
                if self.shownIds.contains(g.id) && (g.trigger["once"]?.value as? Bool ?? true) {
                    Logger.log("Guides.evaluate skip g=\(g.id) reason=already_shown")
                    continue
                }
                if self.sessionShown.contains(g.id) {
                    Logger.log("Guides.evaluate skip g=\(g.id) reason=session_shown")
                    continue
                }
                if !self.matchesTrigger(g, event: eventName, screen: screenName) {
                    Logger.log("Guides.evaluate skip g=\(g.id) reason=trigger_mismatch trig=\(g.trigger)")
                    continue
                }
                if !self.matchesAudience(g, traits: traits) {
                    Logger.log("Guides.evaluate skip g=\(g.id) reason=audience_mismatch")
                    continue
                }
                if !self.matchesPredictiveCohort(g) {
                    Logger.log("Guides.evaluate skip g=\(g.id) reason=cohort_mismatch")
                    continue
                }
                Logger.log("Guides.evaluate SHOW g=\(g.id) name=\(g.name) kind=\(g.kind)")
                self.show(g)
                break
            }
        }
    }

    // When guides arrive from the server after events have already fired
    // (common on cold launch), replay the recent events against the newly
    // loaded guides so triggers like app_open aren't missed.
    private func replayRecentEvents() {
        if !visibleIds.isEmpty { return }
        for ev in recentEvents {
            for g in guides {
                if shownIds.contains(g.id) && (g.trigger["once"]?.value as? Bool ?? true) { continue }
                if sessionShown.contains(g.id) { continue }
                if !matchesTrigger(g, event: ev.event, screen: ev.screen) { continue }
                if !matchesAudience(g, traits: ev.traits) { continue }
                if !matchesPredictiveCohort(g) { continue }
                show(g)
                return
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

    /// AI-native predictive-cohort matching against on-device IntelligenceEngine.
    /// Skipped (treated as no-match) until intelligence has warmed up.
    private func matchesPredictiveCohort(_ g: PulseGuide) -> Bool {
        guard let pc = g.audience["predictiveCohort"]?.value as? [String: Any], !pc.isEmpty else { return true }
        guard Luniq.shared.profile() != nil else { return false } // wait until intelligence warms up
        if let personas = pc["persona"] as? [String], !personas.isEmpty, !personas.contains(Luniq.shared.persona()) { return false }
        if !inBand(Luniq.shared.predictChurn(),           pc["churnRisk"])             { return false }
        if !inBand(Luniq.shared.sessionScore(),           pc["sessionScore"])          { return false }
        if !inBand(Luniq.shared.conversionProbability(),  pc["conversionProbability"]) { return false }
        return true
    }

    private func inBand(_ value: Int, _ band: Any?) -> Bool {
        guard let b = band as? [String: Any] else { return true }
        if let mn = b["min"] as? Int, value < mn { return false }
        if let mx = b["max"] as? Int, value > mx { return false }
        return true
    }

    private func show(_ g: PulseGuide) {
        // Autonomous variant picker — if the guide ships multiple variants, score each
        // against the current user's intelligence and pick the highest match. Falls
        // back to the legacy `steps` field for single-variant guides.
        let pickedVariantId: String?
        let renderGuide: PulseGuide
        if let variants = g.variants, !variants.isEmpty {
            guard let v = pickVariant(variants, for: g) else {
                // No variant matched the user — skip this guide entirely.
                return
            }
            pickedVariantId = v.id
            renderGuide = PulseGuide(id: g.id, name: g.name, kind: g.kind,
                                     trigger: g.trigger, audience: g.audience,
                                     steps: v.steps, variants: nil)
        } else {
            pickedVariantId = nil
            renderGuide = g
        }

        // Claim the slot for this session/visibility so a concurrent
        // evaluate() doesn't double-render. We DO NOT persist to
        // UserDefaults on first present — that only happens on an
        // *explicit* permanent dismissal (see the dismiss reasons below).
        // A backdrop tap or app close keeps the guide eligible for the
        // next app launch.
        sessionShown.insert(g.id)
        visibleIds.insert(g.id)

        GuideRenderer.render(renderGuide, didPresent: { [weak self] in
            guard let self else { return }
            var props: [String: Any] = ["guide_id": g.id, "guide_name": g.name]
            if let vid = pickedVariantId { props["variant_id"] = vid }
            self.track("$guide_shown", props)
        }, dismiss: { [weak self] reason in
            guard let self else { return }
            // step_advance is a transient "moving to next step" signal
            // emitted by the bubble between tour steps. Keep visibleIds +
            // sessionShown set so a racing evaluate() doesn't re-render
            // the same tour from step 0 while the next step is being set
            // up. Telemetry still fires.
            let intermediate = (reason == "step_advance")
            if !intermediate {
                self.visibleIds.remove(g.id)
            }
            let permanent = (reason == "permanently_dismissed" || reason == "completed")
            if !intermediate && !permanent {
                // Visitor closed without confirming permanent dismissal —
                // let it re-fire on the next matching trigger / launch.
                self.sessionShown.remove(g.id)
            }
            if permanent {
                self.shownIds.insert(g.id)
                self.defaults.set(Array(self.shownIds), forKey: self.kShown)
            }
            var dprops: [String: Any] = ["guide_id": g.id, "guide_name": g.name, "reason": reason]
            if let vid = pickedVariantId { dprops["variant_id"] = vid }
            self.track("$guide_\(reason)", dprops)
        })
    }

    /// Picks the best-matching variant for the current user.
    /// Strategy: filter variants whose audience matches (static + predictiveCohort),
    /// then pick by weight (defaults to equal). Returns nil if none match.
    private func pickVariant(_ variants: [PulseGuideVariant], for g: PulseGuide) -> PulseGuideVariant? {
        let eligible = variants.filter { v in
            // static match
            if let m = v.audience["match"]?.value as? [String: Any], !m.isEmpty {
                // We don't have traits at this point — defer to predictive only.
            }
            // predictive cohort
            if let pc = v.audience["predictiveCohort"]?.value as? [String: Any], !pc.isEmpty {
                guard Luniq.shared.profile() != nil else { return false }
                if let personas = pc["persona"] as? [String], !personas.isEmpty, !personas.contains(Luniq.shared.persona()) { return false }
                if !inBand(Luniq.shared.predictChurn(),           pc["churnRisk"])             { return false }
                if !inBand(Luniq.shared.sessionScore(),           pc["sessionScore"])          { return false }
                if !inBand(Luniq.shared.conversionProbability(),  pc["conversionProbability"]) { return false }
            }
            return true
        }
        guard !eligible.isEmpty else { return nil }
        // Weighted random sample. Default weight 1.0.
        let totalWeight = eligible.reduce(0.0) { $0 + ($1.weight ?? 1.0) }
        var pick = Double.random(in: 0..<totalWeight)
        for v in eligible {
            pick -= v.weight ?? 1.0
            if pick <= 0 { return v }
        }
        return eligible.last
    }
}

enum GuideRenderer {
    static func render(_ guide: PulseGuide, didPresent: (() -> Void)? = nil, dismiss: @escaping (String) -> Void) {
        guard let step = guide.steps.first else { return }
        switch guide.kind {
        case "modal": renderModal(guide: guide, step: step, didPresent: didPresent, dismiss: dismiss)
        case "banner": renderBanner(guide: guide, step: step, dismiss: dismiss)
        case "slideout": renderSlideout(guide: guide, step: step, dismiss: dismiss)
        case "tooltip", "tour":
            // Tooltip + tour share the bubble renderer. Single-step
            // tooltips show one bubble; multi-step ("tour") guides walk
            // through each step in order, repositioning over each step's
            // anchor.
            renderTour(guide: guide, didPresent: didPresent, dismiss: dismiss)
        default: renderModal(guide: guide, step: step, didPresent: didPresent, dismiss: dismiss)
        }
    }

    private static func topVC() -> UIViewController? {
        // Find any window scene; prefer foreground-active, fall back to any.
        // At app_open time the scene can briefly be .foregroundInactive while
        // SwiftUI attaches the rootViewController — silently dropping the
        // render then leaves the modal invisible forever. Retry callers
        // handle the still-nil case via withTopVC below.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    /// Run `action` once a top view controller is available, retrying on the
    /// main run loop with exponential-ish backoff. Caps at ~5s of retries —
    /// after that we give up rather than hold a guide hostage forever.
    private static func withTopVC(_ action: @escaping (UIViewController) -> Void) {
        func attempt(_ retriesLeft: Int, delay: TimeInterval) {
            if let vc = topVC() {
                Logger.log("Guides.withTopVC FOUND vc=\(type(of: vc))")
                action(vc)
                return
            }
            Logger.log("Guides.withTopVC nil retriesLeft=\(retriesLeft) delay=\(delay)")
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                attempt(retriesLeft - 1, delay: min(delay * 1.4, 1.0))
            }
        }
        attempt(20, delay: 0.1)
    }

    private static func title(_ step: [String: AnyCodable]) -> String { (step["title"]?.value as? String) ?? "" }
    private static func body(_ step: [String: AnyCodable]) -> String { (step["body"]?.value as? String) ?? "" }
    private static func cta(_ step: [String: AnyCodable]) -> String { (step["cta"]?.value as? String) ?? "OK" }

    private static func renderModal(guide: PulseGuide, step: [String: AnyCodable], didPresent: (() -> Void)?, dismiss: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title(step), message: body(step), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: cta(step), style: .default, handler: { _ in dismiss("completed") }))
        alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler: { _ in dismiss("dismissed") }))
        withTopVC { $0.present(alert, animated: true, completion: { didPresent?() }) }
    }

    private static func renderBanner(guide: PulseGuide, step: [String: AnyCodable], dismiss: @escaping (String) -> Void) {
        let imageURL = step["imageUrl"]?.value as? String
        if let imageURL, !imageURL.isEmpty {
            renderImageBanner(guide: guide, step: step, imageURL: imageURL, dismiss: dismiss)
        } else {
            renderTextBanner(guide: guide, step: step, dismiss: dismiss)
        }
    }

    private static func renderTextBanner(guide: PulseGuide, step: [String: AnyCodable], dismiss: @escaping (String) -> Void) {
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

    // Genesis-style marketing banner: 338×343 pt card, 1:1 square image,
    // overlaid title/body, CTA, tappable to open linkUrl.
    private static func renderImageBanner(guide: PulseGuide, step: [String: AnyCodable], imageURL: String, dismiss: @escaping (String) -> Void) {
        guard let vc = topVC(), let url = URL(string: resolveImageURL(imageURL)) else { return }

        let card = UIView()
        card.backgroundColor = UIColor.black
        card.layer.cornerRadius = 12
        card.layer.masksToBounds = true
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.masksToBounds = false
        card.translatesAutoresizingMaskIntoConstraints = false

        let clipper = UIView()
        clipper.layer.cornerRadius = 12
        clipper.layer.masksToBounds = true
        clipper.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clipper)

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .darkGray
        imageView.translatesAutoresizingMaskIntoConstraints = false
        clipper.addSubview(imageView)

        let gradient = CAGradientLayer()
        gradient.colors = [UIColor.black.withAlphaComponent(0.55).cgColor,
                           UIColor.clear.cgColor,
                           UIColor.clear.cgColor,
                           UIColor.black.withAlphaComponent(0.75).cgColor]
        gradient.locations = [0.0, 0.35, 0.60, 1.0]
        let gradientHost = UIView()
        gradientHost.translatesAutoresizingMaskIntoConstraints = false
        gradientHost.isUserInteractionEnabled = false
        gradientHost.layer.addSublayer(gradient)
        clipper.addSubview(gradientHost)

        let titleLabel = UILabel()
        titleLabel.text = title(step)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        clipper.addSubview(titleLabel)

        let bodyLabel = UILabel()
        bodyLabel.text = body(step)
        bodyLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.numberOfLines = 2
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        clipper.addSubview(bodyLabel)

        let ctaText = cta(step)
        let ctaView = UIView()
        ctaView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        ctaView.layer.cornerRadius = 8
        ctaView.translatesAutoresizingMaskIntoConstraints = false
        clipper.addSubview(ctaView)

        let ctaLabel = UILabel()
        ctaLabel.text = ctaText
        ctaLabel.textColor = .white
        ctaLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        ctaLabel.translatesAutoresizingMaskIntoConstraints = false
        ctaView.addSubview(ctaLabel)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        closeButton.layer.cornerRadius = 18
        closeButton.layer.borderWidth = 1.5
        closeButton.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        clipper.addSubview(closeButton)

        vc.view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            card.heightAnchor.constraint(equalTo: card.widthAnchor),

            clipper.topAnchor.constraint(equalTo: card.topAnchor),
            clipper.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            clipper.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            clipper.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: clipper.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: clipper.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: clipper.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: clipper.bottomAnchor),

            gradientHost.topAnchor.constraint(equalTo: clipper.topAnchor),
            gradientHost.leadingAnchor.constraint(equalTo: clipper.leadingAnchor),
            gradientHost.trailingAnchor.constraint(equalTo: clipper.trailingAnchor),
            gradientHost.bottomAnchor.constraint(equalTo: clipper.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: clipper.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: clipper.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyLabel.leadingAnchor.constraint(equalTo: clipper.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: clipper.trailingAnchor, constant: -16),

            closeButton.topAnchor.constraint(equalTo: clipper.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: clipper.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            ctaView.bottomAnchor.constraint(equalTo: clipper.bottomAnchor, constant: -14),
            ctaView.trailingAnchor.constraint(equalTo: clipper.trailingAnchor, constant: -14),
            ctaLabel.topAnchor.constraint(equalTo: ctaView.topAnchor, constant: 8),
            ctaLabel.bottomAnchor.constraint(equalTo: ctaView.bottomAnchor, constant: -8),
            ctaLabel.leadingAnchor.constraint(equalTo: ctaView.leadingAnchor, constant: 14),
            ctaLabel.trailingAnchor.constraint(equalTo: ctaView.trailingAnchor, constant: -14),
        ])

        // Async image load
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async { imageView.image = img }
        }.resume()

        // Gradient layer follows bounds
        card.layoutIfNeeded()
        gradient.frame = gradientHost.bounds
        DispatchQueue.main.async { gradient.frame = gradientHost.bounds }

        // Tap opens linkUrl — gesture delegate ignores touches that land on the close button
        let linkURL = step["linkUrl"]?.value as? String
        let tap = UITapGestureRecognizer()
        let gateKey = "card-\(ObjectIdentifier(card).hashValue)"
        BannerTapDelegate.shared.skipIfTouchInside(key: gateKey, view: closeButton)
        tap.delegate = BannerTapDelegate.shared
        tap.accessibilityHint = gateKey  // used by the delegate
        tap.addTarget(BannerTapProxy.shared, action: #selector(BannerTapProxy.handle(_:)))
        BannerTapProxy.shared.store(tap: tap) {
            if let s = linkURL, let u = URL(string: s) {
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
            }
            UIView.animate(withDuration: 0.2, animations: { card.alpha = 0 }) { _ in
                card.removeFromSuperview(); dismiss("completed")
            }
        }
        card.addGestureRecognizer(tap)
        card.isUserInteractionEnabled = true

        if #available(iOS 14.0, *) {
            closeButton.addAction(UIAction { _ in
                UIView.animate(withDuration: 0.2, animations: { card.alpha = 0 }) { _ in
                    card.removeFromSuperview(); dismiss("dismissed")
                }
            }, for: .touchUpInside)
        }

        // Slide up animation
        card.transform = CGAffineTransform(translationX: 0, y: 200); card.alpha = 0
        UIView.animate(withDuration: 0.35) { card.transform = .identity; card.alpha = 1 }
    }

    // Resolve relative URLs (e.g. "/v1/banners/image/abc") against the SDK endpoint.
    private static func resolveImageURL(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        guard let cfg = Luniq.shared.currentConfig() else { return raw }
        let base = cfg.endpoint.hasSuffix("/") ? String(cfg.endpoint.dropLast()) : cfg.endpoint
        return base + (raw.hasPrefix("/") ? raw : "/" + raw)
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

    /// Bubble / coachmark renderer. Reads `step["anchor"]` for an
    /// accessibilityIdentifier on a UIView in the host app, then draws a
    /// dimmed backdrop with a spotlight cutout around that view and a
    /// bubble (text + dismiss) pointing at it. Falls back to slideout if
    /// no anchor is provided or no matching view is found in the
    /// hierarchy.
    /// Tour / single-step tooltip renderer. If guide.steps.count > 1,
    /// walks the visitor through the steps with Next/Back navigation and
    /// a final confirm-on-dismiss. Single-step shows one bubble.
    private static func renderTour(guide: PulseGuide, didPresent: (() -> Void)?, dismiss: @escaping (String) -> Void) {
        let steps = guide.steps
        guard !steps.isEmpty else { dismiss("no_steps"); return }
        var didFireDidPresent = false
        showStep(steps: steps, index: 0, didPresent: {
            if !didFireDidPresent {
                didFireDidPresent = true
                didPresent?()
            }
        }, dismiss: dismiss)
    }

    /// Present step `index` of a multi-step tour. Recursively re-enters
    /// itself when the visitor taps Next, so each transition fully tears
    /// down the previous bubble before resolving the next anchor.
    private static func showStep(steps: [[String: AnyCodable]], index: Int, didPresent: @escaping () -> Void, dismiss: @escaping (String) -> Void) {
        let step = steps[index]
        let anchorId = (step["anchor"]?.value as? String) ?? ""
        guard !anchorId.isEmpty else {
            // No anchor → fall back to a slideout for this step. End the
            // tour here since slideouts are full-width and can't chain
            // smoothly with bubble steps.
            withTopVC { _ in renderSlideout(guide: PulseGuide(id: "_tour_step", name: "tour", kind: "slideout", trigger: [:], audience: [:], steps: [step]), step: step, dismiss: dismiss) }
            return
        }
        withTopVC { vc in
            findAnchorRetrying(id: anchorId, vc: vc, retriesLeft: 12, delay: 0.15) { resolved in
                guard let resolved else {
                    Logger.log("Guides.showStep anchor=\(anchorId) NOT FOUND after retries — ending tour with temp dismiss")
                    dismiss("anchor_missing")
                    return
                }
                presentBubble(
                    anchorFrame: resolved,
                    in: vc,
                    step: step,
                    stepIndex: index,
                    totalSteps: steps.count,
                    didPresent: didPresent,
                    onNext: {
                        // Move to next step on the next runloop tick so
                        // the dismissal animation completes first.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            showStep(steps: steps, index: index + 1, didPresent: didPresent, dismiss: dismiss)
                        }
                    },
                    dismiss: dismiss
                )
            }
        }
    }

    private static func findAnchorRetrying(id: String, vc: UIViewController, retriesLeft: Int, delay: TimeInterval, completion: @escaping (CGRect?) -> Void) {
        // 1. Prefer SwiftUI-registered global frame.
        if let f = Luniq.shared.anchorFrame(for: id), f.width > 0, f.height > 0 {
            completion(f); return
        }
        // 2. Fall back to UIView tree traversal by accessibilityIdentifier.
        let root: UIView? = vc.view.window ?? vc.view
        if let root, let v = findView(byAccessibilityIdentifier: id, in: root) {
            let host: UIView = v.window ?? v
            completion(v.convert(v.bounds, to: host)); return
        }
        Logger.log("Guides.findAnchor id=\(id) miss retriesLeft=\(retriesLeft) delay=\(delay)")
        guard retriesLeft > 0 else { completion(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            findAnchorRetrying(id: id, vc: vc, retriesLeft: retriesLeft - 1, delay: min(delay * 1.4, 1.2), completion: completion)
        }
    }

    private static func findView(byAccessibilityIdentifier id: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == id { return root }
        for sub in root.subviews {
            if let found = findView(byAccessibilityIdentifier: id, in: sub) { return found }
        }
        return nil
    }

    private static func presentBubble(
        anchorFrame: CGRect,
        in vc: UIViewController,
        step: [String: AnyCodable],
        stepIndex: Int = 0,
        totalSteps: Int = 1,
        didPresent: (() -> Void)?,
        onNext: (() -> Void)? = nil,
        dismiss: @escaping (String) -> Void
    ) {
        guard let host: UIView = vc.view.window ?? vc.view else { return }
        let titleText = title(step)
        let bodyText  = body(step)
        let isLastStep = (stepIndex >= totalSteps - 1)
        // Final step uses the step's CTA ("Got it"); intermediate steps
        // use a Next label so the visitor knows there's more.
        let ctaText = isLastStep ? cta(step) : "Next"

        // Semi-transparent backdrop with a punch-out around the anchor.
        // CAShapeLayer + even-odd fill gives a clean spotlight without
        // additional UIView siblings.
        let backdrop = UIView(frame: host.bounds)
        backdrop.backgroundColor = .clear
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        let mask = CAShapeLayer()
        let cutout = UIBezierPath(roundedRect: anchorFrame.insetBy(dx: -8, dy: -8), cornerRadius: 12)
        let outer = UIBezierPath(rect: host.bounds)
        outer.append(cutout)
        outer.usesEvenOddFillRule = true
        mask.path = outer.cgPath
        mask.fillRule = .evenOdd
        let shade = CAShapeLayer()
        shade.path = outer.cgPath
        shade.fillRule = .evenOdd
        shade.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        backdrop.layer.addSublayer(shade)
        host.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        // Bubble card.
        let bubble = UIView()
        bubble.backgroundColor = UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        bubble.layer.cornerRadius = 16
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.35
        bubble.layer.shadowRadius = 16
        bubble.layer.shadowOffset = CGSize(width: 0, height: 6)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bubble)

        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = UILabel()
        bodyLabel.text = bodyText
        bodyLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        let dismissBtn = UIButton(type: .system)
        dismissBtn.setTitle(ctaText, for: .normal)
        dismissBtn.setTitleColor(UIColor(red: 0.78, green: 0.54, blue: 0.36, alpha: 1), for: .normal)
        dismissBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        dismissBtn.contentHorizontalAlignment = .trailing
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false

        // Optional step indicator + skip button (only for tours).
        let isTour = totalSteps > 1
        let stepLabel = UILabel()
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        stepLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        stepLabel.text = isTour ? "STEP \(stepIndex + 1) OF \(totalSteps)" : ""

        let skipBtn = UIButton(type: .system)
        skipBtn.translatesAutoresizingMaskIntoConstraints = false
        skipBtn.setTitle("Skip tour", for: .normal)
        skipBtn.setTitleColor(UIColor.white.withAlphaComponent(0.55), for: .normal)
        skipBtn.titleLabel?.font = .systemFont(ofSize: 13)
        skipBtn.isHidden = !isTour || isLastStep   // hide on last step (use Got it)
        skipBtn.contentHorizontalAlignment = .leading

        bubble.addSubview(titleLabel)
        bubble.addSubview(bodyLabel)
        bubble.addSubview(dismissBtn)
        if isTour {
            bubble.addSubview(stepLabel)
            bubble.addSubview(skipBtn)
        }

        // Arrow caret pointing toward the anchor.
        let arrowSize: CGFloat = 12
        let arrow = UIView()
        arrow.backgroundColor = .clear
        arrow.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(arrow)
        let arrowShape = CAShapeLayer()
        arrowShape.fillColor = bubble.backgroundColor?.cgColor
        arrow.layer.addSublayer(arrowShape)

        // Decide whether the bubble sits above or below the anchor based
        // on which side has more room. Default = above (most tab bars are
        // at the bottom).
        let spaceAbove = anchorFrame.minY
        let spaceBelow = host.bounds.height - anchorFrame.maxY
        let placeAbove = spaceAbove >= spaceBelow

        // Bubble layout. The step indicator + skip button live in a row
        // below the body, on the opposite side of the primary CTA.
        var common: [NSLayoutConstraint] = [
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            bubble.centerXAnchor.constraint(equalTo: host.leadingAnchor, constant: max(160, min(host.bounds.width - 160, anchorFrame.midX))),

            titleLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),

            dismissBtn.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 12),
            dismissBtn.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
            dismissBtn.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
        ]
        if isTour {
            common.append(contentsOf: [
                stepLabel.centerYAnchor.constraint(equalTo: dismissBtn.centerYAnchor),
                stepLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
                skipBtn.centerYAnchor.constraint(equalTo: dismissBtn.centerYAnchor),
                skipBtn.leadingAnchor.constraint(equalTo: stepLabel.trailingAnchor, constant: 12),
            ])
        }
        NSLayoutConstraint.activate(common)

        if placeAbove {
            NSLayoutConstraint.activate([
                bubble.bottomAnchor.constraint(equalTo: host.topAnchor, constant: anchorFrame.minY - arrowSize - 4),
            ])
        } else {
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: host.topAnchor, constant: anchorFrame.maxY + arrowSize + 4),
            ])
        }

        // Position the arrow exactly between bubble and anchor.
        host.layoutIfNeeded()
        let arrowX = max(16, min(host.bounds.width - 16 - arrowSize, anchorFrame.midX - arrowSize / 2))
        let arrowY: CGFloat = placeAbove ? anchorFrame.minY - arrowSize - 2 : anchorFrame.maxY + 2
        arrow.frame = CGRect(x: arrowX, y: arrowY, width: arrowSize, height: arrowSize)
        let arrowPath = UIBezierPath()
        if placeAbove {
            arrowPath.move(to: CGPoint(x: 0, y: 0))
            arrowPath.addLine(to: CGPoint(x: arrowSize, y: 0))
            arrowPath.addLine(to: CGPoint(x: arrowSize / 2, y: arrowSize))
        } else {
            arrowPath.move(to: CGPoint(x: 0, y: arrowSize))
            arrowPath.addLine(to: CGPoint(x: arrowSize, y: arrowSize))
            arrowPath.addLine(to: CGPoint(x: arrowSize / 2, y: 0))
        }
        arrowPath.close()
        arrowShape.path = arrowPath.cgPath
        arrowShape.frame = arrow.bounds

        // Animate in.
        bubble.alpha = 0
        bubble.transform = CGAffineTransform(translationX: 0, y: placeAbove ? 8 : -8)
        arrow.alpha = 0
        backdrop.alpha = 0
        UIView.animate(withDuration: 0.28) {
            backdrop.alpha = 1
            bubble.alpha = 1
            bubble.transform = .identity
            arrow.alpha = 1
        }

        // Three close paths:
        //   - dismiss button → confirm sheet → permanent OR cancel-keep-visible
        //   - backdrop tap   → temporary close (reappears next launch)
        //   - app exit       → no event; visibleIds cleared on next start
        // Only "permanently_dismissed" and "completed" persist to
        // UserDefaults; everything else leaves the guide eligible to
        // re-fire on the next matching trigger.
        let close: (String) -> Void = { reason in
            UIView.animate(withDuration: 0.18, animations: {
                bubble.alpha = 0
                arrow.alpha = 0
                backdrop.alpha = 0
            }, completion: { _ in
                bubble.removeFromSuperview()
                arrow.removeFromSuperview()
                backdrop.removeFromSuperview()
                dismiss(reason)
            })
        }
        let confirmThenClose: () -> Void = {
            withTopVC { presenter in
                let confirm = UIAlertController(
                    title: "Want to see this tip again?",
                    message: "Tap Yes to keep it appearing the next time you open the app.",
                    preferredStyle: .alert
                )
                confirm.addAction(UIAlertAction(title: "Yes", style: .default) { _ in
                    // Visitor wants it again — close bubble but keep
                    // eligible for the next matching trigger.
                    close("user_wants_again")
                })
                confirm.addAction(UIAlertAction(title: "No", style: .destructive) { _ in
                    close("permanently_dismissed")
                })
                presenter.present(confirm, animated: true)
            }
        }
        if #available(iOS 14.0, *) {
            // CTA button:
            //   - Final step (or single tooltip): "Got it" → confirm Yes/No
            //   - Intermediate tour step: "Next" → close current bubble + advance
            dismissBtn.addAction(UIAction { _ in
                if isLastStep {
                    confirmThenClose()
                } else {
                    close("step_advance")
                    onNext?()
                }
            }, for: .touchUpInside)
            // Skip button: end whole tour without confirm prompt — visitor
            // can re-trigger the tour next launch since this isn't a
            // permanent dismissal.
            if isTour {
                skipBtn.addAction(UIAction { _ in close("temporarily_dismissed") }, for: .touchUpInside)
            }
        }
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: BubbleTapProxy.shared, action: #selector(BubbleTapProxy.handle(_:))))
        BubbleTapProxy.shared.store(handler: { close("temporarily_dismissed") }, for: backdrop)

        didPresent?()
    }
}

/// Lightweight tap-handler bridge so the bubble can capture backdrop taps
/// without forcing every caller to retain a target object.
final class BubbleTapProxy: NSObject {
    static let shared = BubbleTapProxy()
    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    func store(handler: @escaping () -> Void, for view: UIView) {
        handlers[ObjectIdentifier(view)] = handler
    }

    @objc func handle(_ gr: UITapGestureRecognizer) {
        guard let v = gr.view else { return }
        let key = ObjectIdentifier(v)
        if let h = handlers[key] {
            handlers[key] = nil
            h()
        }
    }
}

final class BannerTapProxy: NSObject {
    static let shared = BannerTapProxy()
    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    func store(tap: UITapGestureRecognizer, handler: @escaping () -> Void) {
        handlers[ObjectIdentifier(tap)] = handler
    }

    @objc func handle(_ gr: UITapGestureRecognizer) {
        if let h = handlers[ObjectIdentifier(gr)] {
            handlers[ObjectIdentifier(gr)] = nil
            h()
        }
    }
}

/// Gesture delegate that suppresses banner-card tap when the touch lands on the
/// close button (so the card's link-open and the X-close don't both fire).
final class BannerTapDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = BannerTapDelegate()
    private var skipViews: [String: WeakBox] = [:]

    func skipIfTouchInside(key: String, view: UIView) {
        skipViews[key] = WeakBox(view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let key = gestureRecognizer.accessibilityHint, let box = skipViews[key], let v = box.value else {
            return true
        }
        let touchedView = touch.view
        var node: UIView? = touchedView
        while let n = node {
            if n === v { return false } // don't fire card-tap if the close button was hit
            node = n.superview
        }
        return true
    }
}

private final class WeakBox {
    weak var value: UIView?
    init(_ v: UIView) { self.value = v }
}
