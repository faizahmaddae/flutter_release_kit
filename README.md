# Flutter Release Kit

A reusable, opt-in release automation toolkit for Flutter applications. One
shared Fastlane implementation supports Android-only, iOS-only, and
dual-platform apps, even when their project directories live in different
locations.

Flutter Release Kit builds Android App Bundles and iOS archives, uploads Android
releases to a **Google Play testing track**, and uploads iOS releases to
**TestFlight**. It cannot publish directly to the public: the `production` Play
track is rejected and TestFlight submission is disabled. Store promotion remains
an explicit action in the relevant console.

## Start here

### 1. Install once

```bash
git clone https://github.com/faizahmaddae/flutter_release_kit.git ~/.flutter-release-kit
~/.flutter-release-kit/bin/frk setup
```

`setup` creates the private local vault, installs the `frk` command, checks
Flutter and Fastlane, and prints only the next action still needed. It is safe
to run again and never overwrites an existing command or credential file.

If setup reports that `~/.local/bin` is missing from `PATH`, add the exact line
it prints to the shell profile and open a new terminal.

### 2. Add store credentials once

The macOS app opens a first-run Store Connections assistant. Select a Google
Play service-account JSON, an App Store Connect `.p8` key, or explicitly choose
local builds for now. The same connections remain editable in **Settings →
Manage Connections**.

