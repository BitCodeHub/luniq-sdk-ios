# Changelog

All notable changes to `LuniqSDK` for iOS are documented in this file.
The project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.4] — 2026-04-28

### Fixed
- **Messenger AI replies invisible**: backend's response field is `reply`,
  but the SDK was reading `aiReply` first → AI text never displayed,
  the chat fell back to a static "Thanks — we've logged this" string.
  Parser now accepts `reply`, `aiReply`, and `ai_reply`. The backend
  was also updated to return all three field names (1.0.x SDKs already
  in the wild work without an upgrade).
- **Messenger composer ate the entire sheet**: UITextView with no max
  height grew to fill all vertical space, collapsing the chat scroll
  view to 0pt — that's why the conversation thread was invisible.
  Added `isScrollEnabled = false` + `>= 44 / <= 120` height bounds and
  set high vertical content-hugging priority.
- **Send button got pushed off-screen as text grew**: composer + send
  button live in a horizontal `UIStackView` (bottom-aligned) now;
  send button has required content-hugging + compression-resistance,
  so growing text never displaces it.
- **Keyboard covered the input + tabs**: manual keyboard avoidance via
  `UIResponder.keyboardWillChangeFrameNotification` (using
  `keyboardLayoutGuide` causes layout cycles inside a page-sheet on
  iPhone 16). Composer slides up exactly the keyboard's overlap height.
- **Duplicate `show_feedback` modals on rapid event bursts**:
  `DecisionAgent` now sets the post-call cooldown when sending the
  `/v1/sdk/decide` request (not when receiving), and an `inFlight`
  guard prevents concurrent decision calls. Without this, two bursts
  of 8 events in <1 s could each fire a decision call, both returning
  `show_feedback` before either set the cooldown.

### Added
- **Messenger conversation history**: opens with the user's prior
  thread populated from `GET /v1/sdk/messages/history`. "Welcome
  back. Here's your recent conversation:" header replaces the
  one-shot greeting after fetch.
- **Sent-status indicators**: AI replies that auto-filed Jira tickets
  now surface a `📌 Filed as ticket <KEY>` confirmation bubble.
  Network-level failures show a clear retry hint instead of the
  silent "logged this" placeholder.

## [1.0.3] — 2026-04-27

### Fixed
- **CocoaPods install was broken in 1.0.0–1.0.2**: the podspec still
  declared a `LuniqObjC` subspec pointing at `Sources/LuniqObjC/**/*.{h,m}`
  — files that no longer exist after the 1.0.1 Swift-bridge refactor.
  Pod install would fail to find sources. Podspec is now a single
  Swift-only spec; the Obj-C facade is part of the main module.
- Podspec `s.source` now points at the public GitHub URL with a tag
  reference, so `pod 'LuniqSDK'` works without needing a local checkout.

## [1.0.2] — 2026-04-27

### Added
- `HTTPTransport.extraProtocolClasses` — test hook so `URLProtocol` mocks
  flow through the SDK's URLSession even though `Luniq.shared` is a
  singleton. Production code never touches it; tests set it in setUp().

### Changed
- iOS test suite now runs 15/15 with no skips on `xcodebuild test`. The
  five EndToEnd / Transport tests that were skipped in 1.0.1 (waiting on
  URLSession injection) are live again.

## [1.0.1] — 2026-04-27

### Fixed
- **SwiftPM build was broken in 1.0.0**: `Package.swift` did not link
  `UIKit`, so `swift build` and any SPM consumer using a non-default
  toolchain failed with `no such module 'UIKit'`. UIKit + Foundation
  are now declared as `linkerSettings` on the `LuniqSDK` target.
- **Obj-C bridging in 1.0.0**: the separate `LuniqObjC` SPM target
  imported `<LuniqSDK/LuniqSDK-Swift.h>`, which SPM does not generate
  for cross-target Swift→Obj-C interop. The Obj-C facade has been
  reimplemented in Swift as `LuniqObjC` (`@objc` class methods) and
  shipped inside the `LuniqSDK` module — same call sites
  (`[LuniqObjC startWithApiKey:...]`) keep working.

### Removed
- `LuniqObjC` as a separate SPM library product. Pods users see no
  change; SwiftPM consumers no longer import a second module.

### Added
- Shared scheme at `.swiftpm/xcode/xcshareddata/xcschemes/LuniqSDK.xcscheme`
  with a working test action so `xcodebuild test` discovers the test
  target without opening Xcode first.
- `LICENSE` (Apache-2.0).

## [1.0.0] — 2026-04-26

### Added
- Initial public release: `Luniq.shared.start/identify/track/screen`,
  auto-capture, session replay, in-app messenger, design mode, dual
  Swift/Obj-C API.
