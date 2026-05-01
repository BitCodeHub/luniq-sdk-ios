import Foundation
import UIKit

// On-device, top-most overlay that surfaces test runs to the user the same
// way a Selenium grid surfaces them in a browser: an obvious banner saying
// "automation is happening", a step counter, the current action, and an
// animated tap-ring at every synthesized touch point.
//
// Lives in its own UIWindow at .alert windowLevel so it sits above
// everything (sheets, modals, status bar). All interactions pass through
// to the underlying app — the overlay is purely visual.

// Not @MainActor — we already gate every call through DispatchQueue.main
// from the runner. Swift's strict-isolation check would reject the runner's
// nonisolated `runStep` calling main-actor methods even via main-queue
// dispatch, so we drop the annotation and trust the call-site discipline.
final class LiveTestOverlay {
    static let shared = LiveTestOverlay()
    private var window: UIWindow?
    private var banner: UIView?
    private var stepLabel: UILabel?
    private var actionLabel: UILabel?
    private var dotPulse: UIView?

    private init() {}

    func show(total: Int) {
        if window != nil { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else { return }

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 100
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        root.view.backgroundColor = .clear
        w.rootViewController = root
        w.isHidden = false
        window = w

        let safeTop = scene.windows.first?.safeAreaInsets.top ?? 44
        let bannerHeight: CGFloat = 56
        let b = UIView(frame: CGRect(x: 12, y: safeTop + 8,
                                     width: w.bounds.width - 24, height: bannerHeight))
        b.backgroundColor = UIColor(red: 0.78, green: 0.54, blue: 0.36, alpha: 0.96) // Luna accent
        b.layer.cornerRadius = 14
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.25
        b.layer.shadowRadius = 12
        b.layer.shadowOffset = CGSize(width: 0, height: 4)
        b.alpha = 0
        root.view.addSubview(b)

        let dot = UIView(frame: CGRect(x: 14, y: 22, width: 12, height: 12))
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 6
        b.addSubview(dot)
        dotPulse = dot
        addPulse(to: dot)

        let title = UILabel(frame: CGRect(x: 36, y: 8, width: b.bounds.width - 44, height: 18))
        title.text = "🧪 Luna AI is testing this app"
        title.textColor = .white
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        b.addSubview(title)

        let step = UILabel(frame: CGRect(x: 36, y: 26, width: 100, height: 14))
        step.text = "step 0 / \(total)"
        step.textColor = UIColor(white: 1, alpha: 0.85)
        step.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        b.addSubview(step)
        stepLabel = step

        let action = UILabel(frame: CGRect(x: 136, y: 26, width: b.bounds.width - 144, height: 14))
        action.text = "preparing…"
        action.textColor = .white
        action.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        action.adjustsFontSizeToFitWidth = true
        action.minimumScaleFactor = 0.7
        b.addSubview(action)
        actionLabel = action

        banner = b
        UIView.animate(withDuration: 0.25) { b.alpha = 1; b.transform = .identity }
        b.transform = CGAffineTransform(translationX: 0, y: -8)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
                       options: [], animations: { b.transform = .identity })
    }

    func update(stepIndex: Int, total: Int, label: String) {
        stepLabel?.text = "step \(stepIndex + 1) / \(total)"
        actionLabel?.text = label
    }

    func flashFailure(_ label: String) {
        banner?.backgroundColor = UIColor(red: 0.86, green: 0.20, blue: 0.20, alpha: 0.96)
        actionLabel?.text = "✕ failed: \(label)"
    }

    func hide() {
        guard let w = window, let b = banner else { window = nil; return }
        UIView.animate(withDuration: 0.25, animations: {
            b.alpha = 0
            b.transform = CGAffineTransform(translationX: 0, y: -8)
        }, completion: { _ in
            w.isHidden = true
            self.window = nil
            self.banner = nil
            self.stepLabel = nil
            self.actionLabel = nil
            self.dotPulse = nil
        })
    }

    /// Show a 60pt expanding ring at `pt` to signal a synthesized tap, the
    /// way Playwright's `slow-mo` highlights a click.
    func animateTouch(at pt: CGPoint) {
        guard let win = window, let root = win.rootViewController?.view else { return }
        let size: CGFloat = 60
        let ring = UIView(frame: CGRect(x: pt.x - size/2, y: pt.y - size/2, width: size, height: size))
        ring.layer.cornerRadius = size / 2
        ring.layer.borderWidth = 3
        ring.layer.borderColor = UIColor(red: 0.78, green: 0.54, blue: 0.36, alpha: 1).cgColor
        ring.backgroundColor = UIColor(red: 0.78, green: 0.54, blue: 0.36, alpha: 0.18)
        ring.isUserInteractionEnabled = false
        ring.transform = .init(scaleX: 0.4, y: 0.4)
        root.addSubview(ring)
        UIView.animate(withDuration: 0.55, delay: 0, options: [.curveEaseOut], animations: {
            ring.transform = .init(scaleX: 1.4, y: 1.4)
            ring.alpha = 0
        }, completion: { _ in ring.removeFromSuperview() })
    }

    private func addPulse(to view: UIView) {
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.4
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        view.layer.add(pulse, forKey: "pulse")
    }
}
