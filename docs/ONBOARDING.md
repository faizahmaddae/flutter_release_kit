# Onboarding a Flutter app

This guide configures one explicitly selected Flutter project for the shared
release pipeline. Nothing is discovered or enrolled automatically.

The examples use these neutral placeholders:

| Placeholder | Meaning |
|---|---|
| `example_app` | Name used by the local project registry |
| `/path/to/example_app` | Absolute path to a Flutter project |
| `<package-id>` | Actual Android application ID |
| `<bundle-id>` | Actual iOS bundle ID |
| `<team-id>` | 10-character Apple developer team ID |

Replace every placeholder with the corresponding value for the app being
onboarded.

## 1. Install the toolkit

```bash
git clone https://github.com/faizahmaddae/flutter_release_kit.git ~/.flutter-release-kit
~/.flutter-release-kit/bin/frk setup
```

The setup command is idempotent. It creates the private vault and registry,
creates a commented credential template, installs the `frk` command in
`~/.local/bin`, and checks Flutter and Fastlane. Existing commands, credentials,
and registered projects are preserved.

Follow any PATH or missing-tool instruction printed by setup, then confirm:

```bash
frk status
```

If the toolkit is stored elsewhere, run its own `bin/frk setup`; the generated
command points back to that clone. When Fastlane is invoked directly instead of
through `frk`, set `FLUTTER_RELEASE_KIT=/path/to/flutter_release_kit`.

## 2. Configure shared credentials

The default private directory layout is:

```text
~/.flutter-release/          mode 700
├── credentials.env          mode 600 — identifiers and credential paths
├── asc/AuthKey_XXXX.p8      mode 600 — App Store Connect API key
├── play/service-account.json mode 600 — Play service account
├── projects.json            mode 600 — explicitly managed project paths
└── signing/
    ├── <package-id>/         Android upload keystore and key.properties
    └── ios/<team-id>/        exported distribution signing material
```

`frk setup` creates `~/.flutter-release/credentials.env`. Uncomment the values
needed for the platforms used on this machine. Paths may be relative to
`~/.flutter-release/` or absolute:

```dotenv
ASC_KEY_ID=XXXXXXXXXX
ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
ASC_KEY_FILEPATH=asc/AuthKey_XXXXXXXXXX.p8
SUPPLY_JSON_KEY=play/service-account.json
```

The macOS app provides the safer guided alternative: open **Settings → Manage
Connections** and choose the JSON or `.p8` source. FRK validates it, preserves
the source, copies it into the private vault with mode `600`, and updates the
environment file without exposing secret contents to the UI or logs.

Credential sources:

- **App Store Connect API key:** App Store Connect → Users and Access →
  Integrations → App Store Connect API → Team Keys → **+**. The App Manager role
  is sufficient for this workflow. The `.p8` file can be downloaded only once
  and applies to the Apple team.
- **Play service account:** Google Cloud Console → IAM & Admin → Service
  Accounts → Keys → Add key (JSON). Enable the Google Play Android Developer API
  in the Google Cloud project. Access to each Play app is granted separately.

Confirm the shared setup:

```bash
frk status
```

## 3. Inspect and onboard the project

Start with a dry run:

```bash
frk onboard /path/to/example_app --dry-run
frk onboard /path/to/example_app
```

The command reads `applicationId` from Gradle and reads
`PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` from the Xcode project. It
does not derive one platform's identifier from the other because Android and
iOS identifiers can legitimately differ.

Onboarding writes:

- `fastlane/Fastfile`
- `fastlane/release_kit.yml`
- `ios/ExportOptions.plist` for iOS apps
- missing release-related `.gitignore` rules
- one absolute path in `~/.flutter-release/projects.json`

Existing files are not overwritten without `--force`. The registry is the
opt-in boundary: `frk list` never scans a parent directory, and `frk forget
NAME_OR_PATH` removes only the registry entry without editing the project.

Useful options:

| Option | Purpose |
|---|---|
| `--name <name>` | Set a stable registry name when the directory name is unsuitable |
| `--platforms android` | Configure an Android-only app |
| `--platforms ios` | Configure an iOS-only app |
| `--platforms android,ios` | Configure both platforms explicitly |
| `--android-package <id>` | Supply an application ID generated dynamically by Gradle |
| `--ios-bundle-id <id>` | Override Xcode bundle-ID detection |
| `--ios-team-id <id>` | Supply the 10-character Apple team ID |
| `--track alpha` | Select `alpha` instead of the default `internal` Play track |
| `--force` | Replace generated configuration after review |

### Projects in nested directories

The registry stores the full project path, so nested projects work without
special handling. Give the project a stable name if its immediate directory has
a generic name such as `v2`:

```bash
frk onboard /workspace/dictionary/v2 --name dictionary_app
```

### Conservative platform detection

The presence of an `ios/` directory does not prove that an app ships on iOS;
Flutter creates that directory by default. Automatic iOS selection therefore
requires both a non-placeholder bundle ID and a valid `DEVELOPMENT_TEAM`.

If the App Store record already exists but the team is not configured locally,
set the team in Xcode and onboard again with `--platforms android,ios`. A missed
platform produces a visible warning, while a false-positive platform would
produce misleading credential failures later.

## 4. Configure Android signing and Play access

Skip this section for iOS-only apps.

Import a complete existing `key.properties` file and its referenced keystore:

```bash
frk signing import example_app --properties /path/to/key.properties
frk signing link example_app
frk signing audit example_app
```

The import copies both files to
`~/.flutter-release/signing/<package-id>/`; it never deletes the source files.
The link command backs up an existing project pointer inside the private vault,
then creates an ignored `android/key.properties` symlink. Existing vault
contents are not replaced unless `--force` is supplied explicitly.

