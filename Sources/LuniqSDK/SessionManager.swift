import Foundation
import UIKit

final class SessionManager {
    private(set) var currentId: String = UUID().uuidString
    private var lastActivity: Date = Date()
    private let timeout: TimeInterval = 30 * 60
    /// Fired every time the app becomes active (cold launch + foreground).
    /// Wired by Luniq.start() to track an "app_open" event so triggers can match.
    var onActive: ((_ wasNewSession: Bool) -> Void)?

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func didBecomeActive() {
        let wasNewSession = Date().timeIntervalSince(lastActivity) > timeout
        if wasNewSession {
            currentId = UUID().uuidString
        }
        lastActivity = Date()
        onActive?(wasNewSession)
    }

    @objc private func didEnterBackground() {
        lastActivity = Date()
    }
}
