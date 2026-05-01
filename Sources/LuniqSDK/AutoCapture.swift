import Foundation
import UIKit
import ObjectiveC

final class AutoCaptureController {
    private let track: (String, [String: Any]) -> Void
    private static var installed = false

    init(track: @escaping (String, [String: Any]) -> Void) { self.track = track }

    func install(enabled: Bool) {
        guard enabled, !Self.installed else { return }
        Self.installed = true
        UIViewController.luniq_swizzleViewDidAppear(track: track)
        UIApplication.luniq_swizzleSendAction(track: track)
    }
}

extension UIViewController {
    static func luniq_swizzleViewDidAppear(track: @escaping (String, [String: Any]) -> Void) {
        LuniqSwizzleStore.viewDidAppear = track
        let orig = class_getInstanceMethod(UIViewController.self, #selector(viewDidAppear(_:)))!
        let new  = class_getInstanceMethod(UIViewController.self, #selector(luniq_viewDidAppear(_:)))!
        method_exchangeImplementations(orig, new)
    }

    @objc func luniq_viewDidAppear(_ animated: Bool) {
        self.luniq_viewDidAppear(animated)
        let name = String(describing: type(of: self))
        LuniqSwizzleStore.currentScreen = name  // remember for $tap enrichment
        LuniqSwizzleStore.viewDidAppear?("$screen", ["screen_name": name, "source": "auto"])
    }
}

extension UIApplication {
    static func luniq_swizzleSendAction(track: @escaping (String, [String: Any]) -> Void) {
        LuniqSwizzleStore.sendAction = track
        let sel = #selector(UIApplication.sendAction(_:to:from:for:))
        let new = #selector(UIApplication.luniq_sendAction(_:to:from:for:))
        let orig = class_getInstanceMethod(UIApplication.self, sel)!
        let nm   = class_getInstanceMethod(UIApplication.self, new)!
        method_exchangeImplementations(orig, nm)
    }

    @objc func luniq_sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
        let result = self.luniq_sendAction(action, to: target, from: sender, for: event)
        if let control = sender as? UIControl, control.isTouchInside {
            var props: [String: Any] = [
                "action": NSStringFromSelector(action),
                "control": String(describing: type(of: control)),
                "source": "auto"
            ]
            if let b = control as? UIButton, let title = b.currentTitle { props["title"] = title }
            if let id = control.accessibilityIdentifier { props["id"] = id }
            // Attach current screen so heatmaps + frustration can aggregate per screen
            if !LuniqSwizzleStore.currentScreen.isEmpty {
                props["screen_name"] = LuniqSwizzleStore.currentScreen
            }

            // Tap coords (screen-relative, in points) for heatmap aggregation
            if let touch = event?.allTouches?.first {
                let winLoc = touch.location(in: nil)
                let screen = UIScreen.main.bounds.size
                props["tap_x"]    = Int(winLoc.x)
                props["tap_y"]    = Int(winLoc.y)
                props["screen_w"] = Int(screen.width)
                props["screen_h"] = Int(screen.height)
            }

            LuniqSwizzleStore.sendAction?("$tap", props)
        }
        return result
    }
}

enum LuniqSwizzleStore {
    static var viewDidAppear: ((String, [String: Any]) -> Void)?
    static var sendAction: ((String, [String: Any]) -> Void)?
    static var currentScreen: String = ""
}
