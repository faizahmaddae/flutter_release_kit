import Foundation

enum PlatformKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case android
    case ios

    var id: String { rawValue }

    var title: String {
        switch self {
        case .android: "Android"
        case .ios: "iOS"
        }
    }

    var systemImage: String {
        switch self {
        case .android: "apps.iphone"
        case .ios: "apple.logo"
        }
    }

    /// The store that counts this platform's uploads.
    var storeName: String {
        switch self {
        case .android: "Google Play"
        case .ios: "App Store Connect"
        }
    }

    /// What the store calls the number passed as `--build-number`. The two stores use
    /// different words for it, and using the wrong one is how a user ends up looking
    /// for "versionCode" in App Store Connect.
    var buildNumberLabel: String {
        switch self {
        case .android: "versionCode"
        case .ios: "build"
        }
    }
}

struct CapabilitiesResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let minimumDesktopProtocol: Int
    let maximumDesktopProtocol: Int
    let capabilities: Capabilities

    struct Capabilities: Codable, Equatable {
        let projectDiscovery: Bool
        let streamingEvents: Bool
        let credentialManagement: Bool?
        let productionRelease: Bool
        let platforms: [String]
        let actions: [String]
    }
}

struct CredentialsResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let vaultPath: String?
    let configuredAny: Bool?
    let googlePlay: GooglePlayCredentialStatus?
    let appStoreConnect: AppStoreCredentialStatus?
    let error: APIErrorPayload?

    var hasConfiguredStore: Bool { configuredAny == true }
}

struct GooglePlayCredentialStatus: Codable, Equatable {
    let configured: Bool
    let validationStatus: String
    let detail: String
    let keyPath: String?
    let clientEmail: String?
    let projectId: String?
}

struct AppStoreCredentialStatus: Codable, Equatable {
    let configured: Bool
    let validationStatus: String
    let detail: String
    let keyPath: String?
    let keyId: String?
    let issuerId: String?
}

enum CredentialOnboardingPolicy {
    static func shouldPresent(hasConfiguredStore: Bool, setupDecisionMade: Bool) -> Bool {
        !hasConfiguredStore && !setupDecisionMade
    }
}

struct ProjectsResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let projects: [ProjectSummary]
}

/// What `api set-track` returns: the one project it just wrote, read back from disk
/// rather than assumed, so the model can replace its matching entry directly instead
/// of reloading the whole fleet for a one-file change.
struct ProjectDocument: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let project: ProjectSummary
}

struct APIErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct ProjectSummary: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let path: String
    let exists: Bool
    let onboarded: Bool
    let state: String
    let platforms: [PlatformKind]
    let version: String?
    let buildName: String?
    let buildNumber: Int?
    let android: AndroidSummary?
    let ios: IOSSummary?
    let artifacts: ArtifactSummary
    let addedAt: String?

    var isReady: Bool { state == "ready" }
    var pathURL: URL { URL(fileURLWithPath: path) }

    func supports(_ platform: PlatformKind) -> Bool {
        platforms.contains(platform)
    }
}

extension ProjectSummary {
    /// Local setup only; store permissions are checked separately by the CLI.
    var setupLabel: String {
        if !exists { return "Folder missing" }
        if !onboarded || !isReady || platforms.isEmpty { return "Setup required" }
        if platforms.contains(where: { !readiness(for: $0).ready }) { return "Signing required" }
        return "Signing ready"
    }

    var needsSetup: Bool {
        !exists || !onboarded || !isReady || platforms.isEmpty
            || platforms.contains(where: { !readiness(for: $0).ready })
    }

    /// Badge state for one platform card. `signingReady` is optional on iOS because
    /// older CLIs omit it, so the profile flag is the documented fallback.
    func readiness(for platform: PlatformKind) -> (ready: Bool, label: String) {
        switch platform {
        case .android:
            let ready = android?.signingReady == true
            return (ready, ready ? "Signing ready" : "Signing required")
        case .ios:
            let ready = ios?.signingReady ?? (ios?.profileReady == true)
            let missing = ios?.profileReady == false ? "Profile required" : "Signing required"
            return (ready, ready ? "Signing ready" : missing)
        }
    }
}

struct AndroidSummary: Codable, Equatable, Hashable {
    let packageId: String?
    let signingReady: Bool
    let track: String
}

struct IOSSummary: Codable, Equatable, Hashable {
    let bundleId: String?
    let teamId: String?
    let profileReady: Bool
    let profilePath: String?
    let distributionIdentityReady: Bool?
    let signingReady: Bool?
}

