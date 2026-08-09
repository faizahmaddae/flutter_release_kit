# Flutter Release Kit — AI Handoff

Updated: 2026-08-06

Read this file completely before editing. Then read `README.md` and
`docs/MACHINE_API.md`, run `git status --short`, and preserve every existing
working-tree change. The changes after commit `a9dfb09` are active work and
must not be reset or discarded.

## Product direction

Flutter Release Kit manages multiple Flutter projects through one shared CLI,
Fastlane implementation, private credential vault, and native SwiftUI macOS
app. Projects may be Android-only, iOS-only, or both.

The user deliberately removed the Store Listing Manager because app-name,
description, keywords, listing import, and publishing workflows made the tool
too complex. Do not reintroduce those features unless explicitly requested.

The only store-asset feature wanted now is **Screenshot Studio**:

- discover running Android emulators/devices and iOS Simulators;
- capture a fresh screen with `adb` or `xcrun simctl`;
- import PNG/JPEG/HEIC or paste an image;
- add a clean Android, iPhone, or no-device frame;
- choose transparent/light/dark/accent canvas and outer spacing;
- preview and export a new high-resolution PNG;
- never alter the source image or upload anything automatically.

## Architecture and safety

- `bin/frk`: standard-library-only Python CLI and versioned machine API.
- `fastlane/Fastfile`: single source of build, validation, and tester-release behavior.
- `desktop/ReleaseKitApp`: SwiftUI client; release logic remains in the CLI.
- Secrets/signing material live under `~/.flutter-release`, never in Git or API
  responses.
- Versions never auto-increment.
- Uploads remain Play testing tracks and TestFlight only—never production.
- Store listing and first-release preparation assistants are intentionally out
  of scope; the existing build, signing, validation, and tester-release flow remains.

## Current implementation

Run `frk --version` for the current CLI version. Machine protocol is v1. Relevant files:

- `desktop/ReleaseKitApp/Sources/ScreenshotStudioView.swift`
- `desktop/ReleaseKitApp/Sources/ScreenshotCaptureService.swift`
- `desktop/ReleaseKitApp/Sources/ScreenshotRenderer.swift`
- `desktop/ReleaseKitApp/Sources/ProjectDetailView.swift`
- `desktop/ReleaseKitApp/Sources/RootView.swift`
- `desktop/ReleaseKitApp/Tests/ReleaseKitAppTests.swift`

The old Store Listing Manager and First Release Assistant, along with their
Swift models/client state, CLI endpoints, Fastlane lanes/helpers, docs, and
tests, have been removed. Search for `StoreListing`, `store-listing`,
`Edit Listing`, and `first-release` before handoff; there should be no active
implementation references.

## Verification commands

```bash
# Repository root
ruby -c fastlane/Fastfile
python3 -m py_compile bin/frk
python3 -m unittest tests.test_frk
git diff --check

# desktop/ReleaseKitApp
swift test
./scripts/build_app.sh
codesign --verify --deep --strict "dist/Flutter Release Kit.app"
```

For visual QA, open the built app, select a managed project, open
**Screenshots**, capture/import a portrait image, switch between Android and
iPhone frames, change canvas/padding, and export a PNG to a temporary location.
Never upload it during QA.

## Next-model guidance

1. Do not broaden Screenshot Studio into a full listing/publishing system.
2. Keep source screenshots untouched and exports deterministic.
3. Prefer simple native UI and actionable errors when `adb`, a device, or an
   iOS Simulator is unavailable.
4. Commit or push only when the user asks.
