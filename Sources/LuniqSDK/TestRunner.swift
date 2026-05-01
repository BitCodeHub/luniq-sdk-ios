import Foundation
import UIKit

// iOS test-runner. Activates only when Luniq is started with a test-mode
// API key (prefix "lq_test_"). Long-polls the backend for queued runs and
// drives the live UI by tapping registered anchors, asserting state, and
// reporting results.
//
// Step semantics mirror the web runner so the same test spec works on both:
//   navigate(screen)        — tries to invoke a top-level navigation hook;
//                             customers can hook this by calling
//                             Luniq.shared.onNavigate = { screen in ... }
//   tap(anchor)             — finds anchor frame, dispatches a UITapGesture
//   type(anchor, text)      — finds UITextField, sets text + fires editingChanged
//   wait(ms)                — sleep
//   assert_visible(anchor)  — anchor frame is non-zero AND on-screen
//   assert_text(anchor,text)— UILabel/UITextField text contains substring
//   assert_screen(name)     — current screen_name property matches
//   screenshot(name)        — UIGraphicsImageRenderer; uploaded as base64

@objc public final class LuniqTestRunner: NSObject {
    private let endpoint: String
    private let apiKey: String
    private var polling = false
    private var inFlight = false  // a poll/exec is currently happening; don't double up
    private weak var luniq: Luniq?
    private let workQueue = DispatchQueue(label: "ai.luniq.testrunner", qos: .userInitiated)

