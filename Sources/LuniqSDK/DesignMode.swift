// DesignMode.swift — pairs a debug build of the host app to the Pulse dashboard
// over a WebSocket relay so the user (PM/designer) can preview unpublished
// guides/banners/surveys on the real device before they go live.
//
// Entry points:
//   Luniq.shared.enableDesignMode()                 — shows pairing code prompt
//   Luniq.shared.enableDesignMode(code: "abc123")   — pairs immediately
//
// Compiled into all builds, but the shake-to-enter UI is gated on a debug flag
// the host app must opt into (LuniqConfig.designModeEnabled).

import Foundation
import UIKit

@objc public final class LuniqDesignMode: NSObject, URLSessionWebSocketDelegate {

    @objc public static let shared = LuniqDesignMode()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var endpoint: String = ""
    private var apiKey: String = ""
    private var code: String?
    private var captureTimer: Timer?
    private var screen: String = "unknown"
    private weak var overlay: LuniqDesignOverlayView?
    private var connected = false

    private override init() { super.init() }

    @objc public func configure(endpoint: String, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    @objc public func startPairing() {
        DispatchQueue.main.async { [weak self] in self?.presentCodePrompt() }
    }

    @objc public func pair(code: String) {
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !endpoint.isEmpty, let pairCode = self.code, !pairCode.isEmpty else { return }
        let wsBase = endpoint
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        guard let url = URL(string: "\(wsBase)/v1/design/ws/\(pairCode)/sdk") else { return }
        let cfg = URLSessionConfiguration.default
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Luniq-Key")
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        let t = s.webSocketTask(with: req)
        self.session = s
        self.task = t
        t.resume()
        listen()
        DispatchQueue.main.async { [weak self] in self?.installOverlay() }
    }

    @objc public func disconnect() {
        captureTimer?.invalidate(); captureTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; session = nil; connected = false
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.removeFromSuperview()
            BannerPreviewView.clear()
        }
    }

    @objc public func reportScreen(_ name: String) {
        screen = name
        send(["type": "screen", "name": name])
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        connected = true
        send(["type": "hello", "platform": "ios", "device": UIDevice.current.model, "os": UIDevice.current.systemVersion])
        startCapture()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connected = false
        captureTimer?.invalidate(); captureTimer = nil
        DispatchQueue.main.async { [weak self] in self?.overlay?.setStatus("disconnected") }
    }

    // MARK: - Capture loop

