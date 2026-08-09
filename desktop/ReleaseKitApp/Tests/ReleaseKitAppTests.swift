import XCTest
@testable import ReleaseKitApp

final class ReleaseKitAppTests: XCTestCase {
    func testCapabilitiesDecodeTheVersionedContract() throws {
        let json = #"{"protocolVersion":1,"cliVersion":"0.2.0","minimumDesktopProtocol":1,"maximumDesktopProtocol":1,"capabilities":{"projectDiscovery":true,"streamingEvents":true,"productionRelease":false,"platforms":["android","ios"],"actions":["build","release"]}}"#

        let response = try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.protocolVersion, 1)
        XCTAssertEqual(response.cliVersion, "0.2.0")
        XCTAssertFalse(response.capabilities.productionRelease)
        XCTAssertEqual(response.capabilities.platforms, ["android", "ios"])
    }

    func testProjectDecodeDoesNotRequireAnUnusedPlatform() throws {
        let json = #"{"protocolVersion":1,"cliVersion":"0.2.0","projects":[{"id":"example","name":"Example","path":"/tmp/example","exists":true,"onboarded":true,"state":"ready","platforms":["android"],"version":"1.2.0+42","buildName":"1.2.0","buildNumber":42,"android":{"packageId":"com.example.app","signingReady":true,"track":"internal"},"ios":null,"artifacts":{"androidAab":null,"iosIpa":null},"addedAt":null}]}"#

        let response = try JSONDecoder().decode(ProjectsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.projects.first?.platforms, [.android])
        XCTAssertTrue(response.projects.first?.android?.signingReady == true)
        XCTAssertNil(response.projects.first?.ios)
    }

    func testReleaseArgumentsUseOnlyTheStableAPI() {
        let request = FRKRunRequest(
            action: .release,
            project: "example",
            platform: .ios,
            buildName: "2.0.0",
            buildNumber: "51"
        )

        XCTAssertEqual(request.arguments, [
            "api", "run", "release", "example",
            "--platform", "ios",
            "--build-name", "2.0.0",
            "--build-number", "51",
        ])
        XCTAssertEqual(
            request.commandPreview,
            "frk api run release example --platform ios --build-name 2.0.0 --build-number 51"
        )
    }

    func testCommandPreviewQuotesPathsWithSpaces() {
        let request = FRKRunRequest(action: .onboard, project: "/tmp/My App")

        XCTAssertEqual(request.commandPreview, "frk api run onboard '/tmp/My App'")
    }

    func testOnboardingCanUseAutoDetection() {
        let request = FRKRunRequest(
            action: .onboard,
            project: "/tmp/example",
            onboardName: "Example",
            onboardPlatforms: nil,
            track: "internal",
            dryRun: true
        )

        XCTAssertEqual(request.arguments, [
            "api", "run", "onboard", "/tmp/example",
            "--name", "Example",
            "--track", "internal",
            "--dry-run",
        ])
    }

    func testSetupStatusDecodesWithoutSigningSecrets() throws {
        let json = #"{"protocolVersion":1,"cliVersion":"0.3.0","projectId":"example","android":{"configured":true,"packageId":"org.example.app","projectPropertiesPath":"/app/android/key.properties","projectPropertiesExists":true,"propertiesComplete":true,"referencedKeystorePath":"/app/android/missing.jks","keystoreExists":false,"vaultPath":"/vault/org.example.app","vaultReady":false,"projectLinked":false,"gitTracked":false,"signingReady":false},"ios":{"configured":true,"bundleId":"org.example.app","teamId":"ABCDE12345","workspacePath":"/app/ios/Runner.xcworkspace","workspaceExists":true,"distributionIdentityReady":true,"ascCredentialsReady":true,"profilePath":"/vault/profile.mobileprovision","profileReady":false,"signingReady":false},"error":null}"#

        let response = try JSONDecoder().decode(SetupStatusResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.projectId, "example")
        XCTAssertFalse(response.android?.keystoreExists ?? true)
        XCTAssertTrue(response.ios?.ascCredentialsReady == true)
        XCTAssertFalse(response.ios?.signingReady ?? true)
    }

    func testCredentialStatusDecodesWithoutPrivateKeyContents() throws {
        let json = #"{"protocolVersion":1,"cliVersion":"0.3.0","vaultPath":"/vault","configuredAny":true,"googlePlay":{"configured":true,"validationStatus":"ready","detail":"Service-account key is valid","keyPath":"/vault/play/service-account.json","clientEmail":"release@example.com","projectId":"release-project"},"appStoreConnect":{"configured":false,"validationStatus":"missing","detail":"App Store Connect .p8 key is not configured","keyPath":null,"keyId":null,"issuerId":null}}"#

        let response = try JSONDecoder().decode(CredentialsResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.hasConfiguredStore)
        XCTAssertEqual(response.googlePlay?.projectId, "release-project")
        XCTAssertFalse(response.appStoreConnect?.configured ?? true)
        XCTAssertFalse(json.contains("BEGIN PRIVATE KEY"))
    }

    func testCredentialAssistantAppearsOnlyUntilAStoreOrLocalOnlyDecisionExists() {
        XCTAssertTrue(CredentialOnboardingPolicy.shouldPresent(
            hasConfiguredStore: false,
            setupDecisionMade: false
        ))
        XCTAssertFalse(CredentialOnboardingPolicy.shouldPresent(
            hasConfiguredStore: true,
            setupDecisionMade: false
        ))
        XCTAssertFalse(CredentialOnboardingPolicy.shouldPresent(
            hasConfiguredStore: false,
            setupDecisionMade: true
        ))
    }

    func testSigningImportRequestUsesStableMachineAPI() {
        let request = FRKRunRequest(
            action: .signingImport,
            project: "example",
            keystorePath: "/backup/upload.jks",
            link: true
        )

        XCTAssertEqual(request.arguments, [
            "api", "run", "signing-import", "example",
            "--keystore", "/backup/upload.jks",
            "--link",
        ])
    }

    func testForgetRequestUsesTheStableAPIAndTargetsOnlyOneManagedProject() {
        let request = FRKRunRequest(action: .forget, project: "example")

        XCTAssertEqual(request.arguments, ["api", "run", "forget", "example"])
    }

    func testClientReadsTheRealLocalCLIContract() async throws {
        let client = FRKClient(executableURL: realCLIURL())

        let capabilities = try await client.capabilities()
        let projects = try await client.projects()
        let credentials = try await client.credentials()

        XCTAssertEqual(capabilities.protocolVersion, 1)
        XCTAssertEqual(projects.protocolVersion, 1)
        XCTAssertEqual(credentials.protocolVersion, 1)
    }

    func testStreamingClientReceivesTerminalEventFromRealCLI() throws {
        let client = FRKClient(executableURL: realCLIURL())
        let pipe = Pipe()
        let process = try client.makeStreamingProcess(
            arguments: FRKRunRequest(action: .status).arguments,
            pipe: pipe
        )

        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let events = String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(APIEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(events.first?.type, "started")
        XCTAssertEqual(events.last?.type, "finished")
        XCTAssertEqual(events.last?.success, true)
    }

    func testWorkspaceUsesFocusedLayoutBeforeContentWouldClip() {
        XCTAssertEqual(WorkspaceLayoutMode(width: 680), .focused)
        XCTAssertEqual(WorkspaceLayoutMode(width: 899), .focused)
        XCTAssertEqual(WorkspaceLayoutMode(width: 900), .standard)
        XCTAssertEqual(WorkspaceLayoutMode(width: 979), .standard)
        XCTAssertEqual(WorkspaceLayoutMode(width: 980), .expanded)
    }

    private func realCLIURL() -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/frk")
    }
}
