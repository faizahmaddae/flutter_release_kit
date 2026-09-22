# Flutter Release Kit for macOS

A native SwiftUI control surface for the `frk` command-line tool. The desktop
app intentionally contains no Fastlane or signing logic: the CLI remains the
single source of truth, while the app speaks the stable, versioned FRK protocol.

## Build and run

Requirements: macOS 14 or newer to run the app, and Xcode 16 or newer to build
it. `Package.swift` declares `swift-tools-version: 6.0`, which earlier toolchains
cannot read, so `swift test` fails immediately on Xcode 15.

```bash
cd desktop/ReleaseKitApp
swift test
./scripts/build_app.sh
open "dist/Flutter Release Kit.app"
```

The build script generates a complete Retina `.icns` from
`Resources/AppIcon/app-icon-1024.png`, embeds it in the application bundle, and
sets `CFBundleIconFile`. Keep that reviewed 1024px PNG as the single icon source.

The app looks for `frk` in `~/.local/bin/frk`, then
`~/.flutter-release-kit/bin/frk`. A different executable can be selected in
Settings. Install the current CLI first with:

```bash
frk setup
```

## Everyday workflow

- Search managed projects by name, folder, or application ID; combine the search
  with Android, iOS, or Needs setup filters. Filtering does not change a project.
- Setup indicators reflect folder availability and signing for every configured
  platform. Store access is checked separately.
- Version inputs and build/upload actions come first. Expand **Signing &
  destination** for identifiers and the Play track; track edits still save
  immediately. Artifacts, extra build flags, and Screenshot Studio follow below.
- **Check Setup** runs Doctor; **Analyze & Test** runs Verify. Upload and Android
  validation retain their confirmation dialogs.
- Activity opens when a job starts. Toggle it with **⇧⌘L**, or close it without
  stopping the job. It sits beside the project in wide windows and below it in
  narrow windows, staying open through resizing and immediate launch failures.
  Turn off **Follow output** to read earlier log lines. The
  originating project remains visible even when another project is selected.
- The CLI path in Settings is a draft until **Save & Reconnect**. **Cancel**
  and closing the Settings window discard that draft, including when macOS
  reuses the same Settings window. Store credentials have their own explicit
  save flow.

## Safety model

- Projects appear only after explicit onboarding.
- Switching projects discards pending build-flag and signing-status responses
  from the previous selection. A delayed read cannot undo newly saved flags.
- Passwords, API keys, upload keys, and provisioning-profile contents are never
  returned by the machine API or stored by the app.
- Builds and releases stream through the external `frk` process and can be
  cancelled from the Activity panel.
- The current CLI stops the process group on cancellation, including a store
  check's Fastlane helpers, and bounds cleanup when a tool ignores termination.
- Android upload is restricted to testing tracks. iOS upload is restricted to
  TestFlight. There is no production-publish action.
- Store release uploads require an explicit confirmation in the app. Android
  validation also requires confirmation because it sends the AAB to Google
  Play's validation API, although it creates no track release.
- Each **Fix Setup** button opens the Setup Assistant for that platform. Local
  checks refresh in place; **Run Full Check** checks both platforms and store
  access in Activity. Missing iOS API credentials can be configured directly
  through the existing Store credentials screen.
- The Setup Assistant checks Android in build order: `key.properties`, the
  referenced keystore, all signing credentials, Gradle wiring, and Git safety.
  Vault linking is recommended management, not a false prerequisite for a
  valid local release build, and stays under an optional disclosure when the
  local key is valid. An imported source is preserved and validated. Cancelling
  a file picker preserves the current selection.
- iOS is treated as a signing chain rather than a single file: Xcode bundle/team,
  Distribution certificate plus private key, decoded app profile, certificate
  compatibility, expiry, and ExportOptions are checked separately.
- Automatic iOS repair has a separate confirmation because it can create or
  refresh Apple Developer certificates and provisioning profiles. It never
  uploads a build.
- Screenshot Studio is local-only. It can capture a selected Android device or
  iOS Simulator, import an existing image, add an Android/iPhone frame, and
  export a new PNG. The original image is never overwritten and nothing is
  uploaded to a store.

The locally built app is ad-hoc signed. Before public distribution, use a
Developer ID certificate, hardened runtime, notarization, and a release-specific
bundle identifier owned by the distributor.

## Architecture

```text
SwiftUI app -> frk api (JSON / JSON Lines) -> existing frk commands -> Fastlane
```

The desktop client currently supports protocol version 1. New CLI behavior can
be added without changing the UI; breaking protocol changes require a new
protocol version with an overlap period.