    private func startCapture() {
        captureTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.setStatus("paired")
            self?.captureTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                self?.captureFrame()
            }
            self?.captureFrame()
        }
    }

    private func captureFrame() {
        guard connected else { return }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else { return }

        // Render at full logical points × @2x — sharp on Retina dashboard
        // displays without sending the full @3x native pixel buffer.
        // Cap longest edge at 1200 px so iPad screens don't blow up the payload.
        let logicalSize = window.bounds.size
        let targetPxScale: CGFloat = {
            let longestEdge = max(logicalSize.width, logicalSize.height) * 2
            if longestEdge > 1200 { return 1200 / max(logicalSize.width, logicalSize.height) }
            return 2.0
        }()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = targetPxScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: logicalSize, format: format)
        let img = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = img.jpegData(compressionQuality: 0.75) else { return }
        send([
            "type":   "frame",
            "format": "jpeg",
            "width":  Int(logicalSize.width  * targetPxScale),
            "height": Int(logicalSize.height * targetPxScale),
            "screen": screen,
            "data":   data.base64EncodedString()
        ])
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(_):
                self.connected = false
                return
            case .success(let msg):
                switch msg {
                case .string(let s):
                    if let data = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(message: obj)
                    }
                case .data(let d):
                    if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        self.handle(message: obj)
                    }
                @unknown default: break
                }
                self.listen()
            }
        }
    }

    private func handle(message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        switch type {
        case "preview_guide":
            if let g = message["guide"] as? [String: Any] {
                DesignPreviewer.previewGuide(g)
                NotificationCenter.default.post(name: .LuniqDesignPreviewGuide, object: nil, userInfo: ["guide": g])
            }
        case "preview_banner":
            if let b = message["banner"] as? [String: Any] {
                DesignPreviewer.previewBanner(b)
                NotificationCenter.default.post(name: .LuniqDesignPreviewBanner, object: nil, userInfo: ["banner": b])
            }
        case "preview_survey":
            if let s = message["survey"] as? [String: Any] {
                DesignPreviewer.previewSurvey(s)
                NotificationCenter.default.post(name: .LuniqDesignPreviewSurvey, object: nil, userInfo: ["survey": s])
            }
        case "fire_event":
            if let n = message["name"] as? String {
                Luniq.shared.track(n, properties: ["__pulse_design": true])
            }
        case "navigate":
            if let s = message["screen"] as? String {
                NotificationCenter.default.post(name: .LuniqDesignNavigate, object: nil, userInfo: ["screen": s])
            }
        case "exit_design_mode":
            disconnect()
        default: break
        }
    }

    private func send(_ obj: [String: Any]) {
        guard connected, let task = task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { _ in }
    }

    // MARK: - Pairing UI

    private func presentCodePrompt() {
        let alert = UIAlertController(title: "Luniq.AI Design Mode", message: "Enter the 6-character code from the dashboard.", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "abc123"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.keyboardType = .asciiCapable
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Pair", style: .default, handler: { [weak self, weak alert] _ in
            let code = alert?.textFields?.first?.text ?? ""
            self?.pair(code: code)
        }))
        topViewController()?.present(alert, animated: true)
    }

    private func installOverlay() {
        guard overlay == nil else { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else { return }
        let v = LuniqDesignOverlayView(frame: window.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.onExit = { [weak self] in self?.disconnect() }
        window.addSubview(v)
        overlay = v
    }

    private func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let root = base ?? scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        if let nav = root as? UINavigationController { return topViewController(base: nav.visibleViewController) }
        if let tab = root as? UITabBarController { return topViewController(base: tab.selectedViewController) }
        if let presented = root?.presentedViewController { return topViewController(base: presented) }
        return root
    }
}

public extension Foundation.Notification.Name {
    static let LuniqDesignPreviewGuide  = Foundation.Notification.Name("LuniqDesignPreviewGuide")
    static let LuniqDesignPreviewBanner = Foundation.Notification.Name("LuniqDesignPreviewBanner")
    static let LuniqDesignPreviewSurvey = Foundation.Notification.Name("LuniqDesignPreviewSurvey")
    static let LuniqDesignNavigate      = Foundation.Notification.Name("LuniqDesignNavigate")
}

/// Persistent banner overlay shown while design mode is active. Communicates state
/// to the user, gives them an exit button, and is non-interactive elsewhere so the
/// app behaves normally underneath.
final class LuniqDesignOverlayView: UIView {
    private let pill = UILabel()
    private let exitBtn = UIButton(type: .system)
    var onExit: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.text = "● LUNIQ.AI DESIGN MODE — connecting…"
        pill.textColor = .white
        pill.font = .systemFont(ofSize: 11, weight: .bold)
        pill.backgroundColor = UIColor(red: 0.76, green: 0.52, blue: 0.42, alpha: 0.95)
        pill.textAlignment = .center
        pill.layer.cornerRadius = 12
        pill.layer.masksToBounds = true
        addSubview(pill)
        exitBtn.translatesAutoresizingMaskIntoConstraints = false
        exitBtn.setTitle("Exit", for: .normal)
        exitBtn.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        exitBtn.setTitleColor(.white, for: .normal)
        exitBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        exitBtn.layer.cornerRadius = 10
        exitBtn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        exitBtn.addTarget(self, action: #selector(handleExit), for: .touchUpInside)
        addSubview(exitBtn)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pill.heightAnchor.constraint(equalToConstant: 24),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: exitBtn.leadingAnchor, constant: -8),
            exitBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            exitBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            exitBtn.heightAnchor.constraint(equalToConstant: 24),
        ])
        isUserInteractionEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ status: String) {
        if status == "paired" {
            pill.text = "● LUNIQ.AI DESIGN MODE — paired"
        } else {
            pill.text = "● LUNIQ.AI DESIGN MODE — \(status)"
        }
    }

    // Pass-through hit testing — only the pill + exit button are interactive.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let exitFrame = exitBtn.frame.insetBy(dx: -8, dy: -8)
        if exitFrame.contains(point) { return exitBtn }
        return nil
    }

    @objc private func handleExit() { onExit?() }
}