If `android/key.properties` is complete but its referenced store was moved or
lost, point to the recovered keystore and link atomically:

```bash
frk signing import example_app --keystore /backup/upload-key.jks --link
```

FRK reads the file with Java Properties semantics, resolves relative
`storeFile` paths the same way the app's Gradle script does, and validates the
store password, alias, and private-key password with the installed JDK. It then
copies the store into the private vault, preserves the source, backs up the
project properties, and links the project. Passwords are never printed or
placed in process arguments.

Grant the Play service account access to the app:

> Play Console → **Users and permissions** → service-account user →
> **App permissions** → **Add app** → select the app →
> **Release to testing tracks, excluding production** → **Apply**

Play permissions are granted per app. A service account that can release one
app does not automatically have access to another. Permission changes may take
several minutes to propagate.

## 5. Configure iOS distribution signing

Skip this section for Android-only apps.

Run the account-level setup once for the Apple team:

```bash
fastlane ios setup_signing
```

The lane creates or reuses an Apple Distribution certificate, creates an App
Store provisioning profile for the app, and imports the identity into the macOS
Keychain. Exported material is stored under
`~/.flutter-release/signing/ios/<team-id>/`, outside the app repository.

The profile name is deterministic (`<bundle-id> AppStore`) and the generated
`ios/ExportOptions.plist` pins exports to it. This matters on machines without
an Apple ID signed into Xcode: automatic export can otherwise select an older
profile whose certificate is no longer installed.

`frk doctor` also requires the app-specific profile in this central directory,
so a missing setup is reported before Xcode spends time creating an archive.

Back up the exported `.p12` securely. Apple does not reissue its private key,
and the number of active distribution certificates is limited.

## 6. Validate

```bash
frk doctor example_app
```

The doctor checks configuration, signing, store connectivity, and current
version state for every configured platform. It reports all detected problems
in one run and shows the next available build number when possible.

The optional verification command runs the app's static analysis and tests:

```bash
frk verify example_app
```

## 7. Build or release

```bash
frk build android example_app --build-name 1.2.0 --build-number 42
frk release android example_app --build-name 1.2.0 --build-number 42
frk release ios example_app --build-name 1.2.0 --build-number 42
frk release all example_app --build-name 1.2.0 --build-number 42
```

Inside the onboarded project directory, `example_app` can be omitted.
`frk release` uses macOS `caffeinate` automatically so a long upload is not
interrupted by system sleep.

`--skip-build` means “upload the artifact already on disk.” It cannot be
combined with version overrides because the artifact's embedded version could
otherwise differ from the requested version.

`frk release all` is not atomic: one store can accept its upload before the
other platform fails. Use separate platform commands when the stores use
different version streams or require independent control.

### Version policy

Version numbers are never auto-incremented. Android and iOS streams can diverge,
and `pubspec.yaml` may describe only one of them. Pass `--build-name` and
`--build-number` explicitly, or intentionally use the values from
`pubspec.yaml`.

Both platforms query the store before building and reject a build number that
is already in use.

## Troubleshooting

### Google Play

**`The caller does not have permission`**

The service account has not been granted access to this app, or the permission
change has not propagated. Repeat the app-level grant in section 4.

**`Package not found: <package-id>`**

The Play Publishing API can update an existing listing but cannot create one.
Create the app in Play Console first and verify that its package name matches
`android.package_name` in `release_kit.yml`. Play can return the same response
when the listing exists but the service account lacks access. A new listing may
also require its first bundle to be uploaded manually in Play Console.

**`versionCode N is already uploaded`**

Choose a higher `--build-number`. The preflight output shows the current store
state when the API is reachable.

**DWARF debugging information warning**

An unobfuscated-DWARF warning can refer to the separate `.symbols` output
created by `--split-debug-info`. That file is required to de-obfuscate crash
reports and is not bundled into the shipped artifact. Inspect the generated AAB
if a store or security check reports debug data in the actual binary.

### App Store Connect and TestFlight

**`<bundle-id> does not exist on App Store Connect`**

The configured `ios.bundle_id` does not match an App Store Connect record. Check
the configured value and query the store with `fastlane ios builds`.

**`No Apple Distribution signing identity`**

Run `fastlane ios setup_signing`.

**The version train is closed or must be higher than the approved version**

Apple closes a marketing-version train after approval. Increasing only the
build number does not reopen it; increase `--build-name`. The release pipeline
checks released versions before archiving and translates the store rejection
into this instruction.

**A TestFlight upload appears to stall**

Apple Transporter can stall or report a network failure after delivering an
IPA. The release lane uses the DAV transport, limits each attempt, terminates a
stalled transfer, retries, and checks App Store Connect before declaring
failure.

| Setting | Default | Override |
|---|---:|---|
| Minutes per upload attempt | 8 | `IOS_UPLOAD_TIMEOUT_MINUTES=25` or `ios.upload_timeout_minutes` |
| Total attempts | 3 | `IOS_UPLOAD_ATTEMPTS=5` or `ios.upload_attempts` |

Observed healthy uploads typically complete in 100–200 seconds, while an
accepted build can take several additional minutes to appear through the API.
The post-failure check therefore waits up to 10 minutes to avoid uploading a
build that has already arrived. Validation errors such as a closed version train
are final and are not retried.

Check the authoritative store state with:

```bash
fastlane ios builds
```

To opt out of the DAV transport for one run:

```bash
TESTFLIGHT_TRANSPORT=default fastlane ios release
```

**The TestFlight build number differs from the requested number**

Xcode can rewrite `CFBundleVersion` during export. The lane reads the version
from the finished IPA, verifies that value, and warns if it differs from the
request.

**`<app>` is not configured for iOS**

The app's `platforms` list in `release_kit.yml` does not include `ios`. Update
the configuration only if iOS is intentionally supported.
