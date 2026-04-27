import Foundation

/// Obj-C friendly facade over `Luniq.shared`. Exposes class methods so
/// Obj-C callers can write `[LuniqObjC startWithApiKey:... endpoint:... environment:...]`
/// instead of `[[Luniq shared] startWithApiKey:... endpoint:... environment:...]`.
///
/// All real work happens in `Luniq` — this is only ergonomic sugar.
@objc(LuniqObjC)
public final class LuniqObjC: NSObject {

    @objc(startWithApiKey:endpoint:environment:)
    public static func start(apiKey: String, endpoint: String, environment: String) {
        Luniq.shared.start(apiKey: apiKey, endpoint: endpoint, environment: environment)
    }

    @objc(trackEvent:properties:)
    public static func track(_ name: String, properties: [String: Any]?) {
        Luniq.shared.track(name, properties: properties ?? [:])
    }

    @objc(screen:properties:)
    public static func screen(_ name: String, properties: [String: Any]?) {
        Luniq.shared.screen(name, properties: properties ?? [:])
    }

    @objc(identifyVisitor:account:traits:)
    public static func identify(visitorId: String, accountId: String?, traits: [String: Any]?) {
        Luniq.shared.identify(visitorId: visitorId, accountId: accountId, traits: traits)
    }

    @objc public static func flush() { Luniq.shared.flush() }
    @objc public static func optOut(_ out: Bool) { Luniq.shared.optOut(out) }
    @objc public static func startRecording() { Luniq.shared.startRecording() }
    @objc public static func stopRecording() { Luniq.shared.stopRecording() }
    @objc public static func showFeedback(_ kind: String?) { Luniq.shared.showFeedback(kind ?? "idea") }
    @objc public static func refreshInApp() { Luniq.shared.refreshInApp() }
}