// MARK: - Luniq facade

public extension Luniq {
    @objc func enableDesignMode() {
        configureDesignModeIfNeeded()
        LuniqDesignMode.shared.startPairing()
    }
    @objc func enableDesignMode(code: String) {
        configureDesignModeIfNeeded()
        LuniqDesignMode.shared.pair(code: code)
    }
    @objc func reportScreenForDesignMode(_ name: String) {
        LuniqDesignMode.shared.reportScreen(name)
    }

    /// Handle a Pulse pairing URL — works for either:
    ///   - Custom scheme: `pulse-design://CODE` (or whatever your workspace scheme is)
    ///   - Universal Link: `https://ingest.uselunaai.com/pair/CODE`
    @discardableResult
    @objc func handleDesignModeURL(_ url: URL) -> Bool {
        let code = pairingCode(from: url)
        guard !code.isEmpty else { return false }
        configureDesignModeIfNeeded()
        LuniqDesignMode.shared.pair(code: code)
        return true
    }

    /// Handle a Universal Link `NSUserActivity` — call from SwiftUI `.onContinueUserActivity`
    /// or SceneDelegate `scene(_:continue:)`.
    @discardableResult
    @objc func handleDesignModeUserActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else { return false }
        return handleDesignModeURL(url)
    }

    private func pairingCode(from url: URL) -> String {
        if let scheme = url.scheme?.lowercased(),
           scheme != "http" && scheme != "https",
           let host = url.host, !host.isEmpty {
            return host
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0].lowercased() == "pair" {
            return parts[1]
        }
        return ""
    }

    /// Enable shake-to-pair. Once enabled, shaking the device while in any UIKit
    /// scene presents the Design Mode pairing dialog. Safe to call from production
    /// builds — but most teams gate this behind their own debug flag.
    @objc func enableShakeToDesignMode() {
        configureDesignModeIfNeeded()
        LuniqShakeBridge.installOnce()
    }

    internal func configureDesignModeIfNeeded() {
        if let cfg = self.config {
            LuniqDesignMode.shared.configure(endpoint: cfg.endpoint, apiKey: cfg.apiKey)
        }
    }
}

/// Method-swizzles `UIWindow.motionEnded(_:with:)` so any shake gesture in the
/// host app triggers the Pulse pairing dialog. Idempotent — calling
/// `installOnce()` more than once is a no-op.
final class LuniqShakeBridge {
    private static var installed = false

    static func installOnce() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIWindow.self
        let originalSel = #selector(UIResponder.motionEnded(_:with:))
        let swizzledSel = #selector(UIWindow.luniq_motionEnded(_:with:))
        guard let originalMethod = class_getInstanceMethod(cls, originalSel),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSel) else { return }
        // We add the swizzled implementation if the class doesn't define motionEnded
        // itself, otherwise we exchange. UIWindow inherits from UIResponder so the
        // method is on UIResponder; class_addMethod ensures we install on UIWindow.
        let didAdd = class_addMethod(cls, originalSel,
                                     method_getImplementation(swizzledMethod),
                                     method_getTypeEncoding(swizzledMethod))
        if didAdd {
            class_replaceMethod(cls, swizzledSel,
                                method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }
}

extension UIWindow {
    @objc func luniq_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            // Open the Design Mode pairing dialog. Ignore re-entrance — DesignMode
            // already guards against multiple presentations.
            Luniq.shared.enableDesignMode()
        }
        // Forward to the original implementation (now installed at the swizzled
        // selector on UIWindow). If the class didn't override the original, this
        // selector won't exist on UIWindow but `UIResponder` will handle it.
        if responds(to: #selector(luniq_motionEnded(_:with:))) {
            // call through to swapped original (avoid infinite loop by going to super)
            super.motionEnded(motion, with: event)
        }
    }
}

