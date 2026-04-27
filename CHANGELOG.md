# Changelog

All notable changes to `LuniqSDK` for iOS are documented in this file.
The project adheres to [Semantic Versioning](https://semver.org/).

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