struct SetupStatusResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let projectId: String?
    let android: AndroidSetupStatus?
    let ios: IOSSetupStatus?
    let error: APIErrorPayload?
}

struct AndroidSetupStatus: Codable, Equatable {
    let configured: Bool
    let packageId: String
    let projectPropertiesPath: String
    let projectPropertiesExists: Bool
    let propertiesComplete: Bool
    let missingPropertiesFields: [String]?
    let referencedKeystorePath: String?
    let keystoreExists: Bool
    let keystoreValidationStatus: String?
    let keystoreValidationDetail: String?
    let certificateSHA256: String?
    let gradleConfigured: Bool?
    let gradleConfigurationPath: String?
    let gradleConfigurationDetail: String?
    let vaultPath: String
    let vaultReady: Bool
    let projectLinked: Bool
    let gitTracked: Bool
    let propertiesGitIgnored: Bool?
    let keystoreGitTracked: Bool?
    let keystoreGitIgnored: Bool?
    let gitSafe: Bool?
    let signingReady: Bool
}

extension AndroidSetupStatus {
    var propertiesDetail: String {
        if !projectPropertiesExists {
            return "Missing at \(projectPropertiesPath)"
        }
        if !propertiesComplete {
            let fields = missingPropertiesFields?.joined(separator: ", ") ?? "required signing fields"
            return "Missing values: \(fields)"
        }
        return "Found and complete · \(projectPropertiesPath)"
    }

    var keystoreDetail: String {
        if !propertiesComplete {
            return "Waiting for a complete key.properties"
        }
        if !keystoreExists {
            return "File not found · \(referencedKeystorePath ?? "storeFile is not set")"
        }
        var detail = keystoreValidationDetail ?? "Keystore file exists"
        if let fingerprint = certificateSHA256 {
            detail += " · SHA-256 \(fingerprint)"
        }
        return detail
    }

    /// Reads the CLI's keystore validation vocabulary. Anything outside it is treated
    /// as a failure, so a renamed status degrades to `.error` rather than to `.ready`.
    var keystoreState: SetupCheckState {
        guard propertiesComplete, keystoreExists else { return .error }
        switch keystoreValidationStatus {
        case "valid": return .ready
        case "partial": return .warning
        default: return .error
        }
    }

    var gitDetail: String {
        var tracked: [String] = []
        if gitTracked { tracked.append("key.properties") }
        if keystoreGitTracked == true { tracked.append("keystore") }
        if !tracked.isEmpty {
            return "Tracked secret: \(tracked.joined(separator: " and "))"
        }
        var unignored: [String] = []
        if propertiesGitIgnored == false { unignored.append("key.properties") }
        if keystoreGitIgnored == false { unignored.append("keystore") }
        if !unignored.isEmpty {
            return "Missing .gitignore protection: \(unignored.joined(separator: " and "))"
        }
        return "Signing secrets are ignored and not tracked by Git"
    }

    var vaultDetail: String {
        if vaultReady && projectLinked {
            return "Protected central copy is linked · \(vaultPath)"
        }
        if vaultReady {
            return "Protected copy exists; link this project to use it"
        }
        return "Optional but recommended: protect one managed copy outside the repository"
    }
}

struct IOSSetupStatus: Codable, Equatable {
    let configured: Bool
    let bundleId: String
    let teamId: String
    let projectIdentityReady: Bool?
    let projectIdentityDetail: String?
    let workspacePath: String
    let workspaceExists: Bool
    let distributionIdentityReady: Bool
    let distributionIdentityDetail: String?
    let ascCredentialsReady: Bool
    let profilePath: String
    let profileReady: Bool
    let profileValidationStatus: String?
    let profileValidationDetail: String?
    let profileExpiresAt: String?
    let profileCertificateMatchesIdentity: Bool?
    let exportOptionsReady: Bool?
    let exportOptionsPath: String?
    let exportOptionsDetail: String?
    let signingReady: Bool
}

extension IOSSetupStatus {
    var profileDetail: String {
        if profileReady && profileCertificateMatchesIdentity == false {
            return "The profile is valid but does not include a distribution identity available on this Mac"
        }
        return profileValidationDetail
            ?? (profileReady ? profilePath : "The app-specific App Store profile is missing")
    }

    var profileState: SetupCheckState {
        profileReady && profileCertificateMatchesIdentity != false ? .ready : .error
    }
}

// MARK: - Store version report

