import Foundation
import UIKit

// Detects frustration signals from the tap stream:
//   $rage_click  — 3+ taps on same control within 2 seconds
//   $dead_click  — tap followed by no screen change or further interaction within 1.5s
final class FrustrationDetector {
    private let emit: (String, [String: Any]) -> Void
    private let ioQueue = DispatchQueue(label: "ai.luniq.sdk.frustration")
    private var recentTaps: [(controlId: String, at: Date, screen: String)] = []
    private var lastScreenChangeAt: Date = .distantPast
    private var rageEmittedFor: Set<String> = []  // control+screen already reported in this burst

    private let rageWindow: TimeInterval = 2.0
    private let rageThreshold = 3
    private let deadResponseWindow: TimeInterval = 1.5

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
    }

    func recordTap(controlId: String, screen: String) {
        ioQueue.async {
            let now = Date()
            self.recentTaps.append((controlId, now, screen))
            let cutoff = now.addingTimeInterval(-self.rageWindow)
            self.recentTaps = self.recentTaps.filter { $0.at >= cutoff }

            let key = "\(screen)|\(controlId)"
            let same = self.recentTaps.filter { $0.controlId == controlId && $0.screen == screen }
            if same.count >= self.rageThreshold && !self.rageEmittedFor.contains(key) {
                self.rageEmittedFor.insert(key)
                let durationMs = Int(now.timeIntervalSince(same.first!.at) * 1000)
                self.emit("$rage_click", [
                    "control": controlId,
                    "screen_name": screen,
                    "count": same.count,
                    "duration_ms": durationMs,
                ])
            }

            // Dead-click: no screen change within window after this tap
            let snapshot = self.lastScreenChangeAt
            self.ioQueue.asyncAfter(deadline: .now() + self.deadResponseWindow) {
                if self.lastScreenChangeAt <= snapshot {
                    // Only report if this control wasn't part of a rage burst (avoid double-counting)
                    if !self.rageEmittedFor.contains(key) {
                        self.emit("$dead_click", [
                            "control": controlId,
                            "screen_name": screen,
                        ])
                    }
                }
            }

            // Let rage burst reset after the window expires
            self.ioQueue.asyncAfter(deadline: .now() + self.rageWindow + 0.5) {
                self.rageEmittedFor.remove(key)
            }
        }
    }

    func recordScreenChange() {
        ioQueue.async {
            self.lastScreenChangeAt = Date()
        }
    }
}