/// Renders draft Guides/Banners/Surveys received from the dashboard so the PM
/// can see exactly how the content looks on the real device — no host-app
/// integration required. Bypasses normal trigger/audience/cohort filtering
/// because previews are explicitly requested by the dashboard user.
enum DesignPreviewer {

    static func previewGuide(_ dict: [String: Any]) {
        guard let guide = decode(PulseGuide.self, from: dict) else {
            showFallback(title: "Couldn't preview guide", body: "The guide data was malformed.")
            return
        }
        DispatchQueue.main.async {
            BannerPreviewView.clear()
            dismissCurrent {
                GuideRenderer.render(guide, dismiss: { _ in })
            }
        }
    }

    static func previewSurvey(_ dict: [String: Any]) {
        guard let survey = decode(PulseSurvey.self, from: dict) else {
            showFallback(title: "Couldn't preview survey", body: "The survey data was malformed.")
            return
        }
        DispatchQueue.main.async {
            BannerPreviewView.clear()
            dismissCurrent {
                SurveyRenderer.render(survey) { _, _ in }
            }
        }
    }

    static func previewBanner(_ dict: [String: Any]) {
        DispatchQueue.main.async {
            // No dismissCurrent here — banner previews update in place to avoid
            // re-animation flicker on every keystroke during live editing.
            BannerPreviewView.show(from: dict)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func dismissCurrent(then: @escaping () -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        if let presented = root?.presentedViewController {
            presented.dismiss(animated: false, completion: then)
        } else {
            then()
        }
    }

    private static func showFallback(title: String, body: String) {
        DispatchQueue.main.async {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard let vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
            let a = UIAlertController(title: title, message: body, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .cancel))
            vc.present(a, animated: true)
        }
    }
}

/// Inline banner overlay used for design-mode previews. Persists for the whole
/// design session — content updates in place when the dashboard sends a new
/// payload (no remove/re-add flicker during live editing). Pan-draggable so the
/// PM can position it freely on the device. Dismissed only when design mode
/// exits or a different draft kind is previewed.
final class BannerPreviewView: UIView {
    static weak var current: BannerPreviewView?