For CLI-only use, edit the template at `~/.flutter-release/credentials.env` and
copy the required key files into the folders shown there. Follow the
[credential guide](docs/ONBOARDING.md#2-configure-shared-credentials) for the
Google Play and/or App Store values used by this machine.

### 3. Add an app

```bash
frk onboard /path/to/example_app --dry-run
frk onboard /path/to/example_app
frk doctor example_app
```

Only that exact project is enrolled. Nothing else on the machine is scanned or
changed.

### 4. Build or release

```bash
frk build android example_app --build-name 1.2.0 --build-number 42
frk release android example_app --build-name 1.2.0 --build-number 42
frk release ios example_app --build-name 1.2.0 --build-number 42
```

The project argument is optional when the command is run inside an onboarded
project directory. On macOS, `frk release` keeps the machine awake while
Fastlane is running.

Press Ctrl+C to cancel a running command. FRK stops its Fastlane process and
helpers before returning; cancellation cannot undo a store-accepted upload.

That is the normal workflow. For signing, platform detection, and uncommon
errors, use the [onboarding guide](docs/ONBOARDING.md).

## Requirements

- A Flutter app with a real Android application ID and/or iOS bundle ID.
- Python 3.9 or newer (macOS ships 3.9 at `/usr/bin/python3`).
- [fastlane](https://fastlane.tools/) 2.220.0 or newer for store releases.
- Store listings and API credentials for the platforms being released.
- macOS with Xcode for iOS builds and TestFlight uploads.

The `frk` command uses only the Python standard library. The shared Fastfile
declares `fastlane_version "2.220.0"`, and an older Fastlane stops while loading
it. `frk setup` checks that Flutter and Fastlane are present, not which version
is installed; it reports any missing tool and gives the relevant installation
command when available.

## How it works

Each onboarded app receives small, non-secret files:

| File | Purpose |
|---|---|
| `fastlane/Fastfile` | Imports the shared Fastfile; contains no release logic |
| `fastlane/release_kit.yml` | Declares identifiers, platforms, tracks, and app-specific options |
| `ios/ExportOptions.plist` | Pins App Store export to the app's deterministic provisioning profile |
| `.gitignore` additions | Excludes generated artifacts and local credentials |

The app Fastfile and the `.gitignore` rules come from the two files in
`templates/`. `fastlane/release_kit.yml` and `ios/ExportOptions.plist` have no
template: `frk` generates them from the identifiers detected for the app.

For example, a generated dual-platform configuration has this shape (all
values are illustrative):

```yaml
name: "example_app"
platforms: [android, ios]
obfuscate: true

android:
  package_name: com.yourcompany.exampleapp
  track: internal

ios:
  bundle_id: com.yourcompany.exampleapp
  team_id: ABCDE12345
```

The central registry at `~/.flutter-release/projects.json` records the exact
absolute paths that were onboarded. Copying the generated configuration to
another checkout does not enroll it on that machine.

Registry updates are serialized across FRK processes, so registering or
forgetting one app cannot discard another concurrent update. Re-registering
the same app preserves its original registration date and existing metadata.
Track and build-flag edits also preserve unrelated project settings and refuse
ambiguous YAML before writing. No configuration migration is required.

After a project is renamed in its release configuration, both its displayed
name and original registered name remain usable. If names overlap across apps,
FRK asks for an explicit path rather than choosing one. These lookups do not
rewrite the registry or project files.

The repository layout is intentionally small:

```text
flutter_release_kit/
├── bin/frk                  CLI for onboarding, checks, builds, and releases
├── desktop/ReleaseKitApp/   native SwiftUI control surface for macOS
├── integrations/mcp/        optional local AI tools using the existing API
├── fastlane/Fastfile        shared release lanes
├── templates/               app Fastfile and .gitignore templates
├── tests/                   dependency-free CLI tests
└── docs/ONBOARDING.md       setup and troubleshooting guide
```

## Credentials and signing

Credentials are separated according to their actual store scope:

| Credential | Scope | Default location |
|---|---|---|
| App Store Connect API key | Apple developer team | `~/.flutter-release/asc/` |
| Play service-account key | Account key, access granted per app | `~/.flutter-release/play/` |
| Android upload key | Android application | `~/.flutter-release/signing/<package-id>/` |
| Apple distribution identity | Apple developer team | macOS Keychain |

The vault directory is created with mode `700`, and credential files use mode
`600`. It is not a backup by itself; back it up as an encrypted archive and keep
the recovery secret in a password manager.

To centralize an existing Android upload key:

```bash
frk signing import example_app --properties /path/to/key.properties
frk signing link example_app
frk signing audit example_app
```

Importing copies the keystore and properties file; it does not delete the
original. Existing vault contents require `--force` before replacement.

If the project's `key.properties` is complete but its referenced keystore is
missing, select the recovered store directly and link in one safe operation:

```bash
frk signing import example_app --keystore /backup/upload-key.jks --link
```

The macOS Setup Assistant starts with the project's own `key.properties`, shows
missing fields precisely, resolves `storeFile` the same way Gradle does, and
validates the store password, alias, and private-key password. Vault management
is offered afterward as protection, not confused with signing validity. The app
contains no separate signing implementation.

## Command overview

```text
frk setup     Prepare a machine safely; can be run more than once
frk onboard   Add one explicitly selected Flutter app
frk doctor    Validate release configuration and store access
frk verify    Run Flutter analysis and tests
frk build     Build Android and/or iOS release artifacts
frk release   Upload to Play testing and/or TestFlight
frk list      Show explicitly managed projects
frk forget    Remove only a registry entry
frk status    Inspect toolkit and shared credential state
frk signing   Import, link, audit Android keys; set up iOS distribution signing
frk build-args View or set extra Flutter build flags per platform
frk track     View or change the Google Play testing track
```

Run `frk COMMAND --help` for command-specific options. Advanced users can also
run the imported Fastlane lanes directly.

## Native macOS app

The optional SwiftUI app gives the same shared system a native project
dashboard, guided onboarding, live logs, safe cancellation, build controls,
Android testing-track uploads, and TestFlight uploads. Its Screenshot Studio
captures a running Android emulator/device or iOS Simulator, accepts existing
images and clipboard content, adds a clean Android or iPhone frame, and exports
a new high-resolution PNG. Source images remain untouched and no screenshot is
uploaded automatically. It calls the installed `frk` executable through a
versioned JSON protocol, so release logic remains in one place and CLI
improvements do not need to be duplicated in the app.

```bash
cd desktop/ReleaseKitApp
swift test
./scripts/build_app.sh
open "dist/Flutter Release Kit.app"
```

See the [desktop app guide](desktop/ReleaseKitApp/README.md) and the
[machine API contract](docs/MACHINE_API.md).

## Claude, ChatGPT, and Codex

The optional local MCP server lets compatible AI clients inspect managed apps,
check store versions, build, upload to testing destinations, and follow or cancel
jobs. It uses the existing machine API and keeps project configuration and
signing management in FRK. The adapter's SDK dependencies are isolated from the
standard-library CLI.

See [MCP setup and usage](docs/MCP.md) for Claude Desktop, Claude Code, and Codex
configuration, example requests, and the separate requirements for browser chats.

## Design constraints

- Version numbers are never auto-incremented. Android and iOS release streams
  can diverge, so the requested number is checked against the store before the
  build instead of being guessed.
- `frk release all` is convenient but not atomic. One platform can succeed
  before the other fails; use separate commands when independent control is
  important.
- Platform detection is conservative. A real iOS bundle ID and a configured
  10-character Apple team ID are required before iOS is selected automatically.
- Transporter recovery may terminate another concurrent `altool` process on the
  same machine. Do not run multiple iOS uploads concurrently.

## Maintaining shared behavior

Shared release logic belongs in `fastlane/Fastfile`. App-specific values belong
in that app's `fastlane/release_kit.yml`. New app-level behavior should be added
as a configuration option with a backward-compatible default.

Do not add release lanes to generated app Fastfiles; doing so recreates the
duplication this toolkit is designed to remove.

Contributors should read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a
pull request.

## License

Released under the MIT License. See [LICENSE](LICENSE).
