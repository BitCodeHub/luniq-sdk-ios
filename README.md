# LuniqSDK · Luna AI for iOS

AI-native product analytics for iOS — auto-capture, in-app guides / banners / surveys, session replay, and Design Mode pairing for live preview from the [Luna AI](https://uselunaai.com) dashboard. Dual Swift and Objective-C API.

## Install

### Swift Package Manager (recommended)

In Xcode → **File ▸ Add Packages…**:

```
https://github.com/BitCodeHub/luniq-sdk-ios.git
```

Pin to `1.0.0` (or "Up to Next Major Version").

### CocoaPods

```ruby
pod 'LuniqSDK', :git => 'https://github.com/BitCodeHub/luniq-sdk-ios.git', :tag => '1.0.0'
```

## Quick start

```swift
import LuniqSDK

// AppDelegate.application(_:didFinishLaunchingWithOptions:)
Luniq.shared.start(
    apiKey:      "lq_live_xxxxxxxxxxxx",
    endpoint:    "https://uselunaai.com",   // or your self-hosted URL
    environment: "PRD"
)

// After login
Luniq.shared.identify(visitorId: userId, accountId: accountId, traits: [
    "plan":    "pro",
    "country": "US",
])

// Custom events
Luniq.shared.track("checkout_started", properties: ["cart_size": 3])
Luniq.shared.screen("Dashboard")
Luniq.shared.reportError(error, context: ["feature": "checkout"])
```

## Objective-C

```objc
#import <LuniqObjC/LuniqObjC.h>

[LuniqObjC startWithApiKey:@"lq_live_xxx"
                  endpoint:@"https://uselunaai.com"
               environment:@"PRD"];
[LuniqObjC trackEvent:@"checkout_started" properties:@{@"cart_size": @3}];
```

## Auto-capture (on by default)

| Event | What triggers it |
|---|---|
| `$screen` | `UIViewController.viewDidAppear` swizzle |
| `$tap`    | `UIControl.sendAction` swizzle (with x/y, control type) |
| `$rage_click` | 3+ taps on the same control within 2 s |
| `$dead_click` | Tap with no app response within 1.5 s |
| `$error`  | `NSException` + Unix signals (SIGABRT, SIGSEGV…) |
| `$network_call` | `URLProtocol` intercepts every `URLSession` request |
| Session Replay | 30-sec H.264 MP4 segments via ReplayKit |

Disable: `LuniqConfig(autoCapture: false, …)`.

## Privacy

- PII redaction is on by default (`LuniqConfig.redactPII = true`).
- Honor opt-out: `Luniq.shared.optOut(true)` stops all collection.
- Events queue locally (JSON in Application Support); flush every 30 s or via `Luniq.shared.flush()`.
- Session Replay shows the iOS system permission prompt every session.

## Design Mode (live preview pairing)

Pair a real device to the dashboard via QR scan to preview unpublished guides / banners / surveys:

```swift
#if DEBUG
Luniq.shared.enableShakeToDesignMode()
#endif

// Or handle a deep link in AppDelegate / SceneDelegate:
func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
    return Luniq.shared.handleDesignModeURL(url)
}
```

## Documentation

Full docs at <https://uselunaai.com/docs/ios>.

## License

Apache-2.0.