    private let titleLabel = UILabel()
    private let bodyLabel  = UILabel()
    private let ctaButton  = UIButton(type: .system)
    private var leadingC: NSLayoutConstraint?
    private var trailingC: NSLayoutConstraint?
    private var topC: NSLayoutConstraint?
    /// Once the user drags the banner manually we stop letting incoming previews
    /// reset the position — they keep their content updates but the banner
    /// stays where the PM put it.
    private var userPositioned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupChrome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func setupChrome() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.numberOfLines = 0
        bodyLabel.font  = .systemFont(ofSize: 12, weight: .regular)
        bodyLabel.numberOfLines = 0
        ctaButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        ctaButton.layer.borderWidth = 1
        ctaButton.layer.cornerRadius = 8
        ctaButton.contentEdgeInsets = .init(top: 6, left: 12, bottom: 6, right: 12)

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, ctaButton])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        // Pan gesture so the PM can drag the banner to a precise position on
        // the device. Once dragged, server-side position updates are ignored.
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))
        isUserInteractionEnabled = true
    }

    func applyContent(title: String, body: String, cta: String, bg: UIColor, text: UIColor) {
        backgroundColor = bg
        titleLabel.text = title
        titleLabel.textColor = text
        bodyLabel.text  = body
        bodyLabel.textColor = text.withAlphaComponent(0.92)
        bodyLabel.isHidden  = body.isEmpty
        ctaButton.setTitle(cta, for: .normal)
        ctaButton.setTitleColor(text, for: .normal)
        ctaButton.layer.borderColor = text.withAlphaComponent(0.6).cgColor
    }

    /// Set position from normalized (0–1) coordinates within the parent window.
    func applyNormalizedPosition(nx: CGFloat, ny: CGFloat) {
        guard let parent = superview else { return }
        let h = parent.bounds.height
        let banded = max(0.05, min(0.95, ny))
        // Center horizontally on nx; clamp so banner stays on screen.
        let halfW = bounds.width / 2
        let centerX = parent.bounds.width * nx
        let lead = max(8, centerX - halfW)
        let trail = min(-8, -(parent.bounds.width - (centerX + halfW)))
        leadingC?.constant  = lead
        trailingC?.constant = trail
        topC?.constant      = h * banded - 40
        userPositioned = false
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        userPositioned = true
        let t = g.translation(in: parent)
        leadingC?.constant  += t.x
        trailingC?.constant += t.x
        topC?.constant      += t.y
        g.setTranslation(.zero, in: parent)
    }

    @objc fileprivate func remove() {
        userPositioned = false
        UIView.animate(withDuration: 0.18, animations: { self.alpha = 0 },
                       completion: { _ in self.removeFromSuperview() })
        if BannerPreviewView.current === self { BannerPreviewView.current = nil }
    }

    static func show(from dict: [String: Any]) {
        let title    = (dict["title"] as? String)
                    ?? (dict["headline"] as? String)
                    ?? (dict["name"] as? String)
                    ?? "Banner preview"
        let body     = (dict["body"] as? String)
                    ?? (dict["message"] as? String)
                    ?? (dict["copy"] as? String)
                    ?? ""
        let cta      = (dict["cta"] as? String) ?? "Learn more"
        let bgHex    = (dict["bg_color"] as? String) ?? (dict["background"] as? String)
        let textHex  = (dict["text_color"] as? String) ?? (dict["color"] as? String)
        let bg       = color(bgHex) ?? UIColor.systemBlue
        let text     = color(textHex) ?? .white

        // Optional normalized position. If absent on this update, the banner
        // keeps whatever position it currently has (default bottom-of-screen
        // for first show, or wherever the dashboard/PM last placed it).
        let pos = dict["position"] as? [String: Any]
        let nxOpt = pos?["x"] as? Double
        let nyOpt = pos?["y"] as? Double
        let isFirstShow = (current == nil || current?.window == nil)
        let nx = CGFloat(nxOpt ?? 0.5)
        let ny = CGFloat(nyOpt ?? 0.82)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) else { return }

        // Update in place if we already have one — no flicker.
        if let v = current, v.window != nil {
            v.applyContent(title: title, body: body, cta: cta, bg: bg, text: text)
            // Only reposition when dashboard explicitly sent coords. This
            // preserves any pan-drag the PM did directly on the device.
            if nxOpt != nil || nyOpt != nil {
                v.applyNormalizedPosition(nx: nx, ny: ny)
            }
            return
        }

        let v = BannerPreviewView()
        window.addSubview(v)
        let leading  = v.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: 16)
        let trailing = v.trailingAnchor.constraint(equalTo: window.trailingAnchor, constant: -16)
        let top = v.topAnchor.constraint(equalTo: window.topAnchor, constant: window.bounds.height * ny - 40)
        v.leadingC = leading
        v.trailingC = trailing
        v.topC = top
        NSLayoutConstraint.activate([leading, trailing, top])
        v.applyContent(title: title, body: body, cta: cta, bg: bg, text: text)
        v.alpha = 0
        UIView.animate(withDuration: 0.2) { v.alpha = 1 }
        current = v
        _ = isFirstShow
    }

    /// Tear down any existing banner — call from DesignPreviewer when the PM
    /// switches to a different draft kind (guide/survey).
    static func clear() {
        current?.remove()
    }

    private static func color(_ hex: String?) -> UIColor? {
        guard let hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue:  CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return UIColor(red: CGFloat((v >> 24) & 0xFF) / 255,
                       green: CGFloat((v >> 16) & 0xFF) / 255,
                       blue:  CGFloat((v >> 8) & 0xFF) / 255,
                       alpha: CGFloat(v & 0xFF) / 255)
    }
}
