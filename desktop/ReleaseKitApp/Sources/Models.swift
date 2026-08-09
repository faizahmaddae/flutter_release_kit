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

struct ProjectResponse: Codable, Equatable {
    let protocolVersion: Int
    let cliVersion: String
    let project: ProjectSummary?
    let error: APIErrorPayload?
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