/// What happened when one platform's store was asked, from `frk api store-versions`.
///
/// An unrecognised spelling decodes as `.unavailable` rather than failing the whole
/// document: the CLI already fails closed the same way, and a status this app has
/// never heard of is not evidence about what a store holds.
enum StoreQueryStatus: String, Codable, Equatable {
    /// The store answered. The numbers alongside are what it holds.
    case ok
    /// The project does not ask for this platform, or its section is unusable.
    case unconfigured
    /// Configured, but no usable store credential was found. Nothing was asked.
    case noCredentials = "no_credentials"
    /// The store was asked and did not produce a usable answer.
    case unavailable

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StoreQueryStatus(rawValue: raw) ?? .unavailable
    }

    /// True when nothing was learned about the store. Distinct from "the store answered
    /// and holds nothing", which is `ok` with a null number and a completely different
    /// thing to tell a user.
    var isFailure: Bool {
        self == .noCredentials || self == .unavailable
    }
}

/// One `frk api store-versions` document. `android` and `ios` are optional only
/// because a handled failure replaces them with `error`; a report always carries both.
struct StoreVersionsResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let project: String?
    let checkedAt: String?
    let android: AndroidStoreVersions?
    let ios: IOSStoreVersions?
    let error: APIErrorPayload?
}

struct AndroidStoreVersions: Codable, Equatable {
    let status: StoreQueryStatus
    let detail: String
    let track: String?
    /// The highest version code Play knows anywhere in this app. `null` means unknown,
    /// never zero — and under `.ok` it means the store genuinely holds nothing yet.
    let latestVersionCode: Int?
    let latestVersionName: String?
    let tracks: [AndroidTrackVersion]
}

struct AndroidTrackVersion: Codable, Equatable, Identifiable {
    let track: String
    let versionCode: Int
    let versionName: String?

    var id: String { "\(track)-\(versionCode)" }
}

struct IOSStoreVersions: Codable, Equatable {
    let status: StoreQueryStatus
    let detail: String
    let latestAppStoreVersion: String?
    let builds: [IOSStoreBuild]
}

struct IOSStoreBuild: Codable, Equatable, Identifiable {
    let version: String?
    /// `null` when CFBundleVersion is not a plain integer — Apple accepts "1.2.3".
    let build: Int?
    let state: String?

    var id: String { "\(version ?? "?")-\(build.map(String.init) ?? "?")-\(state ?? "?")" }
}

extension IOSStoreVersions {
    /// The entry carrying the highest build number, or nil when the list has none.
    ///
    /// Not simply the newest upload: Apple scopes build numbers to the version string,
    /// so the newest upload is not necessarily the highest number on file, and a
    /// candidate has to clear everything the list shows. Entries whose build is null
    /// carry no number to clear.
    var highestNumberedBuild: IOSStoreBuild? {
        builds.filter { $0.build != nil }.max { ($0.build ?? 0) < ($1.build ?? 0) }
    }
}

/// `frk api build-args` / `frk api set-build-args`. Local and instant — no store, no
/// network — so unlike `StoreVersionsResponse` this has no cancellation story.
struct BuildArgsResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    /// Applies to every platform the project ships. Edited only by hand in
    /// `fastlane/release_kit.yml`; `set-build-args` never writes this list.
    let shared: [String]
    let android: PlatformBuildArgs
    let ios: PlatformBuildArgs
}

struct PlatformBuildArgs: Codable, Equatable {
    let configured: Bool
    /// This platform's own flags, editable via `set-build-args`.
    let own: [String]
    /// `shared + own`, in the order actually passed to `flutter build`.
    let effective: [String]
}

/// What one platform's store line shows after a check.
///
/// Built here rather than inside the view so all four statuses can be asserted without
/// a view test. The distinction this type exists to keep: `.empty` is a store that
/// answered and holds nothing, while `.failed` is a store that never answered. Those
/// must never render the same way — a user with a shipped app being told the store is
/// empty is the bug this whole report was added to prevent.
struct StoreVersionRow: Equatable {
    enum Kind: Equatable {
        /// The store answered and holds a number.
        case known
        /// The store answered and holds nothing yet. A real, useful fact.
        case empty
        /// This project does not ask for the platform.
        case notConfigured
        /// No credential, or the store did not answer. Nothing was learned.
        case failed
    }

    let platform: PlatformKind
    let kind: Kind
    let headline: String
    /// A second fact worth showing beside the headline, such as the live App Store
    /// version. Never a substitute for the headline.
    let supplement: String?
    /// The CLI's own sentence about this platform. Always present, always safe to show.
    let detail: String
    /// The highest number the store already holds. Non-nil only for `.known`.
    let latest: Int?