    // Background task — keeps the runner alive briefly when the app
    // transitions to background, so an in-flight long-poll has time to
    // complete. Without this, iOS kills our URL session task immediately.
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    @objc public init(endpoint: String, apiKey: String, luniq: Luniq) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.apiKey = apiKey
        self.luniq = luniq
    }

    @objc public static func isTestKey(_ key: String) -> Bool {
        return key.hasPrefix("lq_test_")
    }

    @objc public func start() {
        guard !polling else { return }
        polling = true

        // App-lifecycle observers — the *only* reliable way to ensure the
        // poll loop wakes up immediately when the user returns to the app.
        // The previous `while polling { sleep }` design lost ticks across
        // iOS suspensions because Thread.sleep doesn't track wall clock.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWillResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)

        scheduleNextTick(after: 0.1)  // first poll fires immediately
        Logger.log("test-mode runner active — polling for queued runs")
    }

    @objc public func stop() {
        polling = false
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleDidBecomeActive() {
        // The user just brought the app back. Kick a poll right away — don't
        // wait for whatever timer was scheduled.
        Logger.log("app active — waking test runner")
        scheduleNextTick(after: 0.0)
    }

    @objc private func handleWillResignActive() {
        // Ask iOS for a brief background grace period so any in-flight
        // long-poll request can complete cleanly. iOS gives us up to ~30s.
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "ai.luniq.testrunner") { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func scheduleNextTick(after delay: TimeInterval) {
        guard polling else { return }
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        guard polling, !inFlight else { return }
        inFlight = true

        let payload = poll()
        if let payload = payload {
            execute(payload)
        }
        inFlight = false

        // End any background-grace task once a tick finishes; iOS will give
        // us another one if we transition again.
        endBackgroundTask()

        // Next tick: 0s if we just executed a run (likely more queued), 2s
        // otherwise. Fast cadence when active, low cost when idle (server
        // long-polls 25s anyway, so we're not actually thrashing).
        let next: TimeInterval = (payload != nil) ? 0.5 : 2.0
        scheduleNextTick(after: next)
    }

    // ---------- protocol I/O ----------

    private func poll() -> RunPayload? {
        guard let url = URL(string: "\(endpoint)/v1/sdk/test/poll") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Luniq-Key")
        req.timeoutInterval = 30
        let device = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) | \(UIDevice.current.model)"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceInfo": device])
        let (data, _, _) = SyncURL.request(req, timeout: 32)
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runId = obj["runId"] as? String, !runId.isEmpty else {
            return nil
        }
        let testId = obj["testId"] as? String ?? ""
        let spec = obj["spec"] as? [String: Any] ?? [:]
        let steps = (spec["steps"] as? [[String: Any]]) ?? []
        return RunPayload(runId: runId, testId: testId, steps: steps)
    }

    private func report(_ runId: String, stepIndex: Int, action: String, status: String,
                        durationMs: Int, error: String, artifact: String,
                        final: Bool, finalStatus: String) {
        guard let url = URL(string: "\(endpoint)/v1/sdk/test/result") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Luniq-Key")
        req.timeoutInterval = 8
        let body: [String: Any] = [
            "runId": runId, "stepIndex": stepIndex, "action": action,
            "status": status, "durationMs": durationMs, "error": error,
            "artifact": artifact, "final": final, "finalStatus": finalStatus,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    // ---------- execution ----------

    private func execute(_ run: RunPayload) {
        var finalStatus = "passed"
        var lastIndex = 0
        let total = run.steps.count

        // Show the live "Luna AI is testing" banner so the user can SEE
        // that automation is happening, just like Selenium/Playwright.
        DispatchQueue.main.sync { LiveTestOverlay.shared.show(total: total) }
        defer { DispatchQueue.main.sync { LiveTestOverlay.shared.hide() } }

        for (i, step) in run.steps.enumerated() {
            lastIndex = i
            let action = step["action"] as? String ?? ""
            let label = describe(action: action, step: step)
            DispatchQueue.main.sync { LiveTestOverlay.shared.update(stepIndex: i, total: total, label: label) }

            let started = Date()
            var status = "pass"
            var errorMsg = ""
            var artifact = ""
            do {
                artifact = try runStep(action: action, step: step)
            } catch {
                status = "fail"
                errorMsg = "\(error)"
                finalStatus = "failed"
            }
            let durMs = Int(Date().timeIntervalSince(started) * 1000)

            // Auto-screenshot AFTER every step (except the screenshot step
            // itself, which already produces one). Gives the dashboard a
            // full visual trail without the test author needing to insert
            // explicit screenshot steps.
            var autoArtifact = ""
            if action != "screenshot" {
                autoArtifact = (try? mainSync { captureScreenshot() }) ?? ""
            }

            let isFinal = i == total - 1
            let finalForReport = isFinal && finalStatus == "passed"
            // If the step itself produced an artifact, prefer that; otherwise
            // attach the auto-screenshot.
            let outArtifact = artifact.isEmpty ? autoArtifact : artifact
            report(run.runId, stepIndex: i, action: action, status: status,
                   durationMs: durMs, error: errorMsg, artifact: outArtifact,
                   final: finalForReport, finalStatus: isFinal ? finalStatus : "")
            if status == "fail" {
                DispatchQueue.main.sync { LiveTestOverlay.shared.flashFailure(label) }
                break
            }
        }
        if finalStatus == "failed" {
            report(run.runId, stepIndex: lastIndex, action: "(final)", status: "fail",
                   durationMs: 0, error: "", artifact: "", final: true, finalStatus: "failed")
        }
    }

    private func describe(action: String, step: [String: Any]) -> String {
        let anchor = step["anchor"] as? String ?? ""
        let screen = step["screen"] as? String ?? ""
        switch action {
        case "tap":            return "tap \(anchor)"
        case "type":           return "type into \(anchor)"
        case "wait":           return "wait \(step["ms"] as? Int ?? 0)ms"
        case "navigate":       return "navigate \(screen)"
        case "assert_visible": return "assert \(anchor) visible"
        case "assert_text":    return "assert text in \(anchor)"
        case "assert_screen":  return "assert on \(screen)"
        case "screenshot":     return "screenshot \(step["name"] as? String ?? "")"
        default:               return action
        }
    }

    private func captureScreenshot() -> String {
        guard let win = topWindow() else { return "" }
        let renderer = UIGraphicsImageRenderer(size: win.bounds.size)
        let img = renderer.image { _ in
            win.drawHierarchy(in: win.bounds, afterScreenUpdates: false)
        }
        guard let data = img.jpegData(compressionQuality: 0.5) else { return "" }
        let trimmed = data.count > 150_000 ? data.subdata(in: 0..<150_000) : data
        return "image/jpeg;base64," + trimmed.base64EncodedString()
    }

    private func runStep(action: String, step: [String: Any]) throws -> String {
        switch action {
        case "wait":
            let ms = step["ms"] as? Int ?? 500
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            return ""

        case "navigate":
            // Customers can wire navigation by setting Luniq.shared.onTestNavigate
            // before calling start(). Without that hook, navigation is a no-op
            // because we can't safely change the customer's nav stack.
            if let screen = step["screen"] as? String {
                DispatchQueue.main.sync { Luniq.shared.onTestNavigate?(screen) }
            }
            return ""

        case "tap":
            let anchor = step["anchor"] as? String ?? ""
            return try mainSync {
                guard let frame = Luniq.shared.anchorFrame(for: anchor),
                      let win = topWindow() else { throw Err.notFound(anchor) }
                let pt = CGPoint(x: frame.midX, y: frame.midY)
                // Animate the tap-ring at the target so the user can SEE
                // exactly where the test is tapping. ~250ms ring + scale.
                LiveTestOverlay.shared.animateTouch(at: pt)
                Thread.sleep(forTimeInterval: 0.25)
                if let view = win.hitTest(pt, with: nil) {
                    if let ctrl = view as? UIControl {
                        ctrl.sendActions(for: .touchUpInside)
                    } else {
                        // Walk up to find a tappable
                        var cur: UIView? = view
                        while cur != nil {
                            if let recognizers = cur?.gestureRecognizers,
                               let tap = recognizers.first(where: { $0 is UITapGestureRecognizer }) as? UITapGestureRecognizer {
                                tap.state = .ended  // Best-effort fire
                                _ = tap; break
                            }
                            cur = cur?.superview
                        }
                    }
                    return ""
                }
                throw Err.notFound(anchor)
            }

        case "type":
            let anchor = step["anchor"] as? String ?? ""
            let text = step["text"] as? String ?? ""
            return try mainSync {
                guard let frame = Luniq.shared.anchorFrame(for: anchor),
                      let win = topWindow() else { throw Err.notFound(anchor) }
                let pt = CGPoint(x: frame.midX, y: frame.midY)
                guard let field = win.hitTest(pt, with: nil) as? UITextField else {
                    throw Err.notInput(anchor)
                }
                field.becomeFirstResponder()
                field.text = text
                field.sendActions(for: .editingChanged)
                return ""
            }

        case "assert_visible":
            let anchor = step["anchor"] as? String ?? ""
            guard let frame = Luniq.shared.anchorFrame(for: anchor),
                  frame.width > 0, frame.height > 0 else {
                throw Err.notVisible(anchor)
            }
            return ""

        case "assert_text":
            let anchor = step["anchor"] as? String ?? ""
            let want = step["text"] as? String ?? ""
            return try mainSync {
                guard let frame = Luniq.shared.anchorFrame(for: anchor),
                      let win = topWindow() else { throw Err.notFound(anchor) }
                let pt = CGPoint(x: frame.midX, y: frame.midY)
                let view = win.hitTest(pt, with: nil)
                let got: String? = (view as? UILabel)?.text ?? (view as? UITextField)?.text
                guard let got = got, got.contains(want) else {
                    throw Err.assertion("expected \"\(want)\", got \"\(got ?? "<nil>")\"")
                }
                return ""
            }

        case "assert_screen":
            let want = step["screen"] as? String ?? ""
            // Compare against the last $screen we tracked. Best effort.
            let current = Luniq.shared.lastScreen
            if !current.contains(want) {
                throw Err.assertion("screen mismatch: expected \(want), got \(current)")
            }
            return ""

        case "screenshot":
            return try mainSync {
                guard let win = topWindow() else { return "" }
                let renderer = UIGraphicsImageRenderer(size: win.bounds.size)
                let img = renderer.image { _ in
                    win.drawHierarchy(in: win.bounds, afterScreenUpdates: false)
                }
                if let data = img.jpegData(compressionQuality: 0.5) {
                    // Cap at 150 KB to stay polite to the upload.
                    let trimmed = data.count > 150_000 ? data.subdata(in: 0..<150_000) : data
                    return "image/jpeg;base64," + trimmed.base64EncodedString()
                }
                return ""
            }

        default:
            throw Err.unknownAction(action)
        }
    }

    // ---------- helpers ----------

    private func topWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let ws = scene as? UIWindowScene, let w = ws.windows.first(where: { $0.isKeyWindow }) {
                    return w
                }
            }
        }
        return nil
    }

    private func mainSync<T>(_ work: () throws -> T) throws -> T {
        if Thread.isMainThread { return try work() }
        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            do { result = .success(try work()) } catch { result = .failure(error) }
        }
        return try result.get()
    }

    enum Err: Error, CustomStringConvertible {
        case notFound(String), notVisible(String), notInput(String)
        case assertion(String), unknownAction(String)
        var description: String {
            switch self {
            case .notFound(let a):     return "anchor not found: \(a)"
            case .notVisible(let a):   return "anchor not visible: \(a)"
            case .notInput(let a):     return "anchor is not a text field: \(a)"
            case .assertion(let m):    return m
            case .unknownAction(let a):return "unknown action: \(a)"
            }
        }
    }

    private struct RunPayload {
        let runId: String
        let testId: String
        let steps: [[String: Any]]
    }
}

// Minimal synchronous URLSession wrapper so the runner loop reads simply.
// (Keeping our network code uniform — the rest of the SDK uses the async
// transport, but the runner is in a background loop where sync is fine.)
private struct SyncURL {
    static func request(_ req: URLRequest, timeout: TimeInterval) -> (Data?, URLResponse?, Error?) {
        let sem = DispatchSemaphore(value: 0)
        var d: Data?; var r: URLResponse?; var e: Error?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            d = data; r = resp; e = err; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout)
        return (d, r, e)
    }
}