    /// The candidate this app offers. Computed here from a fact the store reported,
    /// because the machine API deliberately reports no next/suggested version: the
    /// number that ships is the one a human typed or clicked. This value only ever
    /// reaches a field through an explicit tap on the suggestion button.
    var suggestion: Int? {
        guard kind == .known, let latest else { return nil }
        return latest + 1
    }

    /// True when the number currently in the field is one the store already holds, so
    /// the upload would be rejected as a duplicate. False whenever nothing is known —
    /// a failed check never accuses a number of being taken.
    func conflicts(with entered: String) -> Bool {
        guard let latest, let value = Int(entered) else { return false }
        return value <= latest
    }
}

extension StoreVersionRow {
    init(android: AndroidStoreVersions) {
        let track = android.track ?? "testing"
        switch android.status {
        case .ok:
            if let code = android.latestVersionCode {
                let name = android.latestVersionName.map { " · \($0)" } ?? ""
                self.init(
                    platform: .android,
                    kind: .known,
                    headline: "Play \(track): \(code)\(name)",
                    supplement: nil,
                    detail: android.detail,
                    latest: code
                )
            } else {
                self.init(
                    platform: .android,
                    kind: .empty,
                    headline: "Google Play holds no version code yet",
                    supplement: nil,
                    detail: android.detail,
                    latest: nil
                )
            }
        case .unconfigured:
            self.init(
                platform: .android,
                kind: .notConfigured,
                headline: "This project is not configured for Android",
                supplement: nil,
                detail: android.detail,
                latest: nil
            )
        case .noCredentials:
            self.init(
                platform: .android,
                kind: .failed,
                headline: "Not checked — no Google Play credential",
                supplement: nil,
                detail: android.detail,
                latest: nil
            )
        case .unavailable:
            self.init(
                platform: .android,
                kind: .failed,
                headline: "Could not check Google Play",
                supplement: nil,
                detail: android.detail,
                latest: nil
            )
        }
    }

    init(ios: IOSStoreVersions) {
        let appStore = ios.latestAppStoreVersion.map { "App Store: \($0)" } ?? "App Store: never released"
        switch ios.status {
        case .ok:
            if let newest = ios.highestNumberedBuild, let build = newest.build {
                let version = newest.version.map { " (\($0))" } ?? ""
                self.init(
                    platform: .ios,
                    kind: .known,
                    headline: "TestFlight: \(build)\(version)",
                    supplement: appStore,
                    detail: ios.detail,
                    latest: build
                )
            } else {
                self.init(
                    platform: .ios,
                    kind: .empty,
                    headline: "TestFlight holds no numbered build yet",
                    supplement: appStore,
                    detail: ios.detail,
                    latest: nil
                )
            }
        case .unconfigured:
            self.init(
                platform: .ios,
                kind: .notConfigured,
                headline: "This project is not configured for iOS",
                supplement: nil,
                detail: ios.detail,
                latest: nil
            )
        case .noCredentials:
            self.init(
                platform: .ios,
                kind: .failed,
                headline: "Not checked — no App Store Connect credential",
                supplement: nil,
                detail: ios.detail,
                latest: nil
            )
        case .unavailable:
            // `ios` is two reads — the TestFlight build list and the App Store release
            // list — and Connect can serve one and refuse the other. The status is then
            // `unavailable` for the whole platform, fail-closed, while the half that
            // answered is still populated. Showing that half is honest; treating it as
            // the platform's latest is not, because the half that failed could hold a
            // higher number. So `latest` stays nil: no suggestion, no conflict warning,
            // and the row is still `.failed` rather than a store that answered.
            let partial = ios.partialAnswer
            self.init(
                platform: .ios,
                kind: .failed,
                headline: partial == nil
                    ? "Could not check App Store Connect"
                    : "Only part of App Store Connect answered",
                supplement: partial.map { "Partial answer — \($0)" },
                detail: ios.detail,
                latest: nil
            )
        }
    }
}

extension IOSStoreVersions {
    /// What a fail-closed `unavailable` still managed to read, or nil when it read
    /// nothing. Never a `latest`: half an answer cannot rule out a higher number.
    var partialAnswer: String? {
        var parts: [String] = []
        if let newest = highestNumberedBuild, let build = newest.build {
            parts.append("TestFlight held build \(build)\(newest.version.map { " (\($0))" } ?? "")")
        }
        if let released = latestAppStoreVersion {
            parts.append("App Store held \(released)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One platform's half of a release. `frk release all` is not atomic and neither is
/// the app's two-invocation equivalent, so each half is reported on its own rather
/// than collapsed into one success or failure.
struct ReleaseLeg: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
        /// Never started, because an earlier platform did not succeed.
        case skipped
    }

    let platform: PlatformKind
    let buildName: String
    let buildNumber: String
    var state: State

    var id: String { platform.rawValue }

    var isFinished: Bool {
        switch state {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled, .skipped: true
        }
    }

    var summary: String {
        switch state {
        case .queued: "Waiting"
        case .running: "Uploading…"
        case .succeeded: platform == .android ? "Uploaded to Play testing" : "Uploaded to TestFlight"
        case .failed: "Failed — nothing was uploaded for this platform"
        case .cancelled: "Cancelled"
        case .skipped: "Not started, because an earlier platform did not finish"
        }
    }
}

struct ArtifactSummary: Codable, Equatable, Hashable {
    let androidAab: ArtifactRecord?
    let iosIpa: ArtifactRecord?
}

struct ArtifactRecord: Codable, Equatable, Hashable {
    let path: String
    let sizeBytes: Int64
    let modifiedAt: String

    var url: URL { URL(fileURLWithPath: path) }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct APIEvent: Codable, Equatable, Identifiable {
    let protocolVersion: Int
    let cliVersion: String
    let type: String
    let timestamp: String
    let action: String?
    let project: String?
    let platform: String?
    let sequence: Int?
    let stream: String?
    let message: String?
    let code: String?
    let success: Bool?
    let exitCode: Int?
    let durationSeconds: Double?

    var id: String {
        "\(timestamp)-\(type)-\(sequence ?? -1)-\(message ?? "")"
    }
}

enum JobAction: String, CaseIterable {
    case onboard
    case doctor
    case verify
    case build
    case validate
    case release
    case signingAudit = "signing-audit"
    case signingImport = "signing-import"
    case signingLink = "signing-link"
    case iosSetupSigning = "ios-setup-signing"
    case status
    case forget

    var title: String {
        switch self {
        case .onboard: "Add project"
        case .doctor: "Doctor"
        case .verify: "Verify"
        case .build: "Build"
        case .validate: "Validate"
        case .release: "Release to testers"
        case .signingAudit: "Audit signing"
        case .signingImport: "Import upload key"
        case .signingLink: "Link signing"
        case .iosSetupSigning: "Repair iOS signing"
        case .status: "Machine status"
        case .forget: "Remove project"
        }
    }
}

struct FRKRunRequest: Equatable {
    var action: JobAction
    var project: String?
    var platform: PlatformKind?
    var buildName: String?
    var buildNumber: String?
    var skipTests = false
    var skipBuild = false
    var onboardName: String?
    var onboardPlatforms: String?
    var androidPackage: String?
    var iosBundleID: String?
    var iosTeamID: String?
    var track: String?
    var propertiesPath: String?
    var keystorePath: String?
    var force = false
    var link = false
    var dryRun = false

    var arguments: [String] {
        var result = ["api", "run", action.rawValue]
        if let project, !project.isEmpty { result.append(project) }
        if let platform { result += ["--platform", platform.rawValue] }
        if let buildName, !buildName.isEmpty { result += ["--build-name", buildName] }
        if let buildNumber, !buildNumber.isEmpty { result += ["--build-number", buildNumber] }
        if skipTests { result.append("--skip-tests") }
        if skipBuild { result.append("--skip-build") }
        if let onboardName, !onboardName.isEmpty { result += ["--name", onboardName] }
        if let onboardPlatforms, !onboardPlatforms.isEmpty { result += ["--platforms", onboardPlatforms] }
        if let androidPackage, !androidPackage.isEmpty { result += ["--android-package", androidPackage] }
        if let iosBundleID, !iosBundleID.isEmpty { result += ["--ios-bundle-id", iosBundleID] }
        if let iosTeamID, !iosTeamID.isEmpty { result += ["--ios-team-id", iosTeamID] }
        if let track, !track.isEmpty { result += ["--track", track] }
        if let propertiesPath, !propertiesPath.isEmpty { result += ["--properties", propertiesPath] }
        if let keystorePath, !keystorePath.isEmpty { result += ["--keystore", keystorePath] }
        if force { result.append("--force") }
        if link { result.append("--link") }
        if dryRun { result.append("--dry-run") }
        return result
    }

    var commandPreview: String {
        CommandPreview.frk(arguments)
    }
}

enum CommandPreview {
    static func frk(_ arguments: [String]) -> String {
        "frk " + arguments.map(shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ActivityLine: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let kind: Kind

    enum Kind: Equatable {
        case info
        case success
        case error
    }
}

enum RunOutcome: Equatable {
    case success
    case failure
    case cancelled
}
