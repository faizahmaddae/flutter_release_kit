import AppKit
import ImageIO
import XCTest
@testable import ReleaseKitApp

final class ReleaseKitAppTests: XCTestCase {
    private static var sandboxHome: URL?

    override class func setUp() {
        super.setUp()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseKitAppTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sandboxHome = home
        // This setenv is what isolates the CLI-touching tests from the developer's real
        // vault; the sandbox home then deliberately stays empty. `frk setup` is NOT run
        // to seed it: `api capabilities`, `api projects`, `api credentials` and
        // `api run status` all exit 0 against an empty home and emit byte-identical
        // documents either way (load_registry falls back to an empty registry), so the
        // seed bought nothing while its `try?` + nullDevice hid its own failures.
        setenv("FLUTTER_RELEASE_HOME", home.path, 1)
    }

    override class func tearDown() {
        unsetenv("FLUTTER_RELEASE_HOME")
        if let home = sandboxHome {
            try? FileManager.default.removeItem(at: home)
            sandboxHome = nil
        }
        super.tearDown()
    }

    override func tearDown() {
        // splitVersionName/storeVersions persistence writes into UserDefaults.standard,
        // which for `swift test` resolves to the xctest runner's own shared domain
        // (com.apple.dt.xctest.tool) rather than the shipped app's
        // (com.faizdae.flutter-release-kit) — confirmed empirically, so a test run can
        // never reach a user's real preferences. It IS one shared domain across every
        // `swift test` invocation on this machine, though, so a key left behind by one
        // test can make an unrelated later test - possibly reusing the same project id -
        // flaky. Sweep every key this feature can write after each test, unconditionally.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("frkSplitVersionName.") || key.hasPrefix("frkStoreVersionsCache.") {
            defaults.removeObject(forKey: key)
        }
        super.tearDown()
    }

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

    func testIOSReadinessFallsBackToTheProfileOnlyWhenTheCLIOmitsSigningReady() {
        // IOSSummary.signingReady is optional because an older CLI omits it, so every
        // combination below has to resolve to exactly one platform-card badge.
        let cases: [(signingReady: Bool?, profileReady: Bool, ready: Bool, label: String)] = [
            (nil, true, true, "Signing ready"),
            (nil, false, false, "Profile required"),
            (true, true, true, "Signing ready"),
            // signingReady wins outright when present: the CLI already judged the whole
            // chain, so a false profileReady beside it does not downgrade the badge.
            (true, false, true, "Signing ready"),
            // ...and when signingReady says no, profileReady only picks the wording.
            (false, true, false, "Signing required"),
            (false, false, false, "Profile required"),
        ]

        for testCase in cases {
            let readiness = Self.iosProject(
                signingReady: testCase.signingReady,
                profileReady: testCase.profileReady
            ).readiness(for: .ios)
            let described = "signingReady \(String(describing: testCase.signingReady)),"
                + " profileReady \(testCase.profileReady)"

            XCTAssertEqual(readiness.ready, testCase.ready, described)
            XCTAssertEqual(readiness.label, testCase.label, described)
        }

        // A project with no iOS summary at all takes the same not-ready path rather
        // than trapping on the optional chain.
        let absent = Self.projectSummary(id: "apple", name: "apple").readiness(for: .ios)
        XCTAssertFalse(absent.ready)
        XCTAssertEqual(absent.label, "Signing required")
    }

    func testAndroidReadinessRequiresAnExplicitlyReadySigningFlag() {
        XCTAssertEqual(
            Self.projectSummary(id: "apple", name: "apple").readiness(for: .android).label,
            "Signing ready"
        )

        let absent = Self.iosProject(signingReady: true, profileReady: true).readiness(for: .android)
        XCTAssertFalse(absent.ready)
        XCTAssertEqual(absent.label, "Signing required")
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

    func testAndroidKeystoreStateReadsOnlyTheCLIsValidationVocabulary() {
        // These two spellings are a cross-language contract with bin/frk, which emits
        // "valid" / "partial" / "invalid" for keystoreValidationStatus. The key-name
        // contract fixture pins NAMES only, so nothing else catches a renamed VALUE —
        // and a rename degrades a healthy keystore to .error silently.
        XCTAssertEqual(Self.androidSetupStatus(keystoreValidationStatus: "valid").keystoreState, .ready)
        XCTAssertEqual(Self.androidSetupStatus(keystoreValidationStatus: "partial").keystoreState, .warning)

        XCTAssertEqual(Self.androidSetupStatus(keystoreValidationStatus: "invalid").keystoreState, .error)
        XCTAssertEqual(Self.androidSetupStatus(keystoreValidationStatus: nil).keystoreState, .error)
        // Matching is exact and case sensitive, so a near miss fails closed.
        XCTAssertEqual(Self.androidSetupStatus(keystoreValidationStatus: "Valid").keystoreState, .error)
        XCTAssertEqual(Self.androidSetupStatus(keystoreValidationStatus: "ready").keystoreState, .error)

        // Both prerequisites are checked ahead of the vocabulary, so a stale "valid"
        // never outranks a missing file or an incomplete key.properties.
        XCTAssertEqual(
            Self.androidSetupStatus(propertiesComplete: false, keystoreValidationStatus: "valid").keystoreState,
            .error
        )
        XCTAssertEqual(
            Self.androidSetupStatus(keystoreExists: false, keystoreValidationStatus: "valid").keystoreState,
            .error
        )
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

    func testScreenshotCaptureSuggestsTheMatchingPhoneFrame() {
        // No size at all: the pre-capture call site holds no image yet, so the phone frame is
        // the only honest answer. Spelled `.androidPhone` rather than the transitional
        // `.android` shim in ScreenshotRenderer.swift, which now has no remaining callers.
        XCTAssertEqual(ScreenshotCaptureService.suggestedFrame(for: .android), .androidPhone)
        XCTAssertEqual(ScreenshotCaptureService.suggestedFrame(for: .ios), .iphone)
        XCTAssertEqual(ScreenshotFrameStyle.androidPhone.platform, .android)
        XCTAssertEqual(ScreenshotFrameStyle.androidTablet.platform, .android)
        XCTAssertEqual(ScreenshotFrameStyle.iphone.platform, .ios)
        XCTAssertEqual(ScreenshotFrameStyle.ipad.platform, .ios)
        XCTAssertNil(ScreenshotFrameStyle.none.platform)
        // `ScreenshotFrameStyle` is an alias for the catalogue's `ScreenshotFrame` so the two
        // cannot drift; assigning across the names is what proves it.
        let alias: ScreenshotFrameStyle = ScreenshotFrame.androidTablet
        XCTAssertEqual(alias, .androidTablet)
    }

    func testSuggestedFrameSplitsPhoneFromTabletOnTheShortEdge() {
        // The threshold is read off the SHORT edge, so a rotated capture classifies exactly
        // as its portrait twin does - one rule, no landscape branch.
        let cases: [(platform: PlatformKind, size: CGSize, frame: ScreenshotFrame)] = [
            (.ios, CGSize(width: 1320, height: 2868), .iphone),          // iPhone 6.9″
            (.ios, CGSize(width: 750, height: 1334), .iphone),           // legacy 4.7″
            (.ios, CGSize(width: 1488, height: 2266), .ipad),            // iPad 11″
            (.ios, CGSize(width: 2064, height: 2752), .ipad),            // iPad 13″
            (.android, CGSize(width: 1080, height: 2400), .androidPhone),
            (.android, CGSize(width: 1344, height: 2992), .androidPhone),
            (.android, CGSize(width: 1600, height: 2560), .androidTablet),
            // Inclusive at exactly 1400.
            (.android, CGSize(width: 1399, height: 3000), .androidPhone),
            (.android, CGSize(width: 1400, height: 3000), .androidTablet),
            // Landscape twins of three of the rows above.
            (.ios, CGSize(width: 2752, height: 2064), .ipad),
            (.android, CGSize(width: 2400, height: 1080), .androidPhone),
            (.android, CGSize(width: 2560, height: 1600), .androidTablet),
            // Degenerate sizes fall through to the phone rather than trapping.
            (.android, CGSize(width: 0, height: 0), .androidPhone),
            (.ios, CGSize(width: -10, height: -10), .iphone),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ScreenshotCaptureService.suggestedFrame(for: testCase.platform, sourceSize: testCase.size),
                testCase.frame,
                "\(testCase.platform.title) \(Int(testCase.size.width))×\(Int(testCase.size.height))"
            )
        }

        // Documented false positive, pinned deliberately: a 1440 × 3120 Galaxy S24 Ultra
        // capture reads as a tablet. Correcting it needs an aspect guard the spec does not
        // authorise, so this asserts today's behaviour rather than the behaviour we want -
        // a future fix should have to change this line on purpose.
        XCTAssertEqual(
            ScreenshotCaptureService.suggestedFrame(for: .android, sourceSize: CGSize(width: 1440, height: 3120)),
            .androidTablet
        )
        XCTAssertEqual(ScreenshotCaptureService.tabletShortEdgeThreshold, 1400)
    }

    func testAndroidDiscoveryReadsAnEmulatorLine() {
        let targets = ScreenshotCaptureService.parseAndroidDevices("""
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        """)

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.id, "emulator-5554")
        // Pins the `_` -> space substitution applied to every property value: adb
        // never emits a space inside a token, so the model arrives underscored.
        XCTAssertEqual(targets.first?.name, "sdk gphone64 arm64")
        XCTAssertEqual(targets.first?.detail, "Android Emulator · emulator-5554")
        XCTAssertEqual(targets.first?.platform, .android)
    }

    func testAndroidDiscoverySkipsDevicesThatCannotBeCaptured() {
        let targets = ScreenshotCaptureService.parseAndroidDevices("""
        List of devices attached
        R3CN90ABCDE            device usb:1 product:t2s model:Galaxy_S21 device:o1s transport_id:2
        0123456789ABCDEF       offline
        9876543210FEDCBA       unauthorized
        FEDCBA9876543210       device usb:2 product:t2s device:beyond1 transport_id:5
        """)

        // `offline` and `unauthorized` handsets cannot answer `exec-out screencap`,
        // so only the two `device`-state serials survive.
        XCTAssertEqual(targets.map(\.id), ["R3CN90ABCDE", "FEDCBA9876543210"])
        XCTAssertEqual(targets.first?.name, "Galaxy S21")
        XCTAssertEqual(targets.first?.detail, "Android device · R3CN90ABCDE")
        // No `model:` token, so the name falls back to the `device:` codename.
        XCTAssertEqual(targets.last?.name, "beyond1")
    }

    func testAndroidDiscoverySurvivesMalformedPropertyTokens() {
        // Regression: this line used to reach Dictionary(uniqueKeysWithValues:),
        // which TRAPS on a duplicate key. It ran inside a detached Task with no
        // catch site, so one repeated token from `adb devices -l` took the whole
        // app down the moment Screenshot Studio opened.
        let targets = ScreenshotCaptureService.parseAndroidDevices("""
        List of devices attached
        emulator-5556          device transport_id:1 transport_id:2 :x bare model:Pixel_7 model:Pixel_9
        """)

        XCTAssertEqual(targets.count, 1)
        // First value wins for a repeated key.
        XCTAssertEqual(targets.first?.name, "Pixel 7")
        XCTAssertEqual(targets.first?.id, "emulator-5556")
    }

    func testAndroidDiscoveryReturnsWhenAdbFloodsStderr() throws {
        // Regression: the run helper drained stdout to EOF before touching stderr.
        // A child that fills the 64 KiB stderr buffer blocks, never closes stdout,
        // and the reader waits forever - and Task.detached does not inherit
        // cancellation, so dismissing the sheet could not reclaim it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("frk-fake-adb-\(UUID().uuidString)", isDirectory: true)
        let tools = root.appendingPathComponent("platform-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let adb = tools.appendingPathComponent("adb")
        try """
        #!/bin/sh
        head -c 200000 /dev/zero | tr '\\0' 'x' >&2
        printf 'List of devices attached\\n'
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

        let previousAndroidHome = ProcessInfo.processInfo.environment["ANDROID_HOME"]
        setenv("ANDROID_HOME", root.path, 1)
        defer {
            if let previousAndroidHome {
                setenv("ANDROID_HOME", previousAndroidHome, 1)
            } else {
                unsetenv("ANDROID_HOME")
            }
        }

        let finished = expectation(description: "device discovery returns")
        Task {
            let targets = await ScreenshotCaptureService.discoverTargets(for: [.android])
            XCTAssertTrue(targets.isEmpty)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
    }

    func testScreenshotRendererCreatesHighResolutionPNGWithoutChangingSource() throws {
        let source = testImage(width: 320, height: 640)
        let originalSize = ScreenshotRenderer.sourcePixelSize(source)
        let options = ScreenshotRenderOptions(
            frame: .iphone,
            canvas: .transparent,
            paddingPercent: 8
        )

        let data = try ScreenshotRenderer.pngData(image: source, options: options)
        let output = try XCTUnwrap(NSBitmapImageRep(data: data))

        // Worked out by hand from ScreenshotRenderer so this test PINS the Free-mode
        // geometry instead of restating it. Deriving the expectation by calling
        // outputPixelSize() would be a tautology: pngData() sizes its bitmap with
        // that same call, so both sides would move together.
        //
        // Free mode is the one place an output dimension is still an accident of the
        // capture size, which is exactly why no store preset uses it.
        //
        //   bezel  = max(2, round(0.030 * min(320, 640))) = round(9.6) = 10, all four sides
        //   box    = 320 + 20                             = 340
        //            640 + 20                             = 660
        //   margin = round(max(340, 660) * min(8, 20) / 100) = round(52.8) = 53 per side
        //   canvas = 340 + 106                            = 446
        //            660 + 106                            = 766
        XCTAssertEqual(output.pixelsWide, 446)
        XCTAssertEqual(output.pixelsHigh, 766)

        // Secondary, and independently valuable: ScreenshotStudioView shows
        // outputPixelSize() to the user as the export size before any render
        // happens, so the prediction and the produced PNG must not drift apart.
        let predicted = ScreenshotRenderer.outputPixelSize(
            source: try XCTUnwrap(originalSize),
            options: options
        )
        XCTAssertEqual(Int(predicted.width), output.pixelsWide)
        XCTAssertEqual(Int(predicted.height), output.pixelsHigh)

        XCTAssertEqual(ScreenshotRenderer.sourcePixelSize(source), originalSize)

        // §6: the capture is read-only, always. The temp file ScreenshotCaptureService
        // wrote is never reopened for writing, whichever export path runs over it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frk-screenshot-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("capture.png")
        let sourceBitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let sourceBytes = try XCTUnwrap(sourceBitmap.representation(using: .png, properties: [:]))
        try sourceBytes.write(to: file)

        let onDisk = try XCTUnwrap(NSImage(contentsOf: file))
        _ = try ScreenshotRenderer.pngData(image: onDisk, options: options)
        _ = try ScreenshotRenderer.pngData(
            image: onDisk,
            preset: StorePresetCatalog.defaultPreset,
            options: ScreenshotRenderOptions(frame: .iphone)
        )
        _ = try ScreenshotRenderer.renderedImage(image: onDisk, options: options)

        XCTAssertEqual(try Data(contentsOf: file), sourceBytes)
        XCTAssertEqual(ScreenshotRenderer.sourcePixelSize(onDisk), CGSize(width: 320, height: 640))
    }

    // MARK: - Screenshot Studio: store presets

    func testStorePresetSizesAreTheOnesTheStoresPublish() {
        // Hand-transcribed from the spec's tables and NOT read back out of the catalogue.
        // A wrong number here is a store rejection, so the expectation has to be authored
        // independently of the thing it checks.
        let expected: [(id: String, size: PixelSize)] = [
            ("apple.iphone69.portrait", PixelSize(1320, 2868)),
            ("apple.iphone69.landscape", PixelSize(2868, 1320)),
            ("apple.ipad13.portrait", PixelSize(2064, 2752)),
            ("apple.ipad13.landscape", PixelSize(2752, 2064)),
            ("apple.mac", PixelSize(2880, 1800)),
            ("apple.iphone65.portrait", PixelSize(1284, 2778)),
            ("apple.iphone63.portrait", PixelSize(1206, 2622)),
            ("apple.iphone61.portrait", PixelSize(1170, 2532)),
            ("apple.ipad11.portrait", PixelSize(1488, 2266)),
            ("apple.iphone55.portrait", PixelSize(1242, 2208)),
            ("apple.iphone47.portrait", PixelSize(750, 1334)),
            ("apple.iphone40.portrait", PixelSize(640, 1136)),
            ("apple.iphone35.portrait", PixelSize(640, 960)),
            ("apple.ipad129.portrait", PixelSize(2048, 2732)),
            ("apple.ipad105.portrait", PixelSize(1668, 2224)),
            ("apple.ipad97.portrait", PixelSize(1536, 2048)),
            ("play.phone.portrait", PixelSize(1080, 1920)),
            ("play.phone.landscape", PixelSize(1920, 1080)),
            ("play.featureGraphic", PixelSize(1024, 500)),
            ("play.tablet.landscape.hd", PixelSize(1920, 1080)),
            ("play.tablet.landscape.qhd", PixelSize(2560, 1440)),
            // 1440 × 2560, not the spec table's 1600 × 2560. The spec describes this row as
            // "9:16 within the size band" and then prints a number that is 8:5, so the two
            // halves of that sentence disagree; 1440 × 2560 is the half Play's own
            // large-screen rule can be satisfied by. 1600 × 2560 survives as an alternate.
            ("play.tablet.portrait", PixelSize(1440, 2560)),
            ("play.chromebook.landscape", PixelSize(1920, 1080)),
            ("play.tv.screenshot", PixelSize(1920, 1080)),
            ("play.tv.banner", PixelSize(1280, 720)),
            ("play.wear", PixelSize(384, 384)),
        ]

        XCTAssertEqual(StorePresetCatalog.all.count, expected.count)
        XCTAssertEqual(Set(StorePresetCatalog.all.map(\.id)), Set(expected.map(\.id)))
        for row in expected {
            guard let preset = StorePresetCatalog.preset(id: row.id) else {
                XCTFail("missing preset \(row.id)")
                continue
            }
            XCTAssertEqual(preset.pixelSize, row.size, row.id)
        }

        // The 6.9″ alternates matter as much as the primary: they are what the size menu
        // offers, and an unaccepted size there is the same rejection by another door.
        XCTAssertEqual(
            StorePresetCatalog.defaultPreset.alternates,
            [PixelSize(1290, 2796), PixelSize(1260, 2736)]
        )
        XCTAssertEqual(StorePresetCatalog.defaultPreset.id, "apple.iphone69.portrait")
    }

    func testTheMandatoryPresetSetIsExactlyWhatTheSpecRequires() {
        // Required for every project, no condition attached. Ordered: requirement rank,
        // then store with Apple first, then declaration order.
        XCTAssertEqual(
            StorePresetCatalog.all.filter { $0.requirement == .required }.map(\.id),
            ["apple.iphone69.portrait", "play.phone.portrait", "play.featureGraphic"]
        )

        // Everything in the mandatory tier: unconditional plus "required once this holds"
        // (an iPad target, a macOS target, a TV or Wear OS build, a landscape-only app).
        XCTAssertEqual(
            Set(StorePresetCatalog.mandatory.map(\.id)),
            [
                "apple.iphone69.portrait",
                "apple.iphone69.landscape",
                "apple.ipad13.portrait",
                "apple.ipad13.landscape",
                "apple.mac",
                "play.phone.portrait",
                "play.phone.landscape",
                "play.featureGraphic",
                "play.tv.screenshot",
                "play.tv.banner",
                "play.wear",
            ]
        )

        // Apple removed the 5.5″ iPhone and 12.9″ iPad requirements in September 2024.
        // Plenty of tooling still marks them required; this catalogue must not.
        for id in ["apple.iphone55.portrait", "apple.ipad129.portrait", "apple.ipad97.portrait"] {
            guard let preset = StorePresetCatalog.preset(id: id) else {
                XCTFail("missing preset \(id)")
                continue
            }
            XCTAssertFalse(preset.isMandatory, id)
            XCTAssertTrue(preset.isLegacy, id)
        }
        XCTAssertTrue(StorePresetCatalog.current.allSatisfy { !$0.isLegacy })
        XCTAssertEqual(StorePresetCatalog.legacy.count, 7)

        // The large-screen rows unlock placement; their absence never blocks a release.
        XCTAssertEqual(
            Set(StorePresetCatalog.recommended.map(\.id)),
            [
                "play.tablet.landscape.hd",
                "play.tablet.landscape.qhd",
                "play.tablet.portrait",
                "play.chromebook.landscape",
            ]
        )

        // No preset this tool ships permits an alpha channel - not one.
        XCTAssertTrue(StorePresetCatalog.all.allSatisfy { !$0.allowsAlpha })

        // Wear OS is the one preset that forbids a frame, a background and padding outright.
        guard let wear = StorePresetCatalog.preset(id: "play.wear") else { return XCTFail("missing play.wear") }
        XCTAssertFalse(wear.allowsBackground)
        XCTAssertTrue(wear.isFrameLocked)
        XCTAssertEqual(wear.allowedFrames, [.none])
        XCTAssertEqual(wear.defaultFit, .fillCrop)
        XCTAssertTrue(StorePresetCatalog.all.filter { !$0.allowsBackground }.map(\.id) == ["play.wear"])
    }

    func testPlayValidatorRejectsTheDefaultPixelAspectAndCapsAt3840() {
        // The single most common failure this tool exists to prevent: 1080 × 2400 is the
        // native aspect of most modern Android phones and of the default Pixel emulator,
        // and 20:9 is steeper than Play's 2:1 cap.
        let pixel = PixelSize(1080, 2400)
        XCTAssertFalse(PlayImageRules.isValid(pixel))
        XCTAssertEqual(PlayImageRules.validate(pixel), [.tooElongated(size: pixel)])
        XCTAssertEqual(PlayImageRules.aspectLabel(pixel), "20:9")
        XCTAssertTrue(PlayImageRules.rejectionReason(for: pixel)?.contains("20:9") == true)
        // Pad the short edge, never crop the long one.
        XCTAssertEqual(PlayImageRules.nearestLegalSize(for: pixel), PixelSize(1200, 2400))

        // 1080 × 1920 is exactly 9:16 and clears both the publish gate and the ≥1080px
        // promo-eligibility gate, which is why it is the chosen Play phone size.
        XCTAssertTrue(PlayImageRules.isValid(PixelSize(1080, 1920)))
        XCTAssertNil(PlayImageRules.rejectionReason(for: PixelSize(1080, 1920)))
        XCTAssertEqual(PlayImageRules.aspectLabel(PixelSize(1080, 1920)), "16:9")
        XCTAssertTrue(PlayImageRules.isValid(PixelSize(1920, 1080)))
        // Exactly 2:1 is the boundary and is accepted; one pixel past it is not.
        XCTAssertTrue(PlayImageRules.isValid(PixelSize(1000, 2000)))
        XCTAssertFalse(PlayImageRules.isValid(PixelSize(1000, 2001)))

        XCTAssertEqual(PlayImageRules.validate(PixelSize(300, 400)), [.tooSmall(dimension: 300)])
        XCTAssertEqual(PlayImageRules.validate(PixelSize(2000, 4000)), [.tooLarge(dimension: 4000)])

        // ⚠︎CONTRADICTORY: the same Play page also says "1,080 to 7,680px". The requirements
        // block is the binding one, so the cap is 3840 and a 7680px asset is rejected here
        // rather than at upload.
        XCTAssertEqual(PlayImageRules.maxDimension, 3840)
        XCTAssertEqual(PlayImageRules.minDimension, 320)
        XCTAssertFalse(PlayImageRules.isValid(PixelSize(3840, 7680)))
        XCTAssertFalse(PlayImageRules.dimensionCaveat.isEmpty)

        // Nothing in the catalogue is capped above 3840, on any accepted size, either store.
        for preset in StorePresetCatalog.all {
            for size in preset.acceptedSizes {
                XCTAssertLessThanOrEqual(size.maxDimension, PlayImageRules.maxDimension, "\(preset.id) \(size)")
                XCTAssertGreaterThanOrEqual(size.minDimension, PlayImageRules.minDimension, "\(preset.id) \(size)")
            }
        }

        // Every Play size the universal rules actually govern passes them...
        for preset in StorePresetCatalog.presets(for: .play) where preset.followsPlayDimensionRules {
            XCTAssertTrue(PlayImageRules.isValid(preset.pixelSize), preset.id)
        }
        // ...and the feature graphic is the proof the exemption has to exist: Google fixes it
        // at 1024 × 500, which is 2.048:1 and fails Google's own screenshot cap.
        guard let featureGraphic = StorePresetCatalog.preset(id: "play.featureGraphic") else {
            return XCTFail("missing play.featureGraphic")
        }
        XCTAssertTrue(featureGraphic.hasFixedSize)
        XCTAssertFalse(featureGraphic.followsPlayDimensionRules)
        XCTAssertFalse(PlayImageRules.isValid(featureGraphic.pixelSize))
    }

    // MARK: - Screenshot Studio: renderer geometry

    func testEveryPresetExportsAtExactlyItsDeclaredPixelSize() throws {
        // The inversion this rebuild exists for. Before it, outputPixelSize() derived the
        // canvas from `source + frameInsets + padding`, so no store size could ever be hit.
        let source = testImage(width: 540, height: 1200)
        let sourceSize = try XCTUnwrap(ScreenshotRenderer.sourcePixelSize(source))

        for preset in StorePresetCatalog.all {
            var options = ScreenshotRenderOptions()
            options.target = .preset(preset)
            options.frame = preset.defaultFrame
            options.canvas = .accent
            options.fit = preset.defaultFit

            let predicted = ScreenshotRenderer.outputPixelSize(source: sourceSize, options: options)
            XCTAssertEqual(Int(predicted.width), preset.pixelSize.width, preset.id)
            XCTAssertEqual(Int(predicted.height), preset.pixelSize.height, preset.id)

            // Asserted on the encoded bytes, not on the bitmap rep: the IHDR is what the
            // store's validator reads.
            let data = try ScreenshotRenderer.pngData(image: source, options: options)
            XCTAssertEqual(ScreenshotPreflight.pngPixelSize(data), preset.pixelSize, preset.id)

            // §3.1/§3.2: colour type 2 is 24-bit RGB. Every export this tool produced before
            // the rebuild was type 6, because render() allocated samplesPerPixel 4
            // unconditionally - and both stores reject an image carrying the channel even
            // when every pixel is fully opaque. Nothing exported here had ever been
            // uploadable, on any canvas style, to either store.
            XCTAssertEqual(ScreenshotPreflight.pngColourType(data), 2, preset.id)
            XCTAssertEqual(ScreenshotRenderer.pngColorType(data), 2, preset.id)
            XCTAssertNoThrow(try ScreenshotRenderer.assertNoAlpha(data), preset.id)
        }
    }

    func testPresetCanvasIsExactAcrossEveryFrameAndAspectRatioWithConcentricCorners() {
        // Pure geometry, nothing rasterised: layout() is the single place any rounding
        // happens, so it is the thing worth exhausting.
        let sources = [
            CGSize(width: 1080, height: 2400),   // 20:9, the modern Android phone
            CGSize(width: 1320, height: 2868),   // 19.5:9, iPhone 6.9″
            CGSize(width: 1920, height: 1080),   // 16:9 landscape
            CGSize(width: 1536, height: 2048),   // 4:3, legacy iPad
            CGSize(width: 2048, height: 1536),   // 4:3 landscape
            CGSize(width: 1000, height: 1000),   // 1:1
            CGSize(width: 750, height: 1334),    // small enough to trip the readability rule
        ]

        for preset in StorePresetCatalog.all {
            for frame in ScreenshotFrame.allCases {
                for fit in FitPolicy.allCases {
                    for source in sources {
                        var options = ScreenshotRenderOptions()
                        options.target = .preset(preset)
                        options.frame = frame
                        options.fit = fit
                        let plan = ScreenshotRenderer.layout(source: source, options: options)
                        let label = "\(preset.id) \(frame.rawValue) \(fit.rawValue) \(Int(source.width))×\(Int(source.height))"

                        XCTAssertEqual(plan.canvas, preset.pixelSize.cgSize, label)
                        // Non-concentric corners are the single thing that makes a hand-drawn
                        // frame read as fake, so the outer radius is never authored.
                        XCTAssertEqual(plan.outerRadius, plan.screenRadius + plan.bezel, accuracy: 1e-9, label)
                        XCTAssertEqual(plan.screenRect.width, plan.boxRect.width - 2 * plan.bezel, accuracy: 1e-9, label)
                        XCTAssertEqual(plan.screenRect.height, plan.boxRect.height - 2 * plan.bezel, accuracy: 1e-9, label)
                        // A framed export never crops: the canvas absorbs 100% of the mismatch.
                        // Read the RESOLVED frame - a frame-locked preset (Wear, Mac, TV)
                        // overrides the request, and then the fit policy is back in play.
                        if options.resolvedFrame != .none {
                            XCTAssertEqual(plan.sourceRect, CGRect(origin: .zero, size: source), label)
                            XCTAssertEqual(plan.croppedFraction, 0, label)
                        }
                        // The device is centred inside the canvas, and overhangs by at most one
                        // pixel per side. The tolerance is load-bearing, not slack: when the
                        // readability clamp is limited by the canvas HEIGHT it lands the box
                        // exactly on the canvas in reals, and rounding the screen width up to a
                        // whole pixel then pushes the box 1px past the top and bottom - box
                        // (396, -1, 233, 501) on the 1024 × 500 feature graphic from a 1080 × 2400
                        // capture, and the same on apple.iphone69.landscape from a portrait one.
                        // One clipped pixel on a 500px canvas is invisible; widening it would
                        // hide a real regression, so this pins it at exactly 1.
                        let bounds = CGRect(origin: .zero, size: plan.canvas).insetBy(dx: -1, dy: -1)
                        XCTAssertTrue(bounds.contains(plan.boxRect), "\(label) box \(plan.boxRect) escaped \(plan.canvas)")
                    }
                }
            }
        }
    }

    func testFramedAndFramelessLayoutsMatchHandDerivedGeometry() {
        // Every literal below is worked out by hand from the spec's layout algorithm and is
        // deliberately NOT obtained by calling the renderer. The previous version of this
        // suite derived its expectation from outputPixelSize(), which is precisely how it
        // became a tautology that passed through every geometry change.

        // A 1080 × 2400 Pixel capture into play.phone.portrait, androidPhone frame, 6% pad:
        //   ratio      = 2400 / 1080                              = 2.22222
        //   unitBezel  = 0.032 × min(1, ratio)                    = 0.032
        //   unitWidth  = 1.064          unitHeight = 2.28622
        //   margin     = 6% × min(1080, 1920)                     = 64.8
        //   usable     = 950.4 × 1790.4
        //   width      = min(950.4 / 1.064, 1790.4 / 2.28622)     = 783.13
        //   screen     = 783 × round(783 × 20/9)                  = 783 × 1740
        //   bezel      = max(2, round(0.032 × 783))               = 25
        //   box        = 833 × 1790, centred at (round(123.5), round(65)) = (124, 65)
        //   screen     = (149, 90)
        //   radius     = 0.085 × 783                              = 66.555
        let android = ScreenshotRenderer.layout(
            source: CGSize(width: 1080, height: 2400),
            options: options(preset: "play.phone.portrait", frame: .androidPhone, padding: 6)
        )
        XCTAssertEqual(android.canvas, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(android.boxRect, CGRect(x: 124, y: 65, width: 833, height: 1790))
        XCTAssertEqual(android.screenRect, CGRect(x: 149, y: 90, width: 783, height: 1740))
        XCTAssertEqual(android.bezel, 25)
        XCTAssertEqual(android.screenRadius, 66.555, accuracy: 1e-6)
        XCTAssertEqual(android.outerRadius, 91.555, accuracy: 1e-6)
        XCTAssertFalse(android.isEnlargedForReadability)

        // The same capture, frameless, fit & pad. Padding does not apply without a device to
        // inset, so the bars are the aspect mismatch itself: exactly 108px per side, which is
        // the number §2.3 quotes as "visually fine, legally compliant".
        //   scale = min(1080/1080, 1920/2400) = 0.8 -> 864 × 1920, centred at x = 108
        let padded = ScreenshotRenderer.layout(
            source: CGSize(width: 1080, height: 2400),
            options: options(preset: "play.phone.portrait", frame: .none, fit: .fitPad, padding: 6)
        )
        XCTAssertEqual(padded.screenRect, CGRect(x: 108, y: 0, width: 864, height: 1920))
        XCTAssertEqual(padded.horizontalBar, 108)
        XCTAssertEqual(padded.verticalBar, 0)
        XCTAssertEqual(padded.bezel, 0)
        XCTAssertEqual(padded.croppedFraction, 0)

        // ...and filling instead of padding costs exactly the fifth of the capture §2.3 says
        // it does - 240px off the top and 240px off the bottom.
        //   scale = max(1, 0.8) = 1 -> visible 1080 × 1920 centred in 1080 × 2400
        let cropped = ScreenshotRenderer.layout(
            source: CGSize(width: 1080, height: 2400),
            options: options(preset: "play.phone.portrait", frame: .none, fit: .fillCrop, padding: 6)
        )
        XCTAssertEqual(cropped.sourceRect, CGRect(x: 0, y: 240, width: 1080, height: 1920))
        XCTAssertEqual(cropped.screenRect, CGRect(x: 0, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(cropped.croppedFraction, 0.2, accuracy: 1e-9)

        // The same capture into the iPhone 6.9″ canvas: 1080 wide is under the 1161.6px usable
        // width, so the maxUpscale clamp pins the screen at native and nothing is enlarged.
        //   width  = min(1161.6/1.06, 2709.6/2.28222) = 1095.85, clamped to 1 × 1080
        //   bezel  = max(2, round(0.030 × 1080))      = 32
        //   box    = 1144 × 2464 centred at (88, 202); screen at (120, 234)
        //   radius = 0.135 × 1080                     = 145.8
        let iphone = ScreenshotRenderer.layout(
            source: CGSize(width: 1080, height: 2400),
            options: options(preset: "apple.iphone69.portrait", frame: .iphone, padding: 6)
        )
        XCTAssertEqual(iphone.boxRect, CGRect(x: 88, y: 202, width: 1144, height: 2464))
        XCTAssertEqual(iphone.screenRect, CGRect(x: 120, y: 234, width: 1080, height: 2400))
        XCTAssertEqual(iphone.bezel, 32)
        XCTAssertEqual(iphone.screenRadius, 145.8, accuracy: 1e-6)
        XCTAssertEqual(iphone.outerRadius, 177.8, accuracy: 1e-6)
        XCTAssertEqual(iphone.upscale, 1, accuracy: 1e-9)
        XCTAssertFalse(iphone.isEnlargedForReadability)

        // A 750 × 1334 legacy capture in the 2064 × 2752 iPad canvas is the case §2.2 is
        // built around: honouring maxUpscale would leave the device 822px wide on a 2064px
        // canvas, so the readability rule enlarges it to 55% of the canvas and says so.
        //   fit width       = min(1816.32/1.096, 2504.32/1.87467) = 1335.87, clamped to 750
        //   750 × 1.096 = 822 < 0.55 × 2064 = 1135.2  -> forced
        //   readable width  = 1135.2 / 1.096                      = 1035.77 -> 1036
        //   screen height   = round(1036 × 1334/750)              = 1843
        //   bezel           = max(2, round(0.048 × 1036))         = 50
        let enlarged = ScreenshotRenderer.layout(
            source: CGSize(width: 750, height: 1334),
            options: options(preset: "apple.ipad13.portrait", frame: .ipad, padding: 6)
        )
        XCTAssertTrue(enlarged.isEnlargedForReadability)
        XCTAssertEqual(enlarged.screenRect, CGRect(x: 514, y: 455, width: 1036, height: 1843))
        XCTAssertEqual(enlarged.boxRect, CGRect(x: 464, y: 405, width: 1136, height: 1943))
        XCTAssertEqual(enlarged.bezel, 50)
        XCTAssertEqual(enlarged.upscale, 1036.0 / 750.0, accuracy: 1e-9)
        XCTAssertTrue(CGRect(origin: .zero, size: enlarged.canvas).contains(enlarged.boxRect))

        // A native iPad capture in the same canvas is never enlarged: the margin alone takes
        // it below 1:1.
        //   width = min(1816.32/1.096, 2504.32/1.42933) = 1657.23 -> 1657; 1657/2064 = 0.8028
        let native = ScreenshotRenderer.layout(
            source: CGSize(width: 2064, height: 2752),
            options: options(preset: "apple.ipad13.portrait", frame: .ipad, padding: 6)
        )
        XCTAssertFalse(native.isEnlargedForReadability)
        XCTAssertEqual(native.screenRect.width, 1657)
        XCTAssertEqual(native.upscale, 1657.0 / 2064.0, accuracy: 1e-9)
    }

    func testAnAlternateSizeIsHonouredAndAnUnacceptedOneIsIgnored() throws {
        let source = testImage(width: 540, height: 1200)
        let preset = StorePresetCatalog.defaultPreset

        var options = ScreenshotRenderOptions()
        options.target = .preset(preset)
        options.frame = .iphone
        options.sizeOverride = PixelSize(1290, 2796)
        let alternate = try ScreenshotRenderer.pngData(image: source, options: options)
        XCTAssertEqual(ScreenshotPreflight.pngPixelSize(alternate), PixelSize(1290, 2796))

        // An unaccepted size cannot be smuggled through the variant door: it falls back to
        // the preset's own size rather than producing something the store will refuse.
        options.sizeOverride = PixelSize(999, 999)
        let fallback = try ScreenshotRenderer.pngData(image: source, options: options)
        XCTAssertEqual(ScreenshotPreflight.pngPixelSize(fallback), preset.pixelSize)
        XCTAssertTrue(preset.accepts(PixelSize(1260, 2736)))
        XCTAssertFalse(preset.accepts(PixelSize(999, 999)))
    }

    // MARK: - Screenshot Studio: frames

    func testFrameStylesRenderDistinctPixelsAtEveryAspectRatio() throws {
        // The direct regression test for "device frames do not work - the Android frame is
        // shown even for iPhone screenshots". The old studio view round-tripped the frame
        // through the selected capture target, so the user's choice never survived to the
        // renderer and every export came out with the same silhouette.
        let sources = [
            testImage(width: 1080, height: 2400),   // 20:9
            testImage(width: 900, height: 1200),    // 4:3
        ]
        let preset = try XCTUnwrap(StorePresetCatalog.preset(id: "play.phone.portrait"))

        for source in sources {
            var rendered: [ScreenshotFrame: Data] = [:]
            for frame in ScreenshotFrame.allCases {
                var options = ScreenshotRenderOptions()
                options.target = .preset(preset)
                options.frame = frame
                options.canvas = .light
                options.paddingPercent = 6
                let data = try ScreenshotRenderer.pngData(image: source, options: options)
                XCTAssertEqual(ScreenshotPreflight.pngPixelSize(data), preset.pixelSize, frame.rawValue)
                rendered[frame] = data
            }

            let frames = ScreenshotFrame.allCases
            for lhs in frames.indices {
                for rhs in frames.indices where rhs > lhs {
                    XCTAssertNotEqual(
                        rendered[frames[lhs]],
                        rendered[frames[rhs]],
                        "the \(frames[lhs].rawValue) and \(frames[rhs].rawValue) frames render identical pixels"
                    )
                }
            }
        }

        // ...and nothing rewrites the choice on the way in. A cross-family frame is a
        // legitimate mockup, so it survives a Play preset and only warns.
        XCTAssertEqual(
            ScreenshotRenderOptions(target: .preset(preset), frame: .iphone).resolvedFrame,
            .iphone
        )
        // The one exception: a preset that allows exactly one frame overrides the choice,
        // because Play forbids a device frame on a Wear OS asset outright.
        guard let wear = StorePresetCatalog.preset(id: "play.wear") else { return XCTFail("missing play.wear") }
        XCTAssertEqual(ScreenshotRenderOptions(target: .preset(wear), frame: .iphone).resolvedFrame, .none)
        XCTAssertEqual(ScreenshotRenderOptions(target: .preset(wear), paddingPercent: 12).resolvedPaddingPercent, 0)
    }

    func testTheSameInputsRenderByteIdenticalPNGs() throws {
        // §7: no timestamps, no random ids, all geometry rounded in one place. A batch that
        // is re-run must overwrite its own output with the same bytes.
        let source = testImage(width: 540, height: 1200)
        var options = ScreenshotRenderOptions()
        options.target = .preset(StorePresetCatalog.defaultPreset)
        options.frame = .iphone
        options.canvas = .accent

        XCTAssertEqual(
            try ScreenshotRenderer.pngData(image: source, options: options),
            try ScreenshotRenderer.pngData(image: source, options: options)
        )
    }

    func testTheDynamicIslandIsDrawnAtRealDeviceProportionsWithTheSensorInsideIt() throws {
        // The contact sheet showed the island as a thin black bar: the spec's
        // "height = 0.075 × islandWidth" is a quarter of the real ratio. Measured off an
        // iPhone 16 Pro, a 402pt-wide display carries a 125 × 36.7pt island whose top edge
        // sits 11pt below the top of the display:
        //
        //   width  = 125 / 402   = 0.311 of the screen's short edge
        //   ratio  = 36.7 / 125  = 0.2936
        //   inset  = 11 / 402    = 0.027
        //
        // Everything below is derived from those three device figures and the screen rect
        // this suite already pins by hand at testFramedAndFramelessLayoutsMatchHandDerivedGeometry
        // - a 1080 × 2400 capture in apple.iphone69.portrait at 6% padding puts the screen at
        // (120, 234, 1080, 2400) inside a 1320 × 2868 canvas. Nothing here asks the renderer
        // what it drew; it is measured back off the exported pixels.
        //
        //   basis     = min(1080, 2400)        = 1080
        //   length    = 0.311 × 1080           = 335.88
        //   thickness = 0.294 × 335.88         = 98.75
        //   top inset = 0.027 × 1080           = 29.16, so the pill's top row is
        //               2868 - 234 - 2400 + 29.16 = 263.16 counting down from the canvas top
        //   centred horizontally on the screen: midX = 120 + 540 = 660
        //   sensor    = 0.38 × 98.75           = 37.5 across, centred 0.6 × 98.75 = 59.25
        //               in from the pill's right end -> midX 828 - 59.25 = 768.75
        let source = testImage(width: 1080, height: 2400)
        var options = ScreenshotRenderOptions()
        options.target = .preset(StorePresetCatalog.defaultPreset)
        options.frame = .iphone
        options.canvas = .light
        options.paddingPercent = 6
        let png = try ScreenshotRenderer.pngData(image: source, options: options)
        let pixels = try XCTUnwrap(PixelGrid(png: png))
        XCTAssertEqual(pixels.width, 1320)
        XCTAssertEqual(pixels.height, 2868)

        // Scan a band across the middle of the screen's top quarter. It has to clear the
        // hairline seam drawn around the display, and the seam is not just at the edges: the
        // screen corner radius is 0.135 × 1080 = 145.8, so at x = 160 the corner arc dips all
        // the way down to y ≈ 280. Starting at x = 380 is past the arc entirely, and starting
        // at y = 240 clears the straight top edge at y = 234.
        let band = PixelGrid.Region(minX: 380, minY: 240, maxX: 940, maxY: 470)
        // The pill and the sensor dot are the only dark things in that band. The teal capture
        // and the 0.47-white shell both carry far more green + blue than either.
        let island = try XCTUnwrap(pixels.boundingBox(in: band) { $0.g + $0.b < 120 })
        // ...and of those two, the sensor is the only one carrying any red: the pill is pure
        // black and the capture is systemTeal, which is exactly 0 red, so the pill's
        // antialiased rim cannot fake it either.
        let sensor = try XCTUnwrap(pixels.boundingBox(in: band) { $0.g + $0.b < 120 && $0.r > 6 })

        // A threshold scan reads the antialiased edge conservatively, so every measurement
        // below is allowed to come in up to 3px short of the ideal - never over.
        XCTAssertEqual(Double(island.width), 335.88, accuracy: 3, "island width")
        XCTAssertEqual(Double(island.height), 98.75, accuracy: 3, "island height")
        // The figure this test exists for. The pre-polish 0.075 would have produced 0.075
        // here, which is what made the island read as a bar rather than a pill.
        XCTAssertEqual(Double(island.height) / Double(island.width), 36.7 / 125.0, accuracy: 0.02)
        XCTAssertEqual(Double(island.midX), 660, accuracy: 3, "island is centred on the screen")
        XCTAssertEqual(Double(island.minY), 263.16, accuracy: 3, "island top inset")

        // The dot is 0.38 of the pill's height and sits wholly inside it - not filling it,
        // which is the other half of the same regression now that the pill is four times
        // taller than the old drawing assumed.
        XCTAssertEqual(Double(sensor.width), 37.5, accuracy: 4, "sensor diameter")
        XCTAssertEqual(Double(sensor.height), 37.5, accuracy: 4, "sensor is round")
        XCTAssertEqual(Double(sensor.midX), 768.75, accuracy: 4, "sensor sits in from the right cap")
        XCTAssertEqual(Double(sensor.midY), Double(island.midY), accuracy: 3, "sensor is vertically centred")
        // Containment, stated as clearance on all four sides so a dot that grew to fill the
        // pill or slid off its right cap fails here rather than passing on a bbox check.
        XCTAssertGreaterThanOrEqual(sensor.minX - island.minX, 4, "sensor escaped the pill on the left")
        XCTAssertGreaterThanOrEqual(island.maxX - sensor.maxX, 4, "sensor escaped the pill's right cap")
        XCTAssertGreaterThanOrEqual(sensor.minY - island.minY, 4, "sensor escaped the pill on top")
        XCTAssertGreaterThanOrEqual(island.maxY - sensor.maxY, 4, "sensor escaped the pill below")
    }

    // MARK: - Screenshot Studio: feature graphic

    func testTheFeatureGraphicAnchorsRightAndExportsWithoutTheSafeAreaGuide() throws {
        // §2.5. Hand-derived for a 1080 × 2400 capture in the 1024 × 500 canvas with the
        // Android phone frame:
        //   ratio      = 2400 / 1080                     = 2.22222
        //   unitBezel  = 0.032 × min(1, ratio)           = 0.032
        //   unitWidth  = 1.064      unitHeight = 2.28622
        //   width      = 0.82 × 500 / 2.28622            = 179.34, and the reserved strip
        //                460.8 / 1.064 = 433.08 does not bite -> screen 179 wide
        //   screen h   = round(179 × 20/9)               = 398
        //   bezel      = max(2, round(0.032 × 179))      = 6
        //   box        = 191 × 410
        //   safe edge  = round(0.55 × 1024)              = 563
        //   anchor     = round(0.62 × 1024)              = 635, and 1024 - 191 = 833 does not
        //                pull it back, so the box starts at 635
        //   box y      = round((500 - 410) / 2)          = 45
        let preset = try XCTUnwrap(StorePresetCatalog.preset(id: "play.featureGraphic"))
        var options = ScreenshotRenderOptions()
        options.target = .preset(preset)
        options.frame = .androidPhone
        options.canvas = .dark
        options.paddingPercent = 6

        let plan = ScreenshotRenderer.layout(source: CGSize(width: 1080, height: 2400), options: options)
        XCTAssertEqual(plan.canvas, CGSize(width: 1024, height: 500))
        XCTAssertEqual(plan.boxRect, CGRect(x: 635, y: 45, width: 191, height: 410))
        XCTAssertEqual(plan.screenRect, CGRect(x: 641, y: 51, width: 179, height: 398))
        XCTAssertEqual(plan.bezel, 6)
        // Right of centre and clear of the reserved strip, which is the invariant; the 0.62
        // anchor is only the preference.
        XCTAssertGreaterThanOrEqual(plan.boxRect.minX, 563)
        // ...and clear of the outer 6% band Play crops on some homepages, so nothing drawn
        // here can be cut off.
        XCTAssertEqual(plan.cutoffEdges, [])
        XCTAssertNil(plan.cutoffWarning)
        // Padding is not a feature-graphic control: the composition is authored, so the 6%
        // above changes nothing about where the device lands.
        var unpadded = options
        unpadded.paddingPercent = 0
        XCTAssertEqual(ScreenshotRenderer.layout(source: CGSize(width: 1080, height: 2400), options: unpadded).boxRect, plan.boxRect)

        let source = testImage(width: 1080, height: 2400)
        let png = try ScreenshotRenderer.pngData(image: source, options: options)
        let exported = try XCTUnwrap(PixelGrid(png: png))
        XCTAssertEqual(exported.width, 1024)
        XCTAssertEqual(exported.height, 500)

        // The left 55% is reserved for the developer's own text and logo, so the tool draws
        // nothing into it - not the device, not its drop shadow, and above all not the guide.
        // Asserted on the ENCODED bytes because that is the artefact the guide must be absent
        // from; the guide is preview-only chrome and a "remember not to draw it on export"
        // rule is exactly the kind that survives one refactor.
        let reserved = PixelGrid.Region(minX: 0, minY: 0, maxX: 562, maxY: 499)
        let canvasPixel = exported.pixel(0, 0)
        XCTAssertNil(
            exported.firstPixel(in: reserved) { $0 != canvasPixel },
            "the exported feature graphic drew something into the reserved left 55%"
        )
        // Not vacuous: the device is on the canvas, just not in the reserved strip.
        XCTAssertNotNil(exported.firstPixel(in: PixelGrid.Region(minX: 563, minY: 0, maxX: 1023, maxY: 499)) {
            $0 != canvasPixel
        })

        // And the guide really is drawn - in the preview, into the very region the export
        // just came back clean on. Without this the assertion above would also pass on a
        // build that had simply lost the guide altogether.
        let preview = try ScreenshotRenderer.renderedImage(image: source, options: options, chrome: .safeAreaGuide)
        let previewPixels = try XCTUnwrap(PixelGrid(rep: try XCTUnwrap(preview.representations.first as? NSBitmapImageRep)))
        let previewCanvas = previewPixels.pixel(512, 0)
        XCTAssertNotNil(
            previewPixels.firstPixel(in: reserved) { $0 != previewCanvas },
            "the preview drew no safe-area guide, so the export assertion above proves nothing"
        )
        // ...and the export path cannot ask for it: `render` and `pngData` pass `.none` as a
        // literal, so the only chrome-bearing entry point is the preview's.
        let plainPreview = try ScreenshotRenderer.renderedImage(image: source, options: options, chrome: .none)
        let plainPixels = try XCTUnwrap(PixelGrid(rep: try XCTUnwrap(plainPreview.representations.first as? NSBitmapImageRep)))
        XCTAssertNil(plainPixels.firstPixel(in: reserved) { $0 != plainPixels.pixel(0, 0) })
    }

    // MARK: - Screenshot Studio: the studio's own option plumbing

    func testABatchWearJobKeepsItsLockedFitWhateverPresetIsActive() throws {
        // The leak: the batch used to copy the live options and reassign the target, so a
        // Wear job inherited whatever fit the ACTIVE preset had. `fit` is the one locked
        // option the renderer reads straight off the options - `resolvedFrame` and
        // `resolvedPaddingPercent` are derived inside the renderer, `fit` is not - so a
        // fitPad carried in from an iPhone row letterboxed the watch interface onto canvas
        // colour and reported as succeeded.
        let wear = try XCTUnwrap(StorePresetCatalog.preset(id: "play.wear"))
        let iphone = StorePresetCatalog.defaultPreset

        // The UI is sitting on the iPhone row with everything set the way that row wants it,
        // and the batch has a Wear preset ticked. This is the call the batch actually makes.
        let job = StudioRenderOptions.make(
            frame: .iphone,
            target: .preset(wear),
            canvas: .accent,
            paddingPercent: 6,
            fit: .fitPad,
            // The size variant belongs to the iPhone row; Wear must not honour it either.
            sizeOverride: PixelSize(1290, 2796)
        )
        XCTAssertEqual(job.fit, .fillCrop, "the Wear preset's locked fit lost to the active preset's")
        XCTAssertEqual(job.frame, .none)
        XCTAssertEqual(job.paddingPercent, 0)
        XCTAssertEqual(job.resolvedFit, .fillCrop)
        // A preset that permits a background keeps the user's fit, so the lock is Wear's and
        // not a blanket override.
        XCTAssertEqual(
            StudioRenderOptions.make(
                frame: .iphone,
                target: .preset(iphone),
                canvas: .accent,
                paddingPercent: 6,
                fit: .fillCrop,
                sizeOverride: nil
            ).fit,
            .fillCrop
        )

        // Geometry, hand-derived, for a 1080 × 2400 capture into the 384 × 384 Wear canvas:
        //   fillCrop: scale = max(384/1080, 384/2400) = 0.35556, so the visible source is
        //             1080 × round(384/0.35556) = 1080 × 1080 centred at y = 660, drawn over
        //             the whole canvas - interface only, no added background anywhere.
        //   fitPad:   scale = min(...) = 0.16 -> round(172.8) = 173 × 384 centred at
        //             x = round((384 - 173)/2) = 106, leaving 105.5px of canvas colour on
        //             each side. That is the rejectable asset.
        let locked = ScreenshotRenderer.layout(source: CGSize(width: 1080, height: 2400), options: job)
        XCTAssertEqual(locked.canvas, CGSize(width: 384, height: 384))
        XCTAssertEqual(locked.screenRect, CGRect(x: 0, y: 0, width: 384, height: 384))
        XCTAssertEqual(locked.sourceRect, CGRect(x: 0, y: 660, width: 1080, height: 1080))
        XCTAssertEqual(locked.horizontalBar, 0)
        XCTAssertEqual(locked.verticalBar, 0)

        // The old behaviour, constructed: options built by hand with the Wear target but the
        // iPhone row's fit still on them - which is precisely what copying the live options
        // produced, and which the renderer alone does not correct.
        var leaked = ScreenshotRenderOptions()
        leaked.target = .preset(wear)
        leaked.frame = .iphone
        leaked.canvas = .accent
        leaked.paddingPercent = 6
        leaked.fit = .fitPad
        let bars = ScreenshotRenderer.layout(source: CGSize(width: 1080, height: 2400), options: leaked)
        XCTAssertEqual(bars.screenRect, CGRect(x: 106, y: 0, width: 173, height: 384))
        XCTAssertEqual(bars.horizontalBar, 105.5)
        // So the two are distinguishable, and `make` is the thing that closes the gap: the
        // renderer would happily draw the leaked layout.
        XCTAssertNotEqual(bars.screenRect, locked.screenRect)

        // On the exported bytes: with the lock the interface reaches all four corners, and
        // without it the corners are canvas colour.
        let source = testImage(width: 1080, height: 2400)
        let lockedPixels = try XCTUnwrap(PixelGrid(png: try ScreenshotRenderer.pngData(image: source, options: job)))
        XCTAssertEqual(lockedPixels.width, 384)
        XCTAssertEqual(lockedPixels.height, 384)
        let interior = lockedPixels.pixel(192, 192)
        for corner in [(0, 0), (383, 0), (0, 383), (383, 383)] {
            XCTAssertEqual(lockedPixels.pixel(corner.0, corner.1), interior, "corner \(corner) is not the interface")
        }
        let leakedPixels = try XCTUnwrap(PixelGrid(png: try ScreenshotRenderer.pngData(image: source, options: leaked)))
        XCTAssertNotEqual(leakedPixels.pixel(0, 192), interior, "the leaked options drew no band to regress against")
    }

    func testAMixedQueueRendersEachShotInItsOwnFrameAndNeverOverwritesAChoice() throws {
        // Per-shot frames. The queue's two shots carry identical pixels and differ only in
        // the platform they were captured from, so anything that reaches the export other
        // than the shot's own frame shows up as two identical files.
        //
        // `ScreenshotStudioView.seedFrame(of:)` is private to the view and unreachable from
        // here; what is pinned is the pair the fix is built out of - `UserChoice`'s two
        // writers, and the batch's own options call taking the frame per shot.
        let image = testImage(width: 1080, height: 2400)
        var queue = [
            StudioShot(image: image, label: "iPhone 16 Pro", platform: .ios, pixelSize: PixelSize(1080, 2400)),
            StudioShot(image: image, label: "Pixel 9", platform: .android, pixelSize: PixelSize(1080, 2400)),
        ]
        for index in queue.indices {
            let shot = queue[index]
            queue[index].frame.seed(
                ScreenshotCaptureService.suggestedFrame(for: shot.platform!, sourceSize: shot.pixelSize?.cgSize)
            )
        }
        XCTAssertEqual(queue.map(\.frame.value), [.iphone, .androidPhone])
        XCTAssertFalse(queue.contains { $0.frame.isUserChosen })

        // One batch preset, two shots, two silhouettes.
        let preset = StorePresetCatalog.defaultPreset
        func render(_ shot: StudioShot) throws -> Data {
            try ScreenshotRenderer.pngData(image: shot.image, options: StudioRenderOptions.make(
                frame: shot.frame.value,
                target: .preset(preset),
                canvas: .light,
                paddingPercent: 6,
                fit: preset.defaultFit,
                sizeOverride: nil
            ))
        }
        let first = try render(queue[0])
        let second = try render(queue[1])
        XCTAssertNotEqual(first, second, "both queued shots exported in the same frame")

        // A user choice on one shot reaches that shot and no other...
        queue[0].frame.choose(.ipad)
        XCTAssertEqual(queue.map(\.frame.value), [.ipad, .androidPhone])
        XCTAssertNotEqual(try render(queue[0]), first)
        XCTAssertEqual(try render(queue[1]), second)

        // ...and survives the next capture, which seeds only the shot it appends.
        var arrival = StudioShot(image: image, label: "Galaxy S24", platform: .android, pixelSize: PixelSize(1080, 2400))
        arrival.frame.seed(ScreenshotCaptureService.suggestedFrame(for: .android, sourceSize: CGSize(width: 1080, height: 2400)))
        queue.append(arrival)
        XCTAssertEqual(queue.map(\.frame.value), [.ipad, .androidPhone, .androidPhone])
        XCTAssertTrue(queue[0].frame.isUserChosen)
        // The seed door itself refuses, which is the guarantee rather than the call order.
        XCTAssertFalse(queue[0].frame.seed(.androidPhone))
        XCTAssertEqual(queue[0].frame.value, .ipad)

        // Re-asserting the frame already selected is a deliberate act and must lock it too:
        // a SwiftUI Picker does not call its binding's setter for a re-selection, which is
        // how "the frame I picked came back as Android" happened in the first place.
        var reasserted = UserChoice<ScreenshotFrame>(.iphone)
        XCTAssertTrue(reasserted.seed(.androidPhone))
        XCTAssertEqual(reasserted.value, .androidPhone)
        reasserted.choose(.androidPhone)
        XCTAssertTrue(reasserted.isUserChosen)
        XCTAssertFalse(reasserted.seed(.iphone))
        XCTAssertEqual(reasserted.value, .androidPhone)
    }

    // MARK: - Screenshot Studio: alpha

    func testAlphaSurvivesOnlyInFreeModeAndIsRejectedOnTheEncodedBytes() throws {
        let source = testImage(width: 540, height: 1200)
        let preset = StorePresetCatalog.defaultPreset

        // Transparent is unrepresentable with a preset: the option resolves to Light before
        // a pixel is drawn, so the belt (the UI switch) and the braces (this) agree.
        var transparentPreset = ScreenshotRenderOptions()
        transparentPreset.target = .preset(preset)
        transparentPreset.frame = .iphone
        transparentPreset.canvas = .transparent
        XCTAssertEqual(transparentPreset.resolvedCanvas, .light)
        XCTAssertFalse(transparentPreset.preservesAlpha)
        let opaque = try ScreenshotRenderer.pngData(image: source, options: transparentPreset)
        XCTAssertEqual(ScreenshotPreflight.pngColourType(opaque), 2)
        XCTAssertNoThrow(try ScreenshotPreflight.assertNoAlpha(opaque))

        // Free mode is the one place the channel is meaningful - and the one place the
        // validator has something real to reject, which is what proves it has teeth.
        var free = ScreenshotRenderOptions()
        free.frame = .iphone
        free.canvas = .transparent
        XCTAssertTrue(free.preservesAlpha)
        let withAlpha = try ScreenshotRenderer.pngData(image: source, options: free)
        XCTAssertEqual(ScreenshotPreflight.pngColourType(withAlpha), 6)
        XCTAssertThrowsError(try ScreenshotPreflight.assertNoAlpha(withAlpha)) { error in
            guard case .alphaChannelPresent(let colourType) = error as? ScreenshotPreflightError else {
                return XCTFail("expected an alpha rejection, got \(error)")
            }
            XCTAssertEqual(colourType, 6)
        }
        XCTAssertThrowsError(try ScreenshotRenderer.assertNoAlpha(withAlpha))

        // An opaque canvas in Free mode still flattens: there is no reason to ship a channel
        // nobody asked for.
        free.canvas = .dark
        XCTAssertEqual(ScreenshotPreflight.pngColourType(try ScreenshotRenderer.pngData(image: source, options: free)), 2)

        // Not a PNG at all is a failure, not a pass.
        XCTAssertNil(ScreenshotPreflight.pngColourType(Data("not a png".utf8)))
        XCTAssertThrowsError(try ScreenshotPreflight.assertNoAlpha(Data("not a png".utf8)))
    }

    // MARK: - Screenshot Studio: preflight

    func testEveryPreflightCheckFiresOnlyWhenItShould() {
        // One row per finding id: an input that must produce it, and one that must not.
        // Twelve checks, fourteen ids, and exactly three checks that can stop an export.
        let cases: [PreflightCase] = [
            // 1 — alpha where forbidden.
            PreflightCase(
                check: 1,
                id: "alpha.transparent-canvas",
                severity: .block,
                fires: preflightInput("play.phone.portrait", frame: .androidPhone, transparent: true),
                quiet: preflightInput("play.phone.portrait", frame: .androidPhone)
            ),
            PreflightCase(
                check: 1,
                id: "alpha.png-colour-type",
                severity: .block,
                fires: preflightInput("play.phone.portrait", frame: .androidPhone, colourType: 6),
                quiet: preflightInput("play.phone.portrait", frame: .androidPhone, colourType: 2)
            ),
            PreflightCase(
                check: 1,
                id: "alpha.free-mode",
                severity: .info,
                fires: preflightInput(nil, transparent: true),
                quiet: preflightInput(nil)
            ),
            // 2 — upscaling past native.
            PreflightCase(
                check: 2,
                id: "scale.upscale",
                severity: .warn,
                fires: preflightInput(
                    "apple.ipad13.portrait",
                    source: PixelSize(750, 1334),
                    frame: .ipad,
                    layout: PreflightLayout(canvas: PixelSize(2064, 2752), screenWidth: 1036, screenHeight: 1843)
                ),
                quiet: preflightInput(
                    "apple.iphone69.portrait",
                    source: PixelSize(1080, 2400),
                    frame: .iphone,
                    layout: PreflightLayout(canvas: PixelSize(1320, 2868), screenWidth: 1080, screenHeight: 2400)
                )
            ),
            PreflightCase(
                check: 2,
                id: "scale.upscale-severe",
                severity: .warn,
                fires: preflightInput(
                    "apple.ipad13.portrait",
                    source: PixelSize(320, 640),
                    frame: .ipad,
                    layout: PreflightLayout(canvas: PixelSize(2064, 2752), screenWidth: 1036, screenHeight: 2072)
                ),
                // 1.38× is worth a warning but is not "visibly soft".
                quiet: preflightInput(
                    "apple.ipad13.portrait",
                    source: PixelSize(750, 1334),
                    frame: .ipad,
                    layout: PreflightLayout(canvas: PixelSize(2064, 2752), screenWidth: 1036, screenHeight: 1843)
                )
            ),
            // 3 — aspect mismatch. 20:9 into 9:16 is R = 1.25 and shows 108px per side.
            PreflightCase(
                check: 3,
                id: "aspect.mismatch",
                severity: .warn,
                fires: preflightInput(
                    "play.phone.portrait",
                    source: PixelSize(1080, 2400),
                    layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 864, screenHeight: 1920)
                ),
                quiet: preflightInput(
                    "play.phone.portrait",
                    source: PixelSize(1080, 1920),
                    layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 1080, screenHeight: 1920)
                )
            ),
            // 4 — orientation flip.
            PreflightCase(
                check: 4,
                id: "orientation.flip",
                severity: .warn,
                fires: preflightInput(
                    "play.phone.landscape",
                    source: PixelSize(1080, 2400),
                    layout: PreflightLayout(canvas: PixelSize(1920, 1080), screenWidth: 486, screenHeight: 1080)
                ),
                quiet: preflightInput(
                    "play.phone.portrait",
                    source: PixelSize(1080, 2400),
                    layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 864, screenHeight: 1920)
                )
            ),
            // 5 — crop loss.
            PreflightCase(
                check: 5,
                id: "crop.loss",
                severity: .warn,
                fires: preflightInput("play.phone.portrait", source: PixelSize(1080, 2400), fit: .fillCrop),
                quiet: preflightInput("play.phone.portrait", source: PixelSize(1080, 1920), fit: .fillCrop)
            ),
            // 6 — platform mismatch, cosmetic. Same-store, so check 7 stays quiet.
            PreflightCase(
                check: 6,
                id: "platform.frame-mismatch",
                severity: .info,
                fires: preflightInput("play.phone.portrait", platform: .android, frame: .iphone),
                quiet: preflightInput("play.phone.portrait", platform: .android, frame: .androidPhone)
            ),
            // 7 — platform mismatch, reviewable. Warns, never blocks: a mockup is legitimate.
            PreflightCase(
                check: 7,
                id: "platform.store-mismatch",
                severity: .warn,
                fires: preflightInput("apple.iphone69.portrait", platform: .android, frame: .iphone),
                quiet: preflightInput("apple.iphone69.portrait", platform: .ios, frame: .iphone)
            ),
            // 8 — Play dimension bounds. The 20:9 Pixel capture, chosen as an output size.
            PreflightCase(
                check: 8,
                id: "play.dimension-bounds",
                severity: .block,
                fires: preflightInput(
                    "play.phone.portrait",
                    source: PixelSize(1080, 2400),
                    frame: .androidPhone,
                    override: PixelSize(1080, 2400)
                ),
                quiet: preflightInput("play.phone.portrait", source: PixelSize(1080, 2400), frame: .androidPhone)
            ),
            // 9 — Play's large-screen rule is exactly 16:9 or 9:16, not "about".
            PreflightCase(
                check: 9,
                id: "play.large-screen-aspect",
                severity: .warn,
                fires: preflightInput(
                    "play.tablet.landscape.hd",
                    source: PixelSize(1920, 1200),
                    frame: .androidTablet,
                    override: PixelSize(1920, 1200)
                ),
                quiet: preflightInput("play.tablet.landscape.hd", source: PixelSize(1920, 1080), frame: .androidTablet)
            ),
            // 10 — counts, per size class per localization.
            PreflightCase(
                check: 10,
                id: "count.over-maximum",
                severity: .warn,
                fires: preflightInput(
                    "apple.iphone69.portrait",
                    frame: .iphone,
                    counts: ["apple.iphone69.portrait": 11]
                ),
                quiet: preflightInput(
                    "apple.iphone69.portrait",
                    frame: .iphone,
                    counts: ["apple.iphone69.portrait": 10]
                )
            ),
            PreflightCase(
                check: 10,
                id: "count.play-phone-minimum",
                severity: .warn,
                fires: preflightInput(
                    "play.phone.portrait",
                    frame: .androidPhone,
                    counts: ["play.phone.portrait": 1]
                ),
                quiet: preflightInput(
                    "play.phone.portrait",
                    frame: .androidPhone,
                    counts: ["play.phone.portrait": 2]
                )
            ),
            PreflightCase(
                check: 10,
                id: "count.large-screen-minimum",
                severity: .warn,
                fires: preflightInput(
                    "play.tablet.landscape.hd",
                    source: PixelSize(1920, 1080),
                    frame: .androidTablet,
                    counts: ["play.tablet.landscape.hd": 3]
                ),
                quiet: preflightInput(
                    "play.tablet.landscape.hd",
                    source: PixelSize(1920, 1080),
                    frame: .androidTablet,
                    counts: ["play.tablet.landscape.hd": 4]
                )
            ),
            // 11 — Wear OS forbids frames, backgrounds and masking.
            PreflightCase(
                check: 11,
                id: "wear.frame-forbidden",
                severity: .block,
                fires: preflightInput("play.wear", source: PixelSize(1000, 1000), frame: .androidPhone, padding: 0),
                quiet: preflightInput("play.wear", source: PixelSize(1000, 1000), padding: 0)
            ),
            PreflightCase(
                check: 11,
                id: "wear.padding-forbidden",
                severity: .block,
                fires: preflightInput("play.wear", source: PixelSize(1000, 1000), padding: 6),
                quiet: preflightInput("play.wear", source: PixelSize(1000, 1000), padding: 0)
            ),
            // 12 — non-8-bit / non-RGB source.
            PreflightCase(
                check: 12,
                id: "source.colour-conversion",
                severity: .info,
                fires: preflightInput("play.phone.portrait", bitsPerSample: 16, frame: .androidPhone),
                quiet: preflightInput("play.phone.portrait", frame: .androidPhone)
            ),
        ]

        for testCase in cases {
            let label = "check \(testCase.check) · \(testCase.id)"
            let fired = ScreenshotPreflight.evaluate(testCase.fires)
            guard let finding = fired.findings.first(where: { $0.id == testCase.id }) else {
                XCTFail("\(label) did not fire; got \(fired.findings.map(\.id))")
                continue
            }
            XCTAssertEqual(finding.severity, testCase.severity, label)
            XCTAssertFalse(finding.title.isEmpty, label)
            XCTAssertFalse(finding.detail.isEmpty, label)
            // Only a blocking finding may disable the export button, and it must be able to
            // say why in one line.
            XCTAssertEqual(fired.isBlocked, testCase.severity == .block, label)
            if testCase.severity == .block {
                XCTAssertNotNil(fired.blockingReason, label)
            }

            let silent = ScreenshotPreflight.evaluate(testCase.quiet)
            XCTAssertFalse(
                silent.findings.contains { $0.id == testCase.id },
                "\(label) fired on an input that should not trigger it"
            )
        }

        // All twelve checks are covered...
        XCTAssertEqual(Set(cases.map(\.check)), Set(1...12))
        // ...and only checks 1, 8 and 11 can stop an export. Everything else exports on
        // confirmation: the job is to make the consequence visible, not to be right about
        // the user's intent.
        XCTAssertEqual(Set(cases.filter { $0.severity == .block }.map(\.check)), [1, 8, 11])
        XCTAssertEqual(
            Set(cases.filter { $0.severity == .block }.map(\.id)),
            [
                "alpha.transparent-canvas",
                "alpha.png-colour-type",
                "play.dimension-bounds",
                "wear.frame-forbidden",
                "wear.padding-forbidden",
            ]
        )
    }

    func testPreflightGradesTheAspectMismatchAndDrivesThePreviewOverlays() {
        // §2.6's bands, plus the three preview switches the report drives.

        // R = 1.125 with 11% of the width in bars: a genuine near-miss stays quiet.
        let near = ScreenshotPreflight.evaluate(preflightInput(
            "play.phone.portrait",
            source: PixelSize(1080, 2160),
            layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 960, screenHeight: 1920)
        ))
        XCTAssertEqual(near.findings.first { $0.id == "aspect.mismatch" }?.severity, .info)
        XCTAssertFalse(near.highlightsPadBars)

        // R = 1.25, the 20:9 Pixel capture this tool exists to catch, escalates to a warning
        // even though §2.6's numeric band would call it info - §2.6 and §5 both use this very
        // case as their worked .warn example.
        let pixel = ScreenshotPreflight.evaluate(preflightInput(
            "play.phone.portrait",
            source: PixelSize(1080, 2400),
            layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 864, screenHeight: 1920)
        ))
        let mismatch = pixel.findings.first { $0.id == "aspect.mismatch" }
        XCTAssertEqual(mismatch?.severity, .warn)
        XCTAssertEqual(mismatch?.fix, .useFit(.fillCrop))
        XCTAssertTrue(mismatch?.detail.contains("108px") == true, mismatch?.detail ?? "")
        XCTAssertFalse(pixel.highlightsPadBars)

        // R = 1.8 hatches the bars in the preview.
        let extreme = ScreenshotPreflight.evaluate(preflightInput(
            "play.phone.portrait",
            source: PixelSize(1000, 3200),
            layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 600, screenHeight: 1920)
        ))
        XCTAssertEqual(extreme.findings.first { $0.id == "aspect.mismatch" }?.severity, .warn)
        XCTAssertTrue(extreme.highlightsPadBars)

        // Losing more than 30% overlays the crop rect on the full source.
        let heavyCrop = ScreenshotPreflight.evaluate(
            preflightInput("play.phone.portrait", source: PixelSize(1080, 3200), fit: .fillCrop)
        )
        XCTAssertTrue(heavyCrop.highlightsCropRect)
        let lightCrop = ScreenshotPreflight.evaluate(
            preflightInput("play.phone.portrait", source: PixelSize(1080, 2400), fit: .fillCrop)
        )
        XCTAssertTrue(lightCrop.findings.contains { $0.id == "crop.loss" })
        XCTAssertFalse(lightCrop.highlightsCropRect)

        // An orientation flip pins the fit policy: a capture is never auto-cropped across one.
        let flipped = ScreenshotPreflight.evaluate(preflightInput(
            "play.phone.landscape",
            source: PixelSize(1080, 2400),
            fit: .fillCrop,
            layout: PreflightLayout(canvas: PixelSize(1920, 1080), screenWidth: 486, screenHeight: 1080)
        ))
        XCTAssertTrue(flipped.forcesFitPad)
        XCTAssertFalse(flipped.findings.contains { $0.id == "crop.loss" })

        // A framed export has no fit policy at all: the aspect is preserved exactly inside the
        // frame's screen rect and the canvas absorbs 100% of the mismatch, so nothing to warn
        // about is left.
        let framed = ScreenshotPreflight.evaluate(preflightInput(
            "play.phone.portrait",
            source: PixelSize(1080, 2400),
            frame: .androidPhone,
            layout: PreflightLayout(canvas: PixelSize(1080, 1920), screenWidth: 783, screenHeight: 1740)
        ))
        XCTAssertFalse(framed.findings.contains { $0.id == "aspect.mismatch" })
        XCTAssertFalse(framed.findings.contains { $0.id == "crop.loss" })
    }

    func testPreflightWarnsAboutACrossStoreCaptureWithoutBlockingIt() {
        // Check 7 replaces the old hard block. `platformMismatch` used to disable Export
        // outright whenever the frame did not match the capture's platform, which is half of
        // why frame selection appeared broken.
        let report = ScreenshotPreflight.evaluate(
            preflightInput("apple.iphone69.portrait", platform: .android, frame: .iphone)
        )
        let finding = report.findings.first { $0.id == "platform.store-mismatch" }
        XCTAssertEqual(finding?.severity, .warn)
        XCTAssertEqual(finding?.fix, .recaptureOn(.ios))
        XCTAssertTrue(finding?.detail.contains("2.3.3") == true)
        XCTAssertFalse(report.isBlocked)
        XCTAssertNil(report.blockingReason)

        // ...and the same in reverse.
        let reversed = ScreenshotPreflight.evaluate(
            preflightInput("play.phone.portrait", platform: .ios, frame: .androidPhone)
        )
        XCTAssertEqual(reversed.findings.first { $0.id == "platform.store-mismatch" }?.fix, .recaptureOn(.android))
        XCTAssertFalse(reversed.isBlocked)
    }

    func testPreflightOffersTheNearestLegalSizeForAPixelCapture() {
        let report = ScreenshotPreflight.evaluate(preflightInput(
            "play.phone.portrait",
            source: PixelSize(1080, 2400),
            frame: .androidPhone,
            override: PixelSize(1080, 2400)
        ))
        let finding = report.findings.first { $0.id == "play.dimension-bounds" }
        XCTAssertEqual(finding?.severity, .block)
        XCTAssertEqual(finding?.fix, .useOutputSize(PixelSize(1200, 2400)))
        XCTAssertTrue(finding?.detail.contains("20:9") == true, finding?.detail ?? "")
        XCTAssertTrue(report.isBlocked)
        XCTAssertEqual(report.outputSize, PixelSize(1080, 2400))
        // Severest first, so the thing that stops the export is what the user reads.
        XCTAssertEqual(report.highestSeverity, .block)
    }

    func testTabletPortraitDefaultsToASizeThatClearsPlaysOwnLargeScreenRule() throws {
        // The tool used to warn on its own default: play.tablet.portrait shipped at
        // 1600 × 2560, which is 8:5, and check 9 wants exactly 16:9 or 9:16 - so every single
        // use of the row fired a warning the user could do nothing about. 1440 × 2560 is
        // exactly 9:16 (1440 × 16 = 2560 × 9 = 23040) and is the size the row now defaults to.
        let preset = try XCTUnwrap(StorePresetCatalog.preset(id: "play.tablet.portrait"))
        XCTAssertEqual(preset.pixelSize, PixelSize(1440, 2560))
        XCTAssertEqual(preset.pixelSize.width * 16, preset.pixelSize.height * 9)
        // Still within Play's universal validator, and still portrait.
        XCTAssertTrue(PlayImageRules.isValid(preset.pixelSize))
        XCTAssertEqual(preset.orientation, .portrait)

        let quiet = ScreenshotPreflight.evaluate(preflightInput(
            "play.tablet.portrait",
            source: PixelSize(1600, 2560),
            frame: .androidTablet
        ))
        XCTAssertFalse(
            quiet.findings.contains { $0.id == "play.large-screen-aspect" },
            "the row's own default still trips the tool's large-screen check"
        )

        // The 8:5 size survives as an alternate - Play accepts the upload, it just does not
        // qualify for large-screen placement - and choosing it is exactly when the check
        // should speak up.
        XCTAssertEqual(preset.alternates, [PixelSize(1600, 2560)])
        XCTAssertTrue(preset.accepts(PixelSize(1600, 2560)))
        let alternate = ScreenshotPreflight.evaluate(preflightInput(
            "play.tablet.portrait",
            source: PixelSize(1600, 2560),
            frame: .androidTablet,
            override: PixelSize(1600, 2560)
        ))
        let finding = alternate.findings.first { $0.id == "play.large-screen-aspect" }
        XCTAssertEqual(finding?.severity, .warn)
        XCTAssertTrue(finding?.detail.contains("8:5") == true, finding?.detail ?? "")
        XCTAssertFalse(alternate.isBlocked)

        // Every other recommended large-screen row is 16:9 or 9:16 on its default too, so no
        // row in the group warns about itself.
        for row in StorePresetCatalog.recommended {
            let report = ScreenshotPreflight.evaluate(preflightInput(
                row.id,
                source: row.pixelSize,
                frame: .androidTablet
            ))
            XCTAssertFalse(
                report.findings.contains { $0.id == "play.large-screen-aspect" },
                "\(row.id) warns about its own default size"
            )
        }
    }


    private struct PreflightCase {
        let check: Int
        let id: String
        let severity: PreflightSeverity
        let fires: PreflightInput
        let quiet: PreflightInput
    }

    private func preflightInput(
        _ presetID: String?,
        source: PixelSize = PixelSize(1080, 1920),
        bitsPerSample: Int = 8,
        colourModel: SourceColourModel = .rgb,
        platform: PlatformKind? = nil,
        frame: ScreenshotFrame = .none,
        fit: FitPolicy = .fitPad,
        transparent: Bool = false,
        padding: Double = 6,
        override: PixelSize? = nil,
        layout: PreflightLayout? = nil,
        counts: [String: Int] = [:],
        colourType: Int? = nil
    ) -> PreflightInput {
        PreflightInput(
            target: exportTarget(presetID),
            source: SourceImageFacts(
                size: source,
                bitsPerSample: bitsPerSample,
                colourModel: colourModel,
                platform: platform
            ),
            options: PreflightOptions(
                frame: frame,
                fit: fit,
                canvasIsTransparent: transparent,
                paddingPercent: padding,
                outputSizeOverride: override
            ),
            layout: layout,
            queuedCountsByPresetID: counts,
            encodedColourType: colourType
        )
    }

    private func exportTarget(_ presetID: String?) -> ExportTarget {
        guard let presetID else { return .free }
        guard let preset = StorePresetCatalog.preset(id: presetID) else {
            XCTFail("unknown preset id \(presetID)")
            return .free
        }
        return .preset(preset)
    }

    private func options(
        preset presetID: String,
        frame: ScreenshotFrame,
        fit: FitPolicy = .fitPad,
        padding: CGFloat = 6
    ) -> ScreenshotRenderOptions {
        var options = ScreenshotRenderOptions()
        options.target = exportTarget(presetID)
        options.frame = frame
        options.fit = fit
        options.paddingPercent = padding
        return options
    }

    func testPreviewHandsBackTheRenderedBitmapInsteadOfAPNGRoundTrip() throws {
        // Regression: renderedImage() PNG-encoded the ~26 MB bitmap and immediately
        // decoded it again, on the main actor, on every padding-slider tick. The
        // round trip is observable as well as slow: PNG stores un-premultiplied
        // alpha, so re-premultiplying on decode perturbs the frame's drop shadow.
        let source = testImage(width: 96, height: 192)
        let options = ScreenshotRenderOptions(frame: .iphone, canvas: .transparent, paddingPercent: 8)

        let direct = try ScreenshotRenderer.render(image: source, options: options)
        let preview = try ScreenshotRenderer.renderedImage(image: source, options: options)
        let previewRep = try XCTUnwrap(preview.representations.first as? NSBitmapImageRep)

        XCTAssertEqual(previewRep.pixelsWide, direct.pixelsWide)
        XCTAssertEqual(previewRep.pixelsHigh, direct.pixelsHigh)
        // The preview NSImage is sized in the renderer's own pixels, which is what
        // NSImage(data:) used to derive from the PNG's 72-dpi header.
        XCTAssertEqual(preview.size, CGSize(width: direct.pixelsWide, height: direct.pixelsHigh))
        XCTAssertEqual(
            previewRep.tiffRepresentation,
            direct.tiffRepresentation,
            "the preview must be the rendered bitmap, not a re-decoded copy of it"
        )

        // ...and the export still encodes exactly what the preview showed.
        XCTAssertEqual(
            try ScreenshotRenderer.pngData(image: source, options: options),
            direct.representation(using: .png, properties: [:])
        )
    }

    func testLimitedPreviewKeepsExportGeometryAndFullResolution() throws {
        let source = testImage(width: 1080, height: 2400)
        let options = ScreenshotRenderOptions(
            target: .preset(StorePresetCatalog.defaultPreset), frame: .iphone, canvas: .light
        )
        let full = try ScreenshotRenderer.render(image: source, options: options)
        let preview = try ScreenshotRenderer.renderedImage(image: source, options: options, maxPixelDimension: 800)
        let small = try XCTUnwrap(preview.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(max(small.pixelsWide, small.pixelsHigh), 800)
        XCTAssertLessThan(small.bytesPerRow * small.pixelsHigh, full.bytesPerRow * full.pixelsHigh / 8)

        // Measure the neutral device shell independently of the layout implementation.
        let largePixels = try XCTUnwrap(PixelGrid(rep: full))
        let smallPixels = try XCTUnwrap(PixelGrid(rep: small))
        func shell(_ grid: PixelGrid) throws -> PixelGrid.Box {
            try XCTUnwrap(grid.boundingBox(in: .init(minX: 0, minY: 0, maxX: grid.width - 1, maxY: grid.height - 1)) {
                $0.r < 170 && abs($0.r - $0.g) < 6 && abs($0.g - $0.b) < 6
            })
        }
        let largeBox = try shell(largePixels)
        let smallBox = try shell(smallPixels)
        let scale = Double(small.pixelsHigh) / Double(full.pixelsHigh)
        XCTAssertEqual(Double(smallBox.width), Double(largeBox.width) * scale, accuracy: 2)
        XCTAssertEqual(Double(smallBox.height), Double(largeBox.height) * scale, accuracy: 2)
        XCTAssertEqual(smallBox.midX, largeBox.midX * scale, accuracy: 2)
        XCTAssertEqual(smallBox.midY, largeBox.midY * scale, accuracy: 2)
        // Sample outside the shell: preview scaling must scale its shadow too.
        for distance in [4, 8, 12] {
            let x = Int(smallBox.midX)
            let y = smallBox.maxY + distance
            let reference = largePixels.pixel(Int(Double(x) / scale), Int(Double(y) / scale))
            let actual = smallPixels.pixel(x, y)
            XCTAssertEqual(actual.r, reference.r, accuracy: 6, "shadow at \(distance)px")
        }
        let png = try ScreenshotRenderer.pngData(image: source, options: options)
        XCTAssertEqual(ScreenshotPreflight.pngPixelSize(png), StorePresetCatalog.defaultPreset.pixelSize)
        XCTAssertEqual(ScreenshotRenderer.sourcePixelSize(source), CGSize(width: 1080, height: 2400))
    }

    func testLimitedPreviewHandlesLandscapeAndDoesNotEnlargeSmallImages() throws {
        let options = ScreenshotRenderOptions(frame: .none, canvas: .light, paddingPercent: 0)
        for (width, height, expected) in [(1200, 600, CGSize(width: 400, height: 200)),
                                           (100, 200, CGSize(width: 100, height: 200))] {
            let source = testImage(width: width, height: height)
            let preview = try ScreenshotRenderer.renderedImage(image: source, options: options, maxPixelDimension: 400)
            XCTAssertEqual(ScreenshotRenderer.sourcePixelSize(preview), expected)
            let grid = try XCTUnwrap(PixelGrid(rep: try XCTUnwrap(preview.representations.first as? NSBitmapImageRep)))
            XCTAssertEqual(grid.pixel(4, 4), grid.pixel(grid.width - 5, grid.height - 5))
            XCTAssertGreaterThan(grid.pixel(grid.width / 2, grid.height / 2).g, 60)
        }
    }

    func testExportProtectsImportedSourcesIncludingSymlinkAndCaseAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Original.png")
        let source = testImage(width: 64, height: 128)
        let bytes = try XCTUnwrap(source.tiffRepresentation)
        try bytes.write(to: sourceURL)
        let link = directory.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceURL)
        let options = ScreenshotRenderOptions(frame: .iphone)
        var destinations = [sourceURL, link]
        let alternateCase = directory.appendingPathComponent("original.png")
        if FileManager.default.fileExists(atPath: alternateCase.path) { destinations.append(alternateCase) }
        for destination in destinations {
            let outcome = ScreenshotExportJob(image: source, options: options, destination: destination, protectedSources: [sourceURL]).write()
            XCTAssertFalse(outcome.succeeded)
            XCTAssertTrue(outcome.message?.contains("source image") == true)
            XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        }
        let export = directory.appendingPathComponent("export.png")
        XCTAssertTrue(ScreenshotExportJob(image: source, options: options, destination: export, protectedSources: [sourceURL]).write().succeeded)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        XCTAssertNotNil(ScreenshotPreflight.pngPixelSize(try Data(contentsOf: export)))
    }

    func testBackgroundExportPreservesRetinaPixelsAndImageOrientation() async throws {
        let image = testImage(width: 120, height: 240)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSColor.red.setFill()
        CGRect(x: 0, y: 0, width: 60, height: 120).fill()
        NSGraphicsContext.restoreGraphicsState()
        image.size = CGSize(width: 60, height: 120)
        let options = ScreenshotRenderOptions(frame: .iphone, canvas: .transparent)
        let expected = try ScreenshotRenderer.pngData(image: image, options: options)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let job = ScreenshotExportJob(image: image, options: options, destination: destination, protectedSources: [])
        let outcome = await Task.detached { autoreleasepool { job.write() } }.value
        XCTAssertTrue(outcome.succeeded, outcome.message ?? "")
        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    func testBackgroundExportMatchesImportedJPEGHEICAndPNG() async throws {
        let original = testImage(width: 120, height: 240)
        let bitmap = try XCTUnwrap(original.representations.first as? NSBitmapImageRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.red.setFill()
        CGRect(x: 0, y: 0, width: 60, height: 120).fill()
        NSGraphicsContext.restoreGraphicsState()
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: output) }
        let options = ScreenshotRenderOptions(frame: .none, canvas: .light)
        for format in ["public.jpeg", "public.heic", "public.png"] {
            for orientation in [1, 3, 6, 8] {
                let encoded = NSMutableData()
                let writer = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, format as CFString, 1, nil))
                CGImageDestinationAddImage(writer, cgImage, [kCGImagePropertyOrientation: orientation] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(writer))
                let imported = try XCTUnwrap(NSImage(data: encoded as Data))
                let expected = try ScreenshotRenderer.pngData(image: imported, options: options)
                let job = ScreenshotExportJob(image: imported, options: options, destination: output, protectedSources: [])
                let outcome = await Task.detached { autoreleasepool { job.write() } }.value
                XCTAssertTrue(outcome.succeeded, outcome.message ?? "")
                XCTAssertEqual(try Data(contentsOf: output), expected, "\(format), orientation \(orientation)")
            }
        }
    }

    func testExportJobKeepsItsSettingsAndBlockedJobsLeaveExistingFilesAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.png")
        let image = testImage(width: 64, height: 128)
        var liveOptions = ScreenshotRenderOptions(frame: .none, canvas: .light, paddingPercent: 0)
        let job = ScreenshotExportJob(image: image, options: liveOptions, destination: destination, protectedSources: [])
        liveOptions.frame = .iphone
        liveOptions.target = .preset(StorePresetCatalog.defaultPreset)
        XCTAssertTrue(job.write().succeeded)
        let exported = try Data(contentsOf: destination)
        XCTAssertEqual(ScreenshotPreflight.pngPixelSize(exported), PixelSize(64, 128))
        var blockedJob = job
        blockedJob.blockingReason = "Size class limit reached"
        XCTAssertEqual(blockedJob.write().message, "Size class limit reached")
        XCTAssertEqual(try Data(contentsOf: destination), exported)
    }

    func testNoFrameIgnoresPreviousSpacingAndPreservesSourcePixelDimensions() throws {
        let source = testImage(width: 240, height: 480)
        // Switching off a frame must also stop applying the disabled spacing control.
        let options = ScreenshotRenderOptions(frame: .none, canvas: .light, paddingPercent: 14)
        let output = try XCTUnwrap(NSBitmapImageRep(data: ScreenshotRenderer.pngData(image: source, options: options)))

        XCTAssertEqual(options.resolvedPaddingPercent, 0)
        XCTAssertEqual(output.pixelsWide, 240)
        XCTAssertEqual(output.pixelsHigh, 480)
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
        let client = FRKClient(executableURL: Self.realCLIURL())

        let capabilities = try await client.capabilities()
        let projects = try await client.projects()
        let credentials = try await client.credentials()

        XCTAssertEqual(capabilities.protocolVersion, 1)
        XCTAssertEqual(projects.protocolVersion, 1)
        XCTAssertEqual(credentials.protocolVersion, 1)
    }

    func testClientSavesLeadingDashBuildFlagsThroughTheRealCLI() async throws {
        let home = try XCTUnwrap(Self.sandboxHome)
        let project = home.appendingPathComponent("argument-roundtrip")
        let fastlane = project.appendingPathComponent("fastlane")
        try FileManager.default.createDirectory(at: fastlane, withIntermediateDirectories: true)
        let registry = home.appendingPathComponent("projects.json")
        let previousRegistry = try? Data(contentsOf: registry)
        defer {
            if let previousRegistry {
                try? previousRegistry.write(to: registry)
            } else {
                try? FileManager.default.removeItem(at: registry)
            }
            try? FileManager.default.removeItem(at: project)
        }
        try "name: argument-roundtrip\nplatforms: [android]\nandroid:\n  track: internal\n"
            .write(to: fastlane.appendingPathComponent("release_kit.yml"), atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "projects": [["name": "argument-roundtrip", "path": project.path, "platforms": ["android"]]]
        ])
        try data.write(to: registry)
        let client = FRKClient(executableURL: Self.realCLIURL())
        let flags = ["--dart-define=A=1", "--verbose", "--flavor", "demo", "--dart-define=NAME=با فاصله"]
        let saved = try await client.setBuildArgs("argument-roundtrip", platform: .android, args: flags)
        XCTAssertEqual(flags, saved.android.own)
        let reloaded = try await client.buildArgs("argument-roundtrip")
        XCTAssertEqual(flags, reloaded.android.effective)
        let cleared = try await client.setBuildArgs("argument-roundtrip", platform: .android, args: [])
        XCTAssertTrue(cleared.android.own.isEmpty)
    }

    func testClientDecodesJSONWhenTheCLIAlsoWritesAWarningToStderr() async throws {
        // Regression: stdout and stderr shared one pipe, so a single warning from a
        // shell rc file or a Ruby gem was interleaved into a one-shot `api` document
        // and JSONDecoder rejected the whole thing. bootstrap() then blanked the
        // project list and reported "CLI unavailable" against a healthy CLI.
        let stub = try Self.stubCLI("""
        #!/bin/sh
        printf 'warning: Insecure world writable dir in PATH\\n' >&2
        printf '%s\\n' '\(Self.capabilitiesDocumentJSON)'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

        let capabilities = try await FRKClient(executableURL: stub).capabilities()

        XCTAssertEqual(capabilities.cliVersion, "0.7.0")
        XCTAssertEqual(capabilities.protocolVersion, 1)
    }

    func testClientDecodesJSONWhenTheCLIFloodsStderrBeforeAnswering() async throws {
        // The two pipes must be drained concurrently: a child that fills the 64 KiB
        // stderr buffer blocks before it ever writes stdout, so a reader that waits
        // on stdout to EOF first would never return.
        let stub = try Self.stubCLI("""
        #!/bin/sh
        head -c 200000 /dev/zero | tr '\\0' 'x' >&2
        printf '%s\\n' '\(Self.capabilitiesDocumentJSON)'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

        let capabilities = try await FRKClient(executableURL: stub).capabilities()

        XCTAssertEqual(capabilities.cliVersion, "0.7.0")
    }

    func testCommandFailureReportsStderrAndFallsBackToStdoutWhenStderrIsEmpty() async throws {
        let both = try Self.stubCLI("""
        #!/bin/sh
        printf 'boom on stderr\\n' >&2
        printf 'noise on stdout\\n'
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: both.deletingLastPathComponent()) }

        // The diagnostic is the stderr text alone; the stdout noise no longer rides
        // along in the message the way the shared pipe used to make it.
        await assertThrows("boom on stderr\n") {
            _ = try await FRKClient(executableURL: both).projects()
        }

        let stdoutOnly = try Self.stubCLI("""
        #!/bin/sh
        printf 'unknown project apple\\n'
        exit 2
        """)
        defer { try? FileManager.default.removeItem(at: stdoutOnly.deletingLastPathComponent()) }

        // ...and with stderr empty the message still falls back to stdout, which is
        // the byte-identical half of the pre-split behaviour.
        await assertThrows("unknown project apple\n") {
            _ = try await FRKClient(executableURL: stdoutOnly).projects()
        }
    }

    private static let capabilitiesDocumentJSON = #"{"protocolVersion":1,"cliVersion":"0.7.0","minimumDesktopProtocol":1,"maximumDesktopProtocol":1,"capabilities":{"projectDiscovery":true,"streamingEvents":true,"credentialManagement":true,"productionRelease":false,"platforms":["android","ios"],"actions":["build"]}}"#

    @MainActor
    func testClientTreatsATerminatedStoreQueryAsCancellationInsteadOfAnAPIError() async throws {
        let stub = try Self.stubCLI("""
        #!/usr/bin/env python3
        import json, signal, sys, time
        from pathlib import Path
        def cancel(signum, frame):
            print(json.dumps({"protocolVersion": 1, "cliVersion": "0.8.1", "error": {
                "code": "store_query_cancelled", "message": "Store check cancelled"
            }}), flush=True)
            sys.exit(143)
        signal.signal(signal.SIGTERM, cancel)
        Path(__file__).with_name("ready").touch()
        while True:
            time.sleep(0.05)
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let ready = stub.deletingLastPathComponent().appendingPathComponent("ready")
        let client = FRKClient(executableURL: stub)
        let task = Task { _ = try await client.storeVersions("fixture") }
        defer { task.cancel() }
        try await Self.settle(while: { !FileManager.default.fileExists(atPath: ready.path) })
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled query must not complete successfully")
        } catch is CancellationError {
            // The CLI's diagnostic and exit status must not hide Task cancellation.
        }
    }

    private static func stubCLI(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("frk-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("frk")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func testStreamingClientReceivesTerminalEventFromRealCLI() throws {
        let client = FRKClient(executableURL: Self.realCLIURL())
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

    @MainActor
    func testStreamKeepsAMultiByteCharacterWholeAcrossAChunkBoundary() {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        var payload = Data(Self.logEventJSON(message: "héllo").utf8)
        payload.append(0x0A)
        // Split inside the two bytes of "é" (0xC3 0xA9), which is what a 64 KB pipe
        // boundary does to a multi-byte character.
        let boundary = payload.firstIndex(of: 0xC3)! + 1

        model.consume(payload[..<boundary])
        model.consume(payload[boundary...])

        XCTAssertEqual(model.activity.map(\.message), ["héllo"])
    }

    @MainActor
    func testStreamEmitsALastLineThatNeverGotItsNewline() {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        model.consume(Data(Self.logEventJSON(message: "no trailing newline").utf8))
        XCTAssertEqual(model.activity, [], "an unterminated line must wait for more bytes")

        model.flushRemainder()

        XCTAssertEqual(model.activity.map(\.message), ["no trailing newline"])
    }

    func testLineBufferHoldsAPayloadSplitMidJSONUntilItIsWhole() {
        var buffer = NDJSONLineBuffer()
        let line = Self.logEventJSON(message: "split")
        let head = String(line.prefix(20))
        let tail = String(line.dropFirst(20))

        XCTAssertEqual(buffer.feed(Data(head.utf8)), [])
        XCTAssertEqual(buffer.feed(Data((tail + "\n").utf8)), [line])
        XCTAssertNil(buffer.flush())
    }

    func testLineBufferFlushReturnsTheUnterminatedTailExactlyOnce() {
        var buffer = NDJSONLineBuffer()

        XCTAssertEqual(buffer.feed(Data("first\nsecond".utf8)), ["first"])
        XCTAssertEqual(buffer.flush(), "second")
        XCTAssertNil(buffer.flush())
    }

    func testLineBufferReportsEmptyLinesAndLeavesTheGuardToTheCaller() {
        var buffer = NDJSONLineBuffer()

        // The blank line is a real line of the stream, so the buffer returns it; it is
        // AppModel's whitespace guard that keeps it out of the activity log.
        XCTAssertEqual(buffer.feed(Data("a\n\nb\n".utf8)), ["a", "", "b"])
    }

    @MainActor
    func testStreamDropsBlankLinesAndKeepsUndecodableOnesAsText() {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        model.consume(Data("\n   \nnot json at all\n".utf8))

        XCTAssertEqual(model.activity.map(\.message), ["not json at all"])
        XCTAssertEqual(model.activity.map(\.kind), [.info])
    }

    @MainActor
    func testALogLineCarryingFastlanesOwnErrorMarkerIsClassifiedAsErrorAndPinned() {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        model.consume(Data((Self.logEventJSON(message: "[!] Authentication credentials are missing or invalid.") + "\n").utf8))

        XCTAssertEqual(model.activity.map(\.kind), [.error])
        XCTAssertEqual(model.lastActivityErrorLine, "[!] Authentication credentials are missing or invalid.")
    }

    @MainActor
    func testAPlainBacktraceLineIsNotMistakenForFastlanesErrorLine() {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        model.consume(Data((Self.logEventJSON(message: "from /opt/homebrew/Cellar/fastlane/2.230.0_1/libexec/bin/fastlane:25:in '<main>'") + "\n").utf8))

        XCTAssertEqual(model.activity.map(\.kind), [.info])
        XCTAssertNil(model.lastActivityErrorLine)
    }

    @MainActor
    func testStartingANewRunClearsThePinnedErrorLineFromThePreviousFailure() throws {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        model.consume(Data((Self.logEventJSON(message: "[!] previous run's authentication error") + "\n").utf8))
        XCTAssertEqual(model.lastActivityErrorLine, "[!] previous run's authentication error")

        // Executable bit set, but not something the kernel can exec — process.run() throws
        // before anything streams, so this only has to prove the reset that happens at the
        // top of start(), not carry a run to completion.
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("frk-not-a-program-\(UUID().uuidString)")
        try Data("not a program".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }
        model.cliPath = stub.path

        model.start(FRKRunRequest(action: .status))

        XCTAssertNil(model.lastActivityErrorLine)
    }

    func testDisplayTextDropsAPlainUserErrorsMarkerPrefix() {
        XCTAssertEqual(
            ActivityPanel.displayText(for: "[!] Authentication credentials are missing or invalid."),
            "Authentication credentials are missing or invalid."
        )
    }

    func testDisplayTextKeepsOnlyWhatFollowsTheMarkerInACrashsRaiseSiteLine() {
        // A crash's first line glues Ruby's own "path:line:in 'method': " prefix onto the
        // front of fastlane's "[!] " message — the raise site is noise the user cannot
        // act on, so only the marker onward should reach the banner.
        let raw = "interface.rb:153:in 'FastlaneCore::Interface#shell_error!': [!] Exit status of command 'flutter build ipa' was 1 instead of 0. (FastlaneCore::Interface::FastlaneShellError)"
        XCTAssertEqual(
            ActivityPanel.displayText(for: raw),
            "Exit status of command 'flutter build ipa' was 1 instead of 0. (FastlaneCore::Interface::FastlaneShellError)"
        )
    }

    func testDisplayTextReturnsALineUnchangedWhenItCarriesNoMarker() {
        let line = "from /opt/homebrew/Cellar/fastlane/2.230.0_1/libexec/bin/fastlane:25:in '<main>'"
        XCTAssertEqual(ActivityPanel.displayText(for: line), line)
    }

    // Every upload label — the button, the confirmation, and the tooltip — is built from
    // this one mapping, because a release_kit.yml onboarded onto alpha or beta must not
    // read "Internal" anywhere: that's not a wording nit, it names the wrong destination.
    func testPlayTrackDisplayNameUsesTheConsolesCurrentNamesForAlphaAndBeta() {
        XCTAssertEqual(ProjectDetailView.playTrackDisplayName("alpha"), "Closed Testing")
        XCTAssertEqual(ProjectDetailView.playTrackDisplayName("beta"), "Open Testing")
    }

    func testPlayTrackDisplayNameDefaultsToInternalForNilOrTheExplicitValue() {
        XCTAssertEqual(ProjectDetailView.playTrackDisplayName("internal"), "Internal Testing")
        XCTAssertEqual(ProjectDetailView.playTrackDisplayName(nil), "Internal Testing")
    }

    // The Fastfile already refuses to upload anything outside internal/alpha/beta, so this
    // can only reach the UI via a hand-edited release_kit.yml. It should read back exactly
    // what's actually configured rather than mislabel it as a track it is not.
    func testPlayTrackDisplayNameEchoesAnUnrecognizedTrackInsteadOfMislabelingIt() {
        XCTAssertEqual(ProjectDetailView.playTrackDisplayName("production"), "Production")
    }

    @MainActor
    func testClearActivityAlsoClearsThePinnedErrorLine() {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        model.consume(Data((Self.logEventJSON(message: "[!] some earlier failure") + "\n").utf8))
        XCTAssertEqual(model.lastActivityErrorLine, "[!] some earlier failure")

        model.clearActivity()

        XCTAssertNil(model.lastActivityErrorLine)
        XCTAssertEqual(model.activity, [])
    }

    func testLineBufferKeepsAMultiByteCharacterWholeAcrossFeeds() {
        var buffer = NDJSONLineBuffer()
        let bytes = Array("hé".utf8) // 68 C3 A9

        XCTAssertEqual(buffer.feed(Data(bytes[0..<2])), [])
        XCTAssertEqual(buffer.feed(Data(bytes[2...] + [0x0A])), ["hé"])
    }

    func testLineBufferDecodesAnInvalidByteSequenceLossilyInsteadOfDroppingTheLine() {
        var buffer = NDJSONLineBuffer()

        // 0xFF can never appear in UTF-8, so this line is genuinely undecodable rather
        // than merely truncated; the text still has to reach the activity log.
        XCTAssertEqual(buffer.feed(Data([0x61, 0xFF, 0x62, 0x0A])), ["a\u{FFFD}b"])
    }

    @MainActor
    func testStartStreamsEveryLineFromTheRealCLIBeforeSettlingTheRun() async throws {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        model.cliPath = Self.realCLIURL().path

        model.start(FRKRunRequest(action: .status))
        XCTAssertTrue(model.isRunning)
        let acceptedRun = try XCTUnwrap(model.activityRunID)
        model.start(FRKRunRequest(action: .status))
        XCTAssertEqual(model.activityRunID, acceptedRun, "A rejected duplicate must not reopen activity.")

        let deadline = Date().addingTimeInterval(30)
        while model.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.runningTitle)
        // The terminal event is the CLI's last line, so seeing the outcome recorded
        // proves the bookkeeping ran after the stream drained, not beside it.
        XCTAssertEqual(model.lastRunOutcome, .success)
        XCTAssertEqual(model.activity.last?.kind, .success)
        XCTAssertTrue(
            model.activity.contains { $0.message.hasPrefix("Completed successfully") },
            "activity was \(model.activity.map(\.message))"
        )
    }

    @MainActor
    func testAReadStillInFlightWhenTheChildExitsIsNotDroppedByTheStream() async throws {
        // Foundation runs readability callbacks on one queue and the termination
        // callback on another and does not serialise them, so a callback that has taken
        // its bytes off the descriptor can still be short of handing them over when the
        // child is reaped. Left to chance that window is a few instructions wide — 500
        // consecutive runs of this stub never once hit it — so the test holds each read
        // open instead of hoping to catch one, which is what makes the overlap a fact of
        // the run rather than a lottery.
        //
        // The child writes more than a pipe buffer's worth and exits the instant its
        // terminal event is out, so a read is guaranteed to be in flight at exit.
        let lineCount = 900
        let stub = try Self.stubCLI("""
        #!/bin/sh
        i=0
        while [ "$i" -lt \(lineCount) ]; do
          printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"log",\
        "timestamp":"2026-01-01T00:00:00Z","message":"line %s padded out so the child \
        outruns the reader and blocks on a full pipe"}\\n' "$i"
          i=$((i + 1))
        done
        printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"finished",\
        "timestamp":"2026-01-01T00:00:00Z","success":true,"exitCode":0,"durationSeconds":1.5}\\n'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

        let expected = (0..<lineCount).map {
            "line \($0) padded out so the child outruns the reader and blocks on a full pipe"
        } + ["Completed successfully 1.5s"]

        for iteration in 0..<3 {
            let model = AppModel(clientFactory: { _ in FakeFRKClient() })
            model.cliPath = stub.path
            // Every read is held for 25ms between taking its bytes and handing them
            // over, so whichever read is in flight when the child exits is still holding
            // its bytes while the termination handler runs.
            model.readabilityStall = { Thread.sleep(forTimeInterval: 0.025) }

            model.start(FRKRunRequest(action: .status))
            let deadline = Date().addingTimeInterval(30)
            while model.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertFalse(model.isRunning, "run \(iteration) never settled")

            // Asserting the whole log, not just its tail, is deliberate: bytes taken by
            // an in-flight read go missing wherever that read happened to be, and the
            // terminal event is only the case that also costs the run its outcome and
            // its duration. Both are the same dropped-bytes defect.
            XCTAssertEqual(
                model.activity.map(\.message), expected,
                "run \(iteration) delivered \(model.activity.count) of \(expected.count) lines"
            )
            XCTAssertEqual(model.activity.last?.kind, .success)
            XCTAssertEqual(model.lastRunOutcome, .success)
        }
    }

    @MainActor
    func testATerminalEventHeldByTheLastReadStillSettlesTheRun() async throws {
        // The same defect at its most expensive. Everything this child writes fits in
        // the pipe buffer, so one read takes the whole run — terminal event included —
        // and the child exits while that read is still holding it. Finishing the stream
        // underneath it drops all of it at once: the run then settles from
        // terminationStatus, which records an outcome but writes nothing, so the
        // duration and every logged line disappear together.
        let stub = try Self.stubCLI("""
        #!/bin/sh
        printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"log",\
        "timestamp":"2026-01-01T00:00:00Z","message":"packaging"}\\n'
        printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"finished",\
        "timestamp":"2026-01-01T00:00:00Z","success":true,"exitCode":0,"durationSeconds":1.5}\\n'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        model.cliPath = stub.path
        model.readabilityStall = { Thread.sleep(forTimeInterval: 0.05) }

        model.start(FRKRunRequest(action: .status))
        let deadline = Date().addingTimeInterval(30)
        while model.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.activity.map(\.message), ["packaging", "Completed successfully 1.5s"])
        XCTAssertEqual(model.lastRunOutcome, .success)
    }

    @MainActor
    func testAFailedLaunchSettlesTheRunOnceAndLeavesNoConsumerBehind() async throws {
        // Executable bit set, but not something the kernel can exec: makeStreamingProcess
        // accepts it and process.run() is what throws, which is the only branch that can
        // reach the catch after the byte stream has been wired up.
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("frk-not-a-program-\(UUID().uuidString)")
        try Data("not a program".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }

        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        model.cliPath = stub.path

        model.start(FRKRunRequest(action: .status))

        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.runningTitle)
        XCTAssertEqual(model.lastRunOutcome, .failure)
        let settledMessage = try XCTUnwrap(model.errorMessage)
        XCTAssertEqual(model.activity.map(\.message), [settledMessage])

        // The catch settles the run synchronously; nothing may settle it a second time
        // afterwards, or the launch failure would be overwritten by a reload error.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(model.errorMessage, settledMessage)
        XCTAssertEqual(model.activity.map(\.message), [settledMessage])
        XCTAssertEqual(model.lastRunOutcome, .failure)
    }

    private static func logEventJSON(message: String) -> String {
        """
        {"protocolVersion":1,"cliVersion":"0.7.0","type":"log",\
        "timestamp":"2026-01-01T00:00:00Z","message":"\(message)"}
        """
    }

    func testWorkspaceUsesFocusedLayoutBeforeContentWouldClip() {
        XCTAssertEqual(WorkspaceLayoutMode(width: 680), .focused)
        XCTAssertEqual(WorkspaceLayoutMode(width: 899), .focused)
        XCTAssertEqual(WorkspaceLayoutMode(width: 900), .standard)
        XCTAssertEqual(WorkspaceLayoutMode(width: 1179), .standard)
        XCTAssertEqual(WorkspaceLayoutMode(width: 1180), .expanded)
    }

    func testVisibleActivitySurvivesResizingInBothDirections() {
        var presentation = ActivityPresentationState()
        presentation.isVisible = true
        XCTAssertTrue(presentation.showsSidebar)
        presentation.layoutMode = .focused
        XCTAssertTrue(presentation.showsCompactPanel)
        XCTAssertFalse(presentation.showsSidebar)
        presentation.layoutMode = .standard
        XCTAssertTrue(presentation.showsCompactPanel)
        presentation.layoutMode = .expanded
        XCTAssertTrue(presentation.showsSidebar)
        XCTAssertFalse(presentation.showsCompactPanel)
    }

    func testDismissedActivityStaysHiddenAfterResizing() {
        var presentation = ActivityPresentationState()
        presentation.layoutMode = .focused
        presentation.isVisible = true
        presentation.isVisible = false
        presentation.layoutMode = .expanded
        XCTAssertFalse(presentation.showsSidebar)
        presentation.layoutMode = .standard
        XCTAssertFalse(presentation.showsCompactPanel)
    }

    @MainActor
    func testSettingsDraftCleanupTracksOnlyItsOwnWindow() {
        _ = NSApplication.shared
        let settingsWindow = NSWindow()
        let unrelatedWindow = NSWindow()
        settingsWindow.isReleasedWhenClosed = false
        unrelatedWindow.isReleasedWhenClosed = false
        let observer = SettingsWindowCloseObserver.ObserverView()
        var discardedDrafts = 0
        observer.onClose = { discardedDrafts += 1 }
        settingsWindow.contentView = observer

        unrelatedWindow.close()
        XCTAssertEqual(discardedDrafts, 0, "Closing another window must preserve the current draft.")
        settingsWindow.close()
        XCTAssertEqual(discardedDrafts, 1, "The retained Settings scene must discard its draft on close.")

        settingsWindow.contentView = nil
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settingsWindow)
        XCTAssertEqual(discardedDrafts, 1, "A detached view must stop observing its former window.")
    }

    @MainActor
    func testEachImmediateLaunchFailureLeavesAnObservableActivityRun() throws {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })
        model.cliPath = "/nonexistent/frk-\(UUID().uuidString)"
        XCTAssertNil(model.activityRunID)
        model.start(FRKRunRequest(action: .status))
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.lastRunOutcome, .failure)
        let firstRun = try XCTUnwrap(model.activityRunID)
        model.clearActivity()
        XCTAssertEqual(model.activityRunID, firstRun, "Clearing output must not reopen activity.")
        model.start(FRKRunRequest(action: .status))
        XCTAssertNotEqual(try XCTUnwrap(model.activityRunID), firstRun)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.activity.last?.kind, .error)
    }

    func testProjectSearchMatchesNamesFoldersAndApplicationIDs() {
        let project = Self.projectSummary(id: "sample", name: "Café Demo")
        XCTAssertTrue(ProjectBrowserFilter.all.includes(project, query: "  CAFE  "))
        XCTAssertTrue(ProjectBrowserFilter.all.includes(project, query: "/tmp/sample"))
        XCTAssertTrue(ProjectBrowserFilter.all.includes(project, query: "ORG.EXAMPLE.SAMPLE"))
        XCTAssertTrue(ProjectBrowserFilter.all.includes(project, query: "demo org.example"))
        XCTAssertFalse(ProjectBrowserFilter.all.includes(project, query: "demo unknown"))
        XCTAssertTrue(ProjectBrowserFilter.all.includes(project, query: " \n "))
        let ios = Self.iosProject(signingReady: true, profileReady: true)
        XCTAssertTrue(ProjectBrowserFilter.all.includes(ios, query: "org.example.app"))
    }

    func testProjectFiltersCombinePlatformAndSearch() {
        let project = Self.projectSummary(id: "sample", name: "Demo")
        XCTAssertTrue(ProjectBrowserFilter.android.includes(project, query: "demo"))
        XCTAssertFalse(ProjectBrowserFilter.ios.includes(project, query: "demo"))
        XCTAssertFalse(ProjectBrowserFilter.android.includes(project, query: "unknown"))
        XCTAssertFalse(ProjectBrowserFilter.needsSetup.includes(project, query: "demo"))
    }

    func testProjectSetupStatusIncludesEveryConfiguredPlatform() {
        let project = Self.projectSummary(id: "sample", name: "Demo", platforms: [.android, .ios])
        XCTAssertTrue(project.isReady) // Registry membership is not signing readiness.
        XCTAssertTrue(project.needsSetup)
        XCTAssertEqual(project.setupLabel, "Signing required")
        XCTAssertTrue(ProjectBrowserFilter.needsSetup.includes(project, query: "demo"))
        let signed = Self.projectSummary(id: "sample", name: "Demo")
        XCTAssertFalse(signed.needsSetup)
        XCTAssertEqual(signed.setupLabel, "Signing ready")
    }

    func testProjectSetupStatusPreservesLegacyIOSReadiness() {
        XCTAssertFalse(Self.iosProject(signingReady: nil, profileReady: true).needsSetup)
        XCTAssertTrue(Self.iosProject(signingReady: false, profileReady: true).needsSetup)
        XCTAssertTrue(Self.iosProject(signingReady: nil, profileReady: false).needsSetup)
    }

    func testMissingAndUnconfiguredProjectsNeverShowAsReady() {
        let missing = Self.projectSummary(id: "missing", name: "Missing", exists: false)
        XCTAssertTrue(missing.needsSetup)
        XCTAssertEqual(missing.setupLabel, "Folder missing")
        let unconfigured = Self.projectSummary(id: "new", name: "New", onboarded: false)
        XCTAssertTrue(unconfigured.needsSetup)
        XCTAssertEqual(unconfigured.setupLabel, "Setup required")
        XCTAssertTrue(Self.projectSummary(id: "empty", name: "Empty", platforms: []).needsSetup)
    }

    @MainActor
    func testActivityKeepsItsProjectContextWhenSelectionChanges() async throws {
        let fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "first", name: "First App"),
            Self.projectSummary(id: "second", name: "Second App"),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        // A missing executable fails locally; no build or store request is made.
        model.cliPath = "/nonexistent/frk-\(UUID().uuidString)"
        model.start(FRKRunRequest(action: .build, project: "first", platform: .android))
        XCTAssertEqual(model.activityContext, "First App · Android")
        model.selectedProjectID = "second"
        XCTAssertEqual(model.activityContext, "First App · Android")
        model.clearActivity()
        XCTAssertNil(model.activityContext)
    }

    func testEveryProjectFieldTheAppDecodesIsEmittedByTheCLI() throws {
        let contract = try Self.keyContract()
        let project = ProjectSummary(
            id: "example",
            name: "Example",
            path: "/tmp/example",
            exists: true,
            onboarded: true,
            state: "ready",
            platforms: [.android, .ios],
            version: "1.4.2+17",
            buildName: "1.4.2",
            buildNumber: 17,
            android: AndroidSummary(packageId: "org.example.app", signingReady: true, track: "internal"),
            ios: IOSSummary(
                bundleId: "org.example.app",
                teamId: "ABCDE12345",
                profileReady: true,
                profilePath: "/vault/profile.mobileprovision",
                distributionIdentityReady: true,
                signingReady: true
            ),
            artifacts: ArtifactSummary(
                androidAab: ArtifactRecord(path: "/tmp/app.aab", sizeBytes: 1, modifiedAt: "2026-01-01T00:00:00+00:00"),
                iosIpa: ArtifactRecord(path: "/tmp/app.ipa", sizeBytes: 2, modifiedAt: "2026-01-01T00:00:00+00:00")
            ),
            addedAt: "2026-01-01T00:00:00+00:00"
        )

        try assertCLIEmitsEveryKey(of: project, forRecord: "project_api_record", in: contract)
    }

    func testEverySetupStatusFieldTheAppDecodesIsEmittedByTheCLI() throws {
        let contract = try Self.keyContract()
        let response = SetupStatusResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            projectId: "example",
            android: AndroidSetupStatus(
                configured: true,
                packageId: "org.example.app",
                projectPropertiesPath: "/app/android/key.properties",
                projectPropertiesExists: true,
                propertiesComplete: true,
                missingPropertiesFields: [],
                referencedKeystorePath: "/app/android/upload.jks",
                keystoreExists: true,
                keystoreValidationStatus: "valid",
                keystoreValidationDetail: "detail",
                certificateSHA256: "AA:BB",
                gradleConfigured: true,
                gradleConfigurationPath: "/app/android/app/build.gradle.kts",
                gradleConfigurationDetail: "detail",
                vaultPath: "/vault/org.example.app",
                vaultReady: true,
                projectLinked: true,
                gitTracked: false,
                propertiesGitIgnored: true,
                keystoreGitTracked: false,
                keystoreGitIgnored: true,
                gitSafe: true,
                signingReady: true
            ),
            ios: IOSSetupStatus(
                configured: true,
                bundleId: "org.example.app",
                teamId: "ABCDE12345",
                projectIdentityReady: true,
                projectIdentityDetail: "detail",
                workspacePath: "/app/ios/Runner.xcworkspace",
                workspaceExists: true,
                distributionIdentityReady: true,
                distributionIdentityDetail: "detail",
                ascCredentialsReady: true,
                profilePath: "/vault/profile.mobileprovision",
                profileReady: true,
                profileValidationStatus: "valid",
                profileValidationDetail: "detail",
                profileExpiresAt: "2027-01-01T00:00:00+00:00",
                profileCertificateMatchesIdentity: true,
                exportOptionsReady: true,
                exportOptionsPath: "/app/ios/ExportOptions.plist",
                exportOptionsDetail: "detail",
                signingReady: true
            ),
            error: nil
        )

        try assertCLIEmitsEveryKey(
            of: response,
            forRecord: "setup_status_record",
            in: contract,
            ignoringAppKeys: Self.envelopeKeys
        )
    }

    func testEveryCredentialFieldTheAppDecodesIsEmittedByTheCLI() throws {
        let contract = try Self.keyContract()
        let response = CredentialsResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            vaultPath: "/vault",
            configuredAny: true,
            googlePlay: GooglePlayCredentialStatus(
                configured: true,
                validationStatus: "ready",
                detail: "detail",
                keyPath: "/vault/play/service-account.json",
                clientEmail: "release@example.com",
                projectId: "release-project"
            ),
            appStoreConnect: AppStoreCredentialStatus(
                configured: true,
                validationStatus: "ready",
                detail: "detail",
                keyPath: "/vault/asc/AuthKey_ABCDE12345.p8",
                keyId: "ABCDE12345",
                issuerId: "11111111-2222-3333-4444-555555555555"
            ),
            error: nil
        )

        try assertCLIEmitsEveryKey(
            of: response,
            forRecord: "credential_status_record",
            in: contract,
            ignoringAppKeys: Self.envelopeKeys
        )
    }

    func testEveryCapabilityFieldTheAppDecodesIsEmittedByTheCLI() throws {
        let contract = try Self.keyContract()
        let response = CapabilitiesResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            minimumDesktopProtocol: 1,
            maximumDesktopProtocol: 1,
            capabilities: CapabilitiesResponse.Capabilities(
                projectDiscovery: true,
                streamingEvents: true,
                credentialManagement: true,
                productionRelease: false,
                platforms: ["android", "ios"],
                actions: ["build"]
            )
        )

        // capabilities is captured as a whole document, so the envelope keys are
        // part of the contract here rather than something to ignore.
        try assertCLIEmitsEveryKey(of: response, forRecord: "capabilities_document", in: contract)
    }

    func testEveryStoreVersionFieldTheAppDecodesIsEmittedByTheCLI() throws {
        let contract = try Self.keyContract()
        // Every optional is populated on purpose: a nil encodes to no key at all, so a
        // sparse sample would quietly shrink the app's key set and pass direction 1
        // while hiding a field the CLI still emits.
        let response = StoreVersionsResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            project: "example_app",
            checkedAt: "2026-08-08T09:41:07.412Z",
            android: AndroidStoreVersions(
                status: .ok,
                detail: "detail",
                track: "internal",
                latestVersionCode: 38,
                latestVersionName: "2.0.9",
                tracks: [AndroidTrackVersion(track: "internal", versionCode: 38, versionName: "2.0.9")]
            ),
            ios: IOSStoreVersions(
                status: .ok,
                detail: "detail",
                latestAppStoreVersion: "2.0.8",
                builds: [IOSStoreBuild(version: "2.1.0", build: 41, state: "PROCESSING")]
            ),
            error: nil
        )

        // store-versions is captured as a whole document, envelope included, like
        // capabilities. `error` never coexists with a report, so it is not in the
        // fixture and must not be demanded of one.
        try assertCLIEmitsEveryKey(
            of: response,
            forRecord: "store_versions_document",
            in: contract,
            ignoringAppKeys: ["error"]
        )
    }

    func testEveryBuildArgsFieldTheAppDecodesIsEmittedByTheCLI() throws {
        let contract = try Self.keyContract()
        // shared and both platforms populated, matching the store-versions test's own
        // reasoning: a sample with an empty own/effective would still pass but freeze
        // a smaller key surface than a project that actually uses the feature sends.
        let response = BuildArgsResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            shared: ["--dart-define=COMMON=1"],
            android: PlatformBuildArgs(
                configured: true,
                own: ["--dart-define=A=1"],
                effective: ["--dart-define=COMMON=1", "--dart-define=A=1"]
            ),
            ios: PlatformBuildArgs(configured: true, own: [], effective: ["--dart-define=COMMON=1"])
        )

        try assertCLIEmitsEveryKey(of: response, forRecord: "build_args_document", in: contract)
    }

    func testKeyContractFixtureCarriesNamesOnlyAndMatchesProtocolV1() throws {
        let contract = try Self.keyContract()

        XCTAssertEqual(contract.protocolVersion, 1)
        XCTAssertEqual(contract.records.keys.sorted(), [
            "build_args_document",
            "capabilities_document",
            "credential_status_record",
            "project_api_record",
            "setup_status_record",
            "store_versions_document",
        ])
        for (record, levels) in contract.records {
            for (level, keys) in levels {
                XCTAssertEqual(keys, keys.sorted(), "\(record).\(level) is not sorted")
                for key in keys {
                    XCTAssertFalse(key.contains("/"), "\(record).\(level) contains a path value")
                }
            }
        }
    }

    @MainActor
    func testVersionedActionNeedsABuildNameAndAPositiveIntegerBuildNumber() {
        let model = AppModel()
        let cases: [(buildName: String, buildNumber: String, expected: Bool)] = [
            ("1.4.2", "17", true),
            ("  1.4.2  ", "17", true),
            ("1.4.2", "1", true),
            ("", "17", false),
            ("   ", "17", false),
            ("\t", "17", false),
            ("1.4.2", "", false),
            ("1.4.2", "0", false),
            ("1.4.2", "-1", false),
            ("1.4.2", "17.5", false),
            ("1.4.2", "17abc", false),
            // The build name is trimmed but the build number is not, so a padded
            // number is rejected today while a padded name is accepted.
            ("1.4.2", " 17", false),
            // Int("+17") parses in Swift, so a signed build number is accepted today.
            ("1.4.2", "+17", true),
        ]

        // The same rule has to hold on each platform independently, because each one
        // now carries its own build number.
        for platform in PlatformKind.allCases {
            for testCase in cases {
                model.sharedBuildName = testCase.buildName
                model.setBuildNumber(testCase.buildNumber, for: platform)

                XCTAssertEqual(
                    model.canRunVersionedAction(for: platform),
                    testCase.expected,
                    "\(platform.title) buildName \(testCase.buildName.debugDescription), "
                        + "buildNumber \(testCase.buildNumber.debugDescription)"
                )
            }
            model.setBuildNumber("", for: platform)
        }
    }

    @MainActor
    func testAnUnusableBuildNumberOnOnePlatformNeverBlocksTheOther() {
        let model = AppModel()
        model.sharedBuildName = "2.1.0"
        model.androidBuildNumber = "39"
        model.iosBuildNumber = ""

        XCTAssertTrue(model.canRunVersionedAction(for: .android))
        XCTAssertFalse(model.canRunVersionedAction(for: .ios))

        let project = Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios])
        XCTAssertEqual(model.runnablePlatforms(of: project), [.android])

        model.iosBuildNumber = "42"
        XCTAssertEqual(model.runnablePlatforms(of: project), [.android, .ios])
    }

    @MainActor
    func testBuildNumbersAreNeverSharedAcrossPlatforms() {
        let model = AppModel()
        model.sharedBuildName = "2.1.0"

        model.setBuildNumber("39", for: .android)
        model.setBuildNumber("42", for: .ios)

        XCTAssertEqual(model.buildNumber(for: .android), "39")
        XCTAssertEqual(model.buildNumber(for: .ios), "42")
        // Writing one must not move the other. The stores count uploads separately and
        // a linked pair is the defect this split exists to remove.
        model.setBuildNumber("40", for: .android)
        XCTAssertEqual(model.buildNumber(for: .ios), "42")
    }

    @MainActor
    func testVersionNameIsSharedUntilTheUserAsksForTwo() {
        let model = AppModel()
        model.sharedBuildName = "2.1.0"

        XCTAssertFalse(model.splitVersionName)
        XCTAssertEqual(model.buildName(for: .android), "2.1.0")
        XCTAssertEqual(model.buildName(for: .ios), "2.1.0")

        // Turning the toggle on seeds the iOS field from what the user already typed,
        // so the rare one-store hotfix starts from the shared name rather than empty.
        model.splitVersionName = true
        XCTAssertEqual(model.iosBuildName, "2.1.0")

        model.iosBuildName = "2.1.1"
        XCTAssertEqual(model.buildName(for: .android), "2.1.0")
        XCTAssertEqual(model.buildName(for: .ios), "2.1.1")

        // Turning it off falls back to the shared name without destroying the override,
        // so a toggle flipped by accident costs nothing.
        model.splitVersionName = false
        XCTAssertEqual(model.buildName(for: .ios), "2.1.0")
        XCTAssertEqual(model.iosBuildName, "2.1.1")

        model.splitVersionName = true
        XCTAssertEqual(model.buildName(for: .ios), "2.1.1")
    }

    @MainActor
    func testASplitVersionNameSurvivesAReloadOfTheSameProject() async throws {
        // reloadProjects runs after every job. Re-seeding the split field from pubspec
        // there would throw away a name the user typed on purpose.
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", buildName: "2.1.0", buildNumber: 4, platforms: [.android, .ios]),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.splitVersionName = true
        XCTAssertEqual(model.iosBuildName, "2.1.0")
        model.iosBuildName = "2.1.1"

        fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", buildName: "2.2.0", buildNumber: 5, platforms: [.android, .ios]),
        ]))
        try await model.reloadProjects()

        XCTAssertEqual(model.buildName(for: .android), "2.2.0")
        XCTAssertEqual(model.buildName(for: .ios), "2.1.1")
        XCTAssertEqual(model.androidBuildNumber, "5")
        XCTAssertEqual(model.iosBuildNumber, "5")
    }

    @MainActor
    func testATypedBuildNumberSurvivesTheReloadThatFollowsBuildOrValidateWhenPubspecDidNotChange() async throws {
        // The reported failure: raise the versionCode field, Build (which never touches
        // pubspec — see CONTRIBUTING's "versions are never auto-incremented"), then
        // Validate. reloadProjects() runs after Build settles, before Validate ever
        // starts, and pubspec still says the old number because nothing edited it. If
        // that reload put the old number back, Validate would run with it and Google
        // Play would reject the upload as a duplicate of the number the user thought
        // they had already moved past — exactly what was reported.
        let fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "maktab", name: "maktab", buildName: "2.0.0", buildNumber: 38, platforms: [.android, .ios]),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        XCTAssertEqual(model.androidBuildNumber, "38")

        model.androidBuildNumber = "39"
        // Simulates the reload AppModel.start() runs once Build settles: same project,
        // pubspec unchanged, so the fake's response is identical to the first reload.
        try await model.reloadProjects()

        XCTAssertEqual(
            model.androidBuildNumber, "39",
            "a same-project reload with an unchanged pubspec must not revert a number the user just typed"
        )
    }

    @MainActor
    func testATypedSharedBuildNameSurvivesTheSameReload() async throws {
        // Same guarantee as the build-number test above, for the version-name field the
        // report raised alongside versionCode.
        let fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "maktab", name: "maktab", buildName: "2.0.0", buildNumber: 38),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        XCTAssertEqual(model.sharedBuildName, "2.0.0")

        model.sharedBuildName = "2.1.0"
        try await model.reloadProjects()

        XCTAssertEqual(model.sharedBuildName, "2.1.0")
    }

    @MainActor
    func testEachPlatformsRequestCarriesItsOwnVersionPair() {
        let model = AppModel()
        model.sharedBuildName = "2.1.0"
        model.splitVersionName = true
        model.iosBuildName = "2.1.1"
        model.androidBuildNumber = "39"
        model.iosBuildNumber = "42"

        XCTAssertEqual(
            model.versionedRequest(.release, project: "apple", platform: .android).arguments,
            ["api", "run", "release", "apple", "--platform", "android", "--build-name", "2.1.0", "--build-number", "39"]
        )
        XCTAssertEqual(
            model.versionedRequest(.release, project: "apple", platform: .ios).arguments,
            ["api", "run", "release", "apple", "--platform", "ios", "--build-name", "2.1.1", "--build-number", "42"]
        )
    }

    @MainActor
    func testBootstrapConnectsAndLoadsCredentialsThenProjects() async {
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(
                capabilitiesResponse: Self.capabilitiesResponse(credentialManagement: true),
                projectsResponse: Self.projectsResponse([
                    Self.projectSummary(id: "banana", name: "Banana"),
                    Self.projectSummary(id: "apple", name: "apple", buildName: "1.4.2", buildNumber: 17),
                ]),
                credentialsResponse: Self.credentialsResponse(configuredAny: true)
            )
        })

        await model.bootstrap()

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.connectionMessage, "FRK 0.7.0 · Protocol v1")
        // Sorting is localizedCaseInsensitive, so "apple" leads "Banana" here even
        // though a plain ASCII sort would put the capital first.
        XCTAssertEqual(model.projects.map(\.name), ["apple", "Banana"])
        XCTAssertEqual(model.selectedProjectID, "apple")
        XCTAssertEqual(model.sharedBuildName, "1.4.2")
        XCTAssertEqual(model.androidBuildNumber, "17")
        XCTAssertEqual(model.iosBuildNumber, "17")
        XCTAssertTrue(model.credentialsStatus?.hasConfiguredStore == true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isLoadingCredentials)
    }

    @MainActor
    func testBootstrapSkipsCredentialsWhenTheCLIDoesNotAdvertiseThem() async {
        // credentials is nil, so the fake would throw if bootstrap asked for it.
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(
                capabilitiesResponse: Self.capabilitiesResponse(credentialManagement: false),
                projectsResponse: Self.projectsResponse([])
            )
        })

        await model.bootstrap()

        XCTAssertTrue(model.isConnected)
        XCTAssertNil(model.credentialsStatus)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testBootstrapFailureClearsEverythingAPreviousBootstrapLoaded() async {
        var fake = FakeFRKClient(
            capabilitiesResponse: Self.capabilitiesResponse(credentialManagement: true),
            projectsResponse: Self.projectsResponse([Self.projectSummary(id: "apple", name: "apple")]),
            credentialsResponse: Self.credentialsResponse(configuredAny: true)
        )
        let model = AppModel(clientFactory: { _ in fake })
        await model.bootstrap()
        XCTAssertTrue(model.isConnected)

        fake = FakeFRKClient()
        await model.bootstrap()

        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.connectionMessage, "CLI unavailable")
        XCTAssertNil(model.capabilities)
        XCTAssertEqual(model.projects, [])
        XCTAssertNil(model.selectedProjectID)
        XCTAssertNil(model.credentialsStatus)
        XCTAssertFalse(model.showCredentialOnboarding)
        XCTAssertEqual(model.errorMessage, FakeFRKClient.failureMessage)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testBootstrapDisconnectsWhenOnlyTheProjectListFails() async {
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(capabilitiesResponse: Self.capabilitiesResponse(credentialManagement: false))
        })

        await model.bootstrap()

        // capabilities succeeded and was published before projects threw, so this
        // pins that the failure path rolls that back rather than leaving a half
        // connected model behind.
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.capabilities)
        XCTAssertEqual(model.errorMessage, FakeFRKClient.failureMessage)
    }

    @MainActor
    func testReloadProjectsKeepsAStillPresentSelectionAndResyncsVersionFields() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple"),
            Self.projectSummary(id: "banana", name: "Banana", buildName: "1.0.0", buildNumber: 3),
        ]))
        let model = AppModel(clientFactory: { _ in fake })

        try await model.reloadProjects()
        XCTAssertEqual(model.selectedProjectID, "apple")
        model.selectedProjectID = "banana"

        fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple"),
            Self.projectSummary(id: "banana", name: "Banana", buildName: "2.0.0", buildNumber: 9),
        ]))
        try await model.reloadProjects()

        XCTAssertEqual(model.selectedProjectID, "banana")
        XCTAssertEqual(model.sharedBuildName, "2.0.0")
        XCTAssertEqual(model.androidBuildNumber, "9")
        XCTAssertEqual(model.iosBuildNumber, "9")
    }

    @MainActor
    func testReloadProjectsFallsBackToTheFirstProjectWhenTheSelectionDisappears() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", buildName: "1.4.2", buildNumber: 17),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        XCTAssertEqual(model.selectedProjectID, "apple")

        fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "banana", name: "Banana"),
        ]))
        try await model.reloadProjects()

        XCTAssertEqual(model.selectedProjectID, "banana")
        XCTAssertEqual(model.sharedBuildName, "")
        XCTAssertEqual(model.androidBuildNumber, "")
        XCTAssertEqual(model.iosBuildNumber, "")
    }

    @MainActor
    func testReloadProjectsClearsTheSelectionWhenTheRegistryIsEmpty() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple"),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()

        fake = FakeFRKClient(projectsResponse: Self.projectsResponse([]))
        try await model.reloadProjects()

        XCTAssertEqual(model.projects, [])
        XCTAssertNil(model.selectedProjectID)
    }

    @MainActor
    func testReloadProjectsPropagatesClientFailuresToItsCaller() async {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        await assertThrows(FakeFRKClient.failureMessage) {
            try await model.reloadProjects()
        }
    }

    @MainActor
    func testCredentialStatusIsStoredWithoutOpeningOnboardingWhenAStoreIsConfigured() async throws {
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(credentialsResponse: Self.credentialsResponse(configuredAny: true))
        })

        try await model.loadCredentialStatus()

        XCTAssertTrue(model.credentialsStatus?.hasConfiguredStore == true)
        XCTAssertFalse(model.showCredentialOnboarding)
        XCTAssertFalse(model.isLoadingCredentials)
    }

    @MainActor
    func testCredentialStatusOpensOnboardingOnlyWhileNoStoreAndNoDecisionExist() async throws {
        let defaults = UserDefaults.standard
        let key = "credentialSetupDecisionMade"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(credentialsResponse: Self.credentialsResponse(configuredAny: false))
        })

        defaults.set(false, forKey: key)
        try await model.loadCredentialStatus()
        XCTAssertTrue(model.showCredentialOnboarding)

        defaults.set(true, forKey: key)
        try await model.loadCredentialStatus()
        XCTAssertFalse(model.showCredentialOnboarding)

        // The settings-screen refresh passes presentFirstRunIfNeeded: false, and must
        // not re-open the assistant even when the decision has been reset.
        defaults.set(false, forKey: key)
        try await model.loadCredentialStatus(presentFirstRunIfNeeded: false)
        XCTAssertFalse(model.showCredentialOnboarding)
    }

    @MainActor
    func testCredentialStatusRejectsAnErrorDocumentInsteadOfStoringIt() async {
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(credentialsResponse: Self.credentialsResponse(
                configuredAny: false,
                error: APIErrorPayload(code: "vault_unreadable", message: "The vault is unreadable.")
            ))
        })

        await assertThrows("The vault is unreadable.") {
            try await model.loadCredentialStatus()
        }

        XCTAssertNil(model.credentialsStatus)
        XCTAssertFalse(model.isLoadingCredentials)
    }

    @MainActor
    func testCredentialStatusPropagatesClientFailures() async {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        await assertThrows(FakeFRKClient.failureMessage) {
            try await model.loadCredentialStatus()
        }

        XCTAssertNil(model.credentialsStatus)
        XCTAssertFalse(model.isLoadingCredentials)
    }

    @MainActor
    func testSetupStatusIsStoredOnSuccess() async {
        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(setupStatusResponse: Self.setupStatusResponse(projectId: "apple"))
        })

        await model.loadSetupStatus(for: "apple")

        XCTAssertEqual(model.setupStatus?.projectId, "apple")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingSetup)
    }

    @MainActor
    func testSetupStatusErrorDocumentDropsAnyPreviouslyLoadedStatus() async {
        var fake = FakeFRKClient(setupStatusResponse: Self.setupStatusResponse(projectId: "apple"))
        let model = AppModel(clientFactory: { _ in fake })
        await model.loadSetupStatus(for: "apple")
        XCTAssertNotNil(model.setupStatus)

        fake = FakeFRKClient(setupStatusResponse: Self.setupStatusResponse(
            projectId: "apple",
            error: APIErrorPayload(code: "unknown_project", message: "No project named apple.")
        ))
        await model.loadSetupStatus(for: "apple")

        XCTAssertNil(model.setupStatus)
        XCTAssertEqual(model.errorMessage, "No project named apple.")
        XCTAssertFalse(model.isLoadingSetup)
    }

    @MainActor
    func testSetupStatusReportsClientFailuresAsAMessageRatherThanThrowing() async {
        let model = AppModel(clientFactory: { _ in FakeFRKClient() })

        await model.loadSetupStatus(for: "apple")

        XCTAssertNil(model.setupStatus)
        XCTAssertEqual(model.errorMessage, FakeFRKClient.failureMessage)
        XCTAssertFalse(model.isLoadingSetup)
    }

    // MARK: - Store version report

    func testStoreVersionsDocumentDecodesTheShapeTheCLIDocuments() throws {
        let response = try Self.decodeStoreVersions("""
        {"protocolVersion":1,"cliVersion":"0.7.0","project":"example_app",\
        "checkedAt":"2026-08-08T09:41:07.412Z",\
        "android":{"status":"ok","detail":"Play's highest known version code is 38.",\
        "track":"internal","latestVersionCode":38,"latestVersionName":"2.0.9",\
        "tracks":[{"track":"internal","versionCode":38,"versionName":"2.0.9"}]},\
        "ios":{"status":"ok","detail":"TestFlight's newest upload is build 41.",\
        "latestAppStoreVersion":"2.0.8",\
        "builds":[{"version":"2.1.0","build":41,"state":"PROCESSING"}]}}
        """)

        XCTAssertEqual(response.protocolVersion, 1)
        XCTAssertEqual(response.project, "example_app")
        XCTAssertEqual(response.checkedAt, "2026-08-08T09:41:07.412Z")
        XCTAssertEqual(response.android?.status, .ok)
        XCTAssertEqual(response.android?.track, "internal")
        XCTAssertEqual(response.android?.latestVersionCode, 38)
        XCTAssertEqual(response.android?.tracks, [
            AndroidTrackVersion(track: "internal", versionCode: 38, versionName: "2.0.9"),
        ])
        XCTAssertEqual(response.ios?.status, .ok)
        XCTAssertEqual(response.ios?.latestAppStoreVersion, "2.0.8")
        XCTAssertEqual(response.ios?.builds.first?.build, 41)
        XCTAssertNil(response.error)
    }

    func testEveryDocumentedStatusDecodesOnBothPlatforms() throws {
        for raw in ["ok", "unconfigured", "no_credentials", "unavailable"] {
            let response = try Self.decodeStoreVersions(Self.storeVersionsJSON(
                android: #"{"status":"\#(raw)","detail":"d","track":null,"latestVersionCode":null,"latestVersionName":null,"tracks":[]}"#,
                ios: #"{"status":"\#(raw)","detail":"d","latestAppStoreVersion":null,"builds":[]}"#
            ))

            let expected = StoreQueryStatus(rawValue: raw)
            XCTAssertEqual(response.android?.status, expected, raw)
            XCTAssertEqual(response.ios?.status, expected, raw)
        }
    }

    func testAnUnknownStatusSpellingFailsClosedToUnavailable() throws {
        // The CLI fails closed the same way. A status this app has never heard of is
        // not evidence about what a store holds, so it must not decode as one.
        let response = try Self.decodeStoreVersions(Self.storeVersionsJSON(
            android: #"{"status":"partially_ok","detail":"d","track":null,"latestVersionCode":38,"latestVersionName":null,"tracks":[]}"#,
            ios: #"{"status":"","detail":"d","latestAppStoreVersion":null,"builds":[]}"#
        ))

        XCTAssertEqual(response.android?.status, .unavailable)
        XCTAssertEqual(response.ios?.status, .unavailable)
        XCTAssertTrue(response.android?.status.isFailure == true)
    }

    func testNullNumbersDecodeAsUnknownRatherThanZero() throws {
        let response = try Self.decodeStoreVersions(Self.storeVersionsJSON(
            android: #"{"status":"ok","detail":"d","track":"internal","latestVersionCode":null,"latestVersionName":null,"tracks":[]}"#,
            ios: #"{"status":"ok","detail":"d","latestAppStoreVersion":null,"builds":[{"version":"1.2.3","build":null,"state":"PROCESSING"}]}"#
        ))

        XCTAssertNil(response.android?.latestVersionCode)
        XCTAssertNotEqual(response.android?.latestVersionCode, 0)
        XCTAssertNil(response.ios?.builds.first?.build)
        XCTAssertNil(response.ios?.highestNumberedBuild)
    }

    func testAFailureDocumentCarriesNoPlatformAtAll() throws {
        let response = try Self.decodeStoreVersions("""
        {"protocolVersion":1,"cliVersion":"0.7.0",\
        "error":{"code":"store_query_timed_out","message":"The lane was stopped."}}
        """)

        // The envelope is the guarantee that a client can never read "the store holds
        // nothing" out of a run that never reached a store.
        XCTAssertNil(response.android)
        XCTAssertNil(response.ios)
        XCTAssertEqual(response.error?.code, "store_query_timed_out")
    }

    func testEveryAndroidStatusRendersAsItsOwnKindOfRow() {
        let known = StoreVersionRow(android: Self.androidVersions(status: .ok, latestVersionCode: 38, latestVersionName: "2.0.9"))
        XCTAssertEqual(known.kind, .known)
        XCTAssertEqual(known.latest, 38)
        XCTAssertTrue(known.headline.contains("38"))

        let empty = StoreVersionRow(android: Self.androidVersions(status: .ok, latestVersionCode: nil))
        XCTAssertEqual(empty.kind, .empty)
        XCTAssertNil(empty.latest)

        let unconfigured = StoreVersionRow(android: Self.androidVersions(status: .unconfigured))
        XCTAssertEqual(unconfigured.kind, .notConfigured)

        let noCredentials = StoreVersionRow(android: Self.androidVersions(status: .noCredentials))
        XCTAssertEqual(noCredentials.kind, .failed)

        let unavailable = StoreVersionRow(android: Self.androidVersions(status: .unavailable))
        XCTAssertEqual(unavailable.kind, .failed)

        // Four statuses, four distinct sentences. The detail sentence the CLI wrote is
        // always carried through, whatever the status.
        let headlines = Set([known, empty, unconfigured, noCredentials, unavailable].map(\.headline))
        XCTAssertEqual(headlines.count, 5)
        XCTAssertEqual(unavailable.detail, "what the CLI said")
    }

    func testEveryIOSStatusRendersAsItsOwnKindOfRow() {
        let known = StoreVersionRow(ios: Self.iosVersions(
            status: .ok,
            latestAppStoreVersion: "2.0.8",
            builds: [IOSStoreBuild(version: "2.1.0", build: 41, state: "PROCESSING")]
        ))
        XCTAssertEqual(known.kind, .known)
        XCTAssertEqual(known.latest, 41)
        XCTAssertEqual(known.supplement, "App Store: 2.0.8")

        let empty = StoreVersionRow(ios: Self.iosVersions(status: .ok, builds: []))
        XCTAssertEqual(empty.kind, .empty)
        XCTAssertNil(empty.latest)
        // A store that answered and has never shipped still reports the App Store fact.
        XCTAssertEqual(empty.supplement, "App Store: never released")

        XCTAssertEqual(StoreVersionRow(ios: Self.iosVersions(status: .unconfigured)).kind, .notConfigured)
        XCTAssertEqual(StoreVersionRow(ios: Self.iosVersions(status: .noCredentials)).kind, .failed)
        XCTAssertEqual(StoreVersionRow(ios: Self.iosVersions(status: .unavailable)).kind, .failed)
    }

    func testAStoreThatNeverAnsweredIsNeverRenderedAsAStoreHoldingNothing() {
        // The defect this whole report exists to prevent: telling a user with a shipped
        // app that the store is empty, when the truth is that nobody asked it.
        let emptyAndroid = StoreVersionRow(android: Self.androidVersions(status: .ok, latestVersionCode: nil))
        let emptyIOS = StoreVersionRow(ios: Self.iosVersions(status: .ok, builds: []))

        for failing in [StoreQueryStatus.unavailable, .noCredentials] {
            let android = StoreVersionRow(android: Self.androidVersions(status: failing))
            let ios = StoreVersionRow(ios: Self.iosVersions(status: failing))

            for row in [android, ios] {
                XCTAssertEqual(row.kind, .failed, "\(failing)")
                XCTAssertNotEqual(row.kind, .empty, "\(failing)")
                // Nothing was learned, so nothing may be offered and nothing may be
                // accused of being taken.
                XCTAssertNil(row.latest, "\(failing)")
                XCTAssertNil(row.suggestion, "\(failing)")
                XCTAssertFalse(row.conflicts(with: "1"), "\(failing)")
                XCTAssertFalse(row.conflicts(with: "9999"), "\(failing)")
            }
            XCTAssertNotEqual(android.headline, emptyAndroid.headline, "\(failing)")
            XCTAssertNotEqual(ios.headline, emptyIOS.headline, "\(failing)")
            // A failed check must not borrow the empty store's supplementary facts either.
            XCTAssertNil(android.supplement, "\(failing)")
            XCTAssertNil(ios.supplement, "\(failing)")
        }
    }

    func testAHalfAnsweredIOSCheckShowsTheHalfItGotWithoutClaimingItIsTheLatest() {
        // App Store Connect is two reads and can serve one and refuse the other. The
        // status is unavailable for the whole platform, and the half that answered is
        // still populated.
        let partial = StoreVersionRow(ios: Self.iosVersions(
            status: .unavailable,
            latestAppStoreVersion: "2.0.8",
            builds: [IOSStoreBuild(version: "2.1.0", build: 41, state: "VALID")]
        ))

        XCTAssertEqual(partial.kind, .failed)
        XCTAssertEqual(partial.supplement?.contains("41"), true)
        XCTAssertEqual(partial.supplement?.contains("2.0.8"), true)
        // The half that failed could hold a higher number, so nothing here becomes a
        // latest: no suggestion, and no number is accused of being taken.
        XCTAssertNil(partial.latest)
        XCTAssertNil(partial.suggestion)
        XCTAssertFalse(partial.conflicts(with: "41"))
        // And it is still visibly not an answer, nor an empty store.
        let total = StoreVersionRow(ios: Self.iosVersions(status: .unavailable))
        let empty = StoreVersionRow(ios: Self.iosVersions(status: .ok, builds: []))
        XCTAssertNotEqual(partial.headline, empty.headline)
        XCTAssertNotEqual(partial.headline, total.headline)
        XCTAssertNil(total.supplement)
    }

    func testHighestNumberedBuildClearsEveryNumberOnFileNotJustTheNewestUpload() {
        // Apple scopes build numbers to the version string, so the newest upload is not
        // necessarily the highest number, and entries with no number clear nothing.
        let versions = Self.iosVersions(status: .ok, builds: [
            IOSStoreBuild(version: "2.1.0", build: 3, state: "PROCESSING"),
            IOSStoreBuild(version: "2.0.0", build: 41, state: "VALID"),
            IOSStoreBuild(version: "1.9.0", build: nil, state: "VALID"),
        ])

        XCTAssertEqual(versions.highestNumberedBuild?.build, 41)
        XCTAssertEqual(StoreVersionRow(ios: versions).latest, 41)
        XCTAssertEqual(StoreVersionRow(ios: versions).suggestion, 42)
    }

    func testASuggestionExistsOnlyWhereARealLatestValueDoes() {
        XCTAssertEqual(
            StoreVersionRow(android: Self.androidVersions(status: .ok, latestVersionCode: 38)).suggestion,
            39
        )
        // Every other row offers nothing, because there is no fact to compute from and
        // the CLI deliberately sends no next-version field for the app to fall back on.
        XCTAssertNil(StoreVersionRow(android: Self.androidVersions(status: .ok, latestVersionCode: nil)).suggestion)
        XCTAssertNil(StoreVersionRow(android: Self.androidVersions(status: .unconfigured)).suggestion)
        XCTAssertNil(StoreVersionRow(android: Self.androidVersions(status: .noCredentials)).suggestion)
        XCTAssertNil(StoreVersionRow(android: Self.androidVersions(status: .unavailable)).suggestion)
        XCTAssertNil(StoreVersionRow(ios: Self.iosVersions(status: .ok, builds: [])).suggestion)
    }

    func testAConflictIsFlaggedOnlyAgainstANumberTheStoreActuallyHolds() {
        let known = StoreVersionRow(android: Self.androidVersions(status: .ok, latestVersionCode: 38))

        XCTAssertTrue(known.conflicts(with: "38"))
        XCTAssertTrue(known.conflicts(with: "12"))
        XCTAssertFalse(known.conflicts(with: "39"))
        XCTAssertFalse(known.conflicts(with: ""))
        XCTAssertFalse(known.conflicts(with: "not a number"))
    }

    @MainActor
    func testSelectingAProjectNeverQueriesTheStores() async throws {
        // `api store-versions` reaches two stores behind fastlane and routinely takes
        // minutes. It runs when the user asks and at no other time.
        let counter = CallCounter()
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
            Self.projectSummary(id: "banana", name: "Banana"),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse()
        fake.storeVersionsCalls = counter
        let model = AppModel(clientFactory: { _ in fake })

        try await model.reloadProjects()
        model.selectedProjectID = "banana"
        model.selectedProjectID = "apple"
        try await model.reloadProjects()

        XCTAssertEqual(counter.recorded, [])
        XCTAssertNil(model.storeVersions)
        XCTAssertFalse(model.isCheckingStores)
    }

    @MainActor
    func testCheckingStoresPublishesTheReportWithoutTouchingAnyField() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", buildName: "2.1.0", buildNumber: 4, platforms: [.android, .ios]),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse(
            android: Self.androidVersions(status: .ok, latestVersionCode: 38, latestVersionName: "2.0.9"),
            ios: Self.iosVersions(
                status: .ok,
                latestAppStoreVersion: "2.0.8",
                builds: [IOSStoreBuild(version: "2.1.0", build: 41, state: "PROCESSING")]
            )
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()

        model.checkStoreVersions()
        try await Self.settle(while: { model.isCheckingStores })

        XCTAssertEqual(model.storeRow(for: .android)?.latest, 38)
        XCTAssertEqual(model.storeRow(for: .ios)?.latest, 41)
        XCTAssertNil(model.storeCheckNote)
        // Nothing is pre-filled from a store value. The seeded pubspec numbers are
        // still exactly what they were before the check.
        XCTAssertEqual(model.androidBuildNumber, "4")
        XCTAssertEqual(model.iosBuildNumber, "4")
    }

    @MainActor
    func testTheSuggestionReachesAFieldOnlyOnClickAndLeavesItEditable() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", buildName: "2.1.0", buildNumber: 4, platforms: [.android, .ios]),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse(
            android: Self.androidVersions(status: .ok, latestVersionCode: 38),
            ios: Self.iosVersions(status: .unavailable)
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.checkStoreVersions()
        try await Self.settle(while: { model.isCheckingStores })

        XCTAssertEqual(model.androidBuildNumber, "4")

        model.applySuggestedBuildNumber(for: .android)
        XCTAssertEqual(model.androidBuildNumber, "39")

        // Still an ordinary editable field afterwards; the app chose nothing that a
        // build could run on without the user seeing it.
        model.setBuildNumber("77", for: .android)
        XCTAssertEqual(model.androidBuildNumber, "77")

        // iOS learned nothing, so its button does not exist and asking anyway is inert.
        XCTAssertNil(model.storeRow(for: .ios)?.suggestion)
        model.applySuggestedBuildNumber(for: .ios)
        XCTAssertEqual(model.iosBuildNumber, "4")
    }

    @MainActor
    func testAStoreCheckFailureIsReportedWithoutInventingAnEmptyStore() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse(
            error: APIErrorPayload(code: "store_query_timed_out", message: "The lane was stopped.")
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()

        model.checkStoreVersions()
        try await Self.settle(while: { model.isCheckingStores })

        XCTAssertNil(model.storeVersions)
        XCTAssertNil(model.storeRow(for: .android))
        XCTAssertNil(model.storeRow(for: .ios))
        XCTAssertEqual(model.storeCheckNote, "The lane was stopped.")
    }

    @MainActor
    func testCancellingAStoreCheckSaysSoAndDebouncesTheRetry() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse()
        fake.storeVersionsDelaySeconds = 30
        let model = AppModel(clientFactory: { _ in fake })
        model.storeCheckRetryDelaySeconds = 0.1
        try await model.reloadProjects()

        model.checkStoreVersions()
        XCTAssertTrue(model.isCheckingStores)
        XCTAssertNotNil(model.storeCheckNote)
        XCTAssertFalse(model.canCheckStoreVersions)

        model.cancelStoreCheck()
        try await Self.settle(while: { model.isCheckingStores })

        XCTAssertNil(model.storeVersions)
        XCTAssertEqual(model.storeCheckNote?.contains("cancelled") ?? false, true)
        // Keep a brief debounce, including compatibility with older protocol-v1 CLIs.
        XCTAssertTrue(model.isStoreCheckCoolingDown)
        XCTAssertFalse(model.canCheckStoreVersions)

        try await Self.settle(while: { model.isStoreCheckCoolingDown })
        XCTAssertTrue(model.canCheckStoreVersions)
    }

    @MainActor
    func testChangingProjectDropsTheReportThatBelongedToTheOldOne() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
            Self.projectSummary(id: "banana", name: "Banana", platforms: [.android, .ios]),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse(
            android: Self.androidVersions(status: .ok, latestVersionCode: 38)
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.checkStoreVersions()
        try await Self.settle(while: { model.isCheckingStores })
        XCTAssertNotNil(model.storeRow(for: .android))
        model.splitVersionName = true
        model.iosBuildName = "2.1.1"

        model.selectedProjectID = "banana"

        // Another project is another release: its report, its per-platform name
        // override, and its outcome all belong to the project that just went away.
        XCTAssertNil(model.storeVersions)
        XCTAssertNil(model.storeRow(for: .android))
        XCTAssertNil(model.storeCheckNote)
        XCTAssertFalse(model.splitVersionName)
        XCTAssertEqual(model.iosBuildName, "")
        XCTAssertEqual(model.releaseLegs, [])
    }

    @MainActor
    func testSplitVersionNameTogglePersistsAcrossARelaunch() async throws {
        let projects = Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ])
        let firstLaunch = AppModel(clientFactory: { _ in FakeFRKClient(projectsResponse: projects) })
        try await firstLaunch.reloadProjects()
        firstLaunch.selectedProjectID = "apple"
        firstLaunch.splitVersionName = true

        // A relaunch is a fresh AppModel reading the same on-disk preferences, not the
        // same in-memory object, so constructing a second instance is the faithful way
        // to test that this survives - asserting on the first instance would not.
        let secondLaunch = AppModel(clientFactory: { _ in FakeFRKClient(projectsResponse: projects) })
        try await secondLaunch.reloadProjects()
        secondLaunch.selectedProjectID = "apple"

        XCTAssertTrue(secondLaunch.splitVersionName)
    }

    @MainActor
    func testStoreVersionsReportSurvivesARelaunchWithoutQueryingTheStoresAgain() async throws {
        let projects = Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ])
        var firstFake = FakeFRKClient(projectsResponse: projects)
        firstFake.storeVersionsResponse = Self.storeVersionsResponse(
            android: Self.androidVersions(status: .ok, latestVersionCode: 56, latestVersionName: "1.5.6")
        )
        let firstLaunch = AppModel(clientFactory: { _ in firstFake })
        try await firstLaunch.reloadProjects()
        firstLaunch.selectedProjectID = "apple"
        firstLaunch.checkStoreVersions()
        try await Self.settle(while: { firstLaunch.isCheckingStores })
        XCTAssertEqual(firstLaunch.storeRow(for: .android)?.latest, 56)

        // The second instance's fake carries no response at all. If selecting the
        // project queried the network here, `unwrap` would throw and the row would come
        // back nil, so the assertions below only pass by way of the cache.
        let secondFake = FakeFRKClient(projectsResponse: projects)
        let secondLaunch = AppModel(clientFactory: { _ in secondFake })
        try await secondLaunch.reloadProjects()
        secondLaunch.selectedProjectID = "apple"

        XCTAssertEqual(secondLaunch.storeRow(for: .android)?.latest, 56)
        XCTAssertTrue(secondFake.storeVersionsCalls.recorded.isEmpty)
        XCTAssertNotNil(secondLaunch.storeVersionsCheckedAtDisplay)
    }

    @MainActor
    func testLoadBuildArgsFetchesTheReportAndStoresIt() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ]))
        fake.buildArgsResponse = Self.buildArgsResponse(
            shared: ["--dart-define=COMMON=1"],
            android: Self.platformBuildArgs(own: ["--dart-define=A=1"], effective: ["--dart-define=COMMON=1", "--dart-define=A=1"]),
            ios: Self.platformBuildArgs()
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.selectedProjectID = "apple"

        await model.loadBuildArgs(for: "apple")

        XCTAssertEqual(["--dart-define=COMMON=1"], model.buildArgs?.shared)
        XCTAssertEqual(["--dart-define=A=1"], model.buildArgs?.android.own)
        XCTAssertEqual(["--dart-define=COMMON=1", "--dart-define=A=1"], model.buildArgs?.android.effective)
        XCTAssertTrue(model.buildArgs?.ios.own.isEmpty ?? false)
        XCTAssertNil(model.buildArgsError)
        XCTAssertEqual(["apple"], fake.buildArgsCalls.recorded)
    }

    @MainActor
    func testChangingProjectDropsTheBuildArgsThatBelongedToTheOldOne() async throws {
        // Unlike the store report and the per-platform toggle, build args are not
        // cached across a project switch: showing project A's flags labeled as
        // project B's, even briefly, would be actively misleading about what B's
        // next build actually runs.
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
            Self.projectSummary(id: "banana", name: "Banana", platforms: [.android, .ios]),
        ]))
        fake.buildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--dart-define=A=1"]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.selectedProjectID = "apple"
        await model.loadBuildArgs(for: "apple")
        XCTAssertNotNil(model.buildArgs)

        model.selectedProjectID = "banana"

        XCTAssertNil(model.buildArgs)
    }

    @MainActor
    func testSetBuildArgsWritesAndUpdatesTheModelFromTheResponse() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ]))
        fake.buildArgsResponse = Self.buildArgsResponse()
        fake.setBuildArgsResponse = Self.buildArgsResponse(
            android: Self.platformBuildArgs(own: ["--dart-define=A=1", "--dart-define=A=2"])
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.selectedProjectID = "apple"
        await model.loadBuildArgs(for: "apple")

        await model.setBuildArgs(for: "apple", platform: .android, args: ["--dart-define=A=1", "--dart-define=A=2"])

        // The model reflects the response the write returned, not a locally
        // assembled guess at what the new state should be.
        XCTAssertEqual(["--dart-define=A=1", "--dart-define=A=2"], model.buildArgs?.android.own)
        XCTAssertEqual(["apple/android/--dart-define=A=1|--dart-define=A=2"], fake.setBuildArgsCalls.recorded)
        XCTAssertNil(model.buildArgsError)
        XCTAssertFalse(model.isSavingBuildArgs)
    }

    @MainActor
    func testSetBuildArgsFailureKeepsThePreviousBuildArgsAndSurfacesAnError() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ]))
        fake.buildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--dart-define=A=1"]))
        // setBuildArgsResponse left nil: the fake throws FakeFRKClient.failureMessage.
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.selectedProjectID = "apple"
        await model.loadBuildArgs(for: "apple")

        await model.setBuildArgs(for: "apple", platform: .android, args: ["--dart-define=A=1", "--dart-define=A=2"])

        // A failed write must not make the UI show a value that was never saved.
        XCTAssertEqual(["--dart-define=A=1"], model.buildArgs?.android.own)
        XCTAssertNotNil(model.buildArgsError)
    }

    @MainActor
    func testSetTrackReplacesTheMatchingProjectFromTheResponseAndLeavesOthersAlone() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", track: "internal"),
            Self.projectSummary(id: "pear", name: "pear", track: "internal"),
        ]))
        fake.setTrackResponse = ProjectDocument(
            protocolVersion: 1, cliVersion: "0.8.0",
            project: Self.projectSummary(id: "apple", name: "apple", track: "beta")
        )
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()

        await model.setTrack(for: "apple", track: "beta")

        // Read back from the response, not assembled locally.
        XCTAssertEqual("beta", model.projects.first { $0.id == "apple" }?.android?.track)
        XCTAssertEqual("internal", model.projects.first { $0.id == "pear" }?.android?.track)
        XCTAssertEqual(["apple/beta"], fake.setTrackCalls.recorded)
        XCTAssertFalse(model.isSavingTrack)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSetTrackFailureLeavesTheProjectUnchangedAndSurfacesAnError() async throws {
        let fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", track: "internal"),
        ]))
        // setTrackResponse left nil: the fake throws FakeFRKClient.failureMessage.
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()

        await model.setTrack(for: "apple", track: "beta")

        // A failed write must not make the UI show a track that was never saved.
        XCTAssertEqual("internal", model.projects.first { $0.id == "apple" }?.android?.track)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isSavingTrack)
    }

    @MainActor
    func testLoadBuildArgsFailureClearsAnyPreviousBuildArgsAndSurfacesAnError() async throws {
        // Unlike a failed write, a failed LOAD has nothing trustworthy to keep: the
        // value on screen might belong to a config that no longer parses, so it is
        // cleared rather than left stale and unlabeled as such.
        let fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
        ]))
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        model.selectedProjectID = "apple"

        await model.loadBuildArgs(for: "apple")

        XCTAssertNil(model.buildArgs)
        XCTAssertNotNil(model.buildArgsError)
    }

    @MainActor
    func testBothBuildNumbersSeedFromPubspecAndNeitherSeedsFromAStore() async throws {
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple", buildName: "2.1.0", buildNumber: 4, platforms: [.android, .ios]),
        ]))
        fake.storeVersionsResponse = Self.storeVersionsResponse(
            android: Self.androidVersions(status: .ok, latestVersionCode: 38),
            ios: Self.iosVersions(
                status: .ok,
                builds: [IOSStoreBuild(version: "2.1.0", build: 41, state: "VALID")]
            )
        )
        let model = AppModel(clientFactory: { _ in fake })

        try await model.reloadProjects()

        // pubspec holds one `+N` and it seeds both, because it is the user's own file
        // and what the build would use with no flag at all. The two therefore start
        // equal even though the stores have already drifted.
        XCTAssertEqual(model.sharedBuildName, "2.1.0")
        XCTAssertEqual(model.androidBuildNumber, "4")
        XCTAssertEqual(model.iosBuildNumber, "4")

        model.checkStoreVersions()
        try await Self.settle(while: { model.isCheckingStores })

        // The store says the fields are stale, and says nothing more. Writing 39 and 42
        // in here would be the app choosing the next version.
        XCTAssertEqual(model.androidBuildNumber, "4")
        XCTAssertEqual(model.iosBuildNumber, "4")
        XCTAssertEqual(model.storeRow(for: .android)?.conflicts(with: "4"), true)
        XCTAssertEqual(model.storeRow(for: .ios)?.conflicts(with: "4"), true)
    }

    @MainActor
    func testReleasingBothStoresIssuesOneInvocationPerPlatformWithItsOwnVersions() async throws {
        // `--platform all` sends one version pair to both stores, which is exactly what
        // divergent build numbers cannot use.
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("frk-argv-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let stub = try Self.stubCLI("""
        #!/bin/sh
        printf '%s\\n' "$*" >> \(log.path)
        printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"finished",\
        "timestamp":"2026-01-01T00:00:00Z","success":true,"exitCode":0,"durationSeconds":1.0}\\n'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(projectsResponse: Self.projectsResponse([
                Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
            ]))
        })
        model.cliPath = stub.path
        try await model.reloadProjects()
        model.sharedBuildName = "2.1.0"
        model.splitVersionName = true
        model.iosBuildName = "2.1.1"
        model.androidBuildNumber = "39"
        model.iosBuildNumber = "42"

        model.startRelease(project: "apple", platforms: [.android, .ios])
        try await Self.settle(while: { model.isRunning || model.releaseLegs.contains { !$0.isFinished } })

        XCTAssertEqual(
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init),
            [
                "api run release apple --platform android --build-name 2.1.0 --build-number 39",
                "api run release apple --platform ios --build-name 2.1.1 --build-number 42",
            ]
        )
        XCTAssertEqual(model.releaseLegs.map(\.state), [.succeeded, .succeeded])
        XCTAssertEqual(model.releaseLegs.map(\.buildNumber), ["39", "42"])
        XCTAssertEqual(model.releaseLegs.map(\.buildName), ["2.1.0", "2.1.1"])
    }

    @MainActor
    func testAFailedFirstPlatformIsReportedPerPlatformAndStopsTheSecond() async throws {
        // `frk release all` is not atomic and neither is this. One half can land while
        // the other never starts, and the report has to say which half that was.
        let stub = try Self.stubCLI("""
        #!/bin/sh
        printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"error",\
        "timestamp":"2026-01-01T00:00:00Z","message":"Play rejected the bundle."}\\n'
        printf '{"protocolVersion":1,"cliVersion":"0.7.0","type":"finished",\
        "timestamp":"2026-01-01T00:00:00Z","success":false,"exitCode":1,"durationSeconds":1.0}\\n'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

        let model = AppModel(clientFactory: { _ in
            FakeFRKClient(projectsResponse: Self.projectsResponse([
                Self.projectSummary(id: "apple", name: "apple", platforms: [.android, .ios]),
            ]))
        })
        model.cliPath = stub.path
        try await model.reloadProjects()
        model.sharedBuildName = "2.1.0"
        model.androidBuildNumber = "39"
        model.iosBuildNumber = "42"

        model.startRelease(project: "apple", platforms: [.android, .ios])
        try await Self.settle(while: { model.isRunning || model.releaseLegs.contains { !$0.isFinished } })

        XCTAssertEqual(model.releaseLegs.map(\.platform), [.android, .ios])
        XCTAssertEqual(model.releaseLegs.map(\.state), [.failed, .skipped])
        // The numbers each half would have used are still named, so the summary says
        // what landed and what did not on its own terms.
        XCTAssertEqual(model.releaseLegs.map(\.buildNumber), ["39", "42"])
        XCTAssertEqual(model.releaseLegs.last?.summary, "Not started, because an earlier platform did not finish")
    }

    @MainActor
    func testTasksFromAnOldViewCannotStartRequestsForTheNewSelection() async {
        let fake = FakeFRKClient()
        let model = AppModel(clientFactory: { _ in fake })
        model.selectedProjectID = "banana"
        await model.loadBuildArgs(for: "apple")
        await model.setBuildArgs(for: "apple", platform: .android, args: ["--old"])
        await model.loadSetupStatus(for: "apple")
        XCTAssertTrue(fake.buildArgsCalls.recorded.isEmpty)
        XCTAssertTrue(fake.setBuildArgsCalls.recorded.isEmpty)
        XCTAssertTrue(fake.setupStatusCalls.recorded.isEmpty)
        XCTAssertNil(model.buildArgsError)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testLateBuildArgsResponseCannotReplaceTheNewProjectsFlags() async throws {
        let gate = ResponseGate()
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple"),
            Self.projectSummary(id: "banana", name: "banana")
        ]))
        fake.buildArgsGate = gate
        fake.buildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--old"]))
        let calls = fake.buildArgsCalls
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        let pending = Task { await model.loadBuildArgs(for: "apple") }
        try await Self.settle(while: { calls.recorded.isEmpty })
        model.selectedProjectID = "banana"
        fake.buildArgsGate = nil
        fake.buildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--current"]))
        await model.loadBuildArgs(for: "banana")
        await gate.open()
        await pending.value
        XCTAssertEqual(["--current"], model.buildArgs?.android.own)
        XCTAssertNil(model.buildArgsError)
        XCTAssertFalse(model.isLoadingBuildArgs)
    }

    @MainActor
    func testLateBuildArgsFailureCannotClearTheNewProjectsFlags() async throws {
        let gate = ResponseGate()
        var fake = FakeFRKClient(projectsResponse: Self.projectsResponse([
            Self.projectSummary(id: "apple", name: "apple"),
            Self.projectSummary(id: "banana", name: "banana")
        ]))
        fake.buildArgsGate = gate
        let calls = fake.buildArgsCalls
        let model = AppModel(clientFactory: { _ in fake })
        try await model.reloadProjects()
        let pending = Task { await model.loadBuildArgs(for: "apple") }
        try await Self.settle(while: { calls.recorded.isEmpty })
        model.selectedProjectID = "banana"
        fake.buildArgsGate = nil
        fake.buildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--current"]))
        await model.loadBuildArgs(for: "banana")
        await gate.open()
        await pending.value
        XCTAssertEqual(["--current"], model.buildArgs?.android.own)
        XCTAssertNil(model.buildArgsError)
    }

    @MainActor
    func testReadStartedBeforeSaveCannotRestoreOldFlags() async throws {
        let gate = ResponseGate()
        var fake = FakeFRKClient()
        fake.buildArgsGate = gate
        fake.buildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--old"]))
        fake.setBuildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--saved"]))
        let model = AppModel(clientFactory: { _ in fake })
        let pending = Task { await model.loadBuildArgs(for: "apple") }
        try await Self.settle(while: { fake.buildArgsCalls.recorded.isEmpty })
        await model.setBuildArgs(for: "apple", platform: .android, args: ["--saved"])
        await gate.open()
        await pending.value
        XCTAssertEqual(["--saved"], model.buildArgs?.android.own)
        XCTAssertFalse(model.isLoadingBuildArgs)
        XCTAssertFalse(model.isSavingBuildArgs)
    }

    @MainActor
    func testLateSaveCannotPopulateAnotherProjectsFlags() async throws {
        let gate = ResponseGate()
        var fake = FakeFRKClient()
        fake.setBuildArgsGate = gate
        fake.setBuildArgsResponse = Self.buildArgsResponse(android: Self.platformBuildArgs(own: ["--saved"]))
        let model = AppModel(clientFactory: { _ in fake })
        model.selectedProjectID = "apple"
        let pending = Task { await model.setBuildArgs(for: "apple", platform: .android, args: ["--saved"]) }
        try await Self.settle(while: { fake.setBuildArgsCalls.recorded.isEmpty })
        model.selectedProjectID = "banana"
        await gate.open()
        await pending.value
        XCTAssertNil(model.buildArgs)
        XCTAssertNil(model.buildArgsError)
        XCTAssertFalse(model.isSavingBuildArgs)
    }

    @MainActor
    func testDismissedSetupIgnoresAnInFlightResponse() async throws {
        let gate = ResponseGate()
        var fake = FakeFRKClient(setupStatusResponse: Self.setupStatusResponse(projectId: "apple"))
        fake.setupStatusGate = gate
        let model = AppModel(clientFactory: { _ in fake })
        let pending = Task { await model.loadSetupStatus(for: "apple") }
        try await Self.settle(while: { fake.setupStatusCalls.recorded.isEmpty })
        model.clearSetupStatus()
        await gate.open()
        await pending.value
        XCTAssertNil(model.setupStatus)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingSetup)
    }

    @MainActor
    func testOlderReadCannotStopTheCurrentLoadingIndicator() async throws {
        let firstGate = ResponseGate()
        let secondGate = ResponseGate()
        var fake = FakeFRKClient()
        fake.buildArgsGate = firstGate
        fake.buildArgsResponse = Self.buildArgsResponse()
        let calls = fake.buildArgsCalls
        let model = AppModel(clientFactory: { _ in fake })
        let first = Task { await model.loadBuildArgs(for: "apple") }
        try await Self.settle(while: { calls.recorded.count < 1 })
        fake.buildArgsGate = secondGate
        let second = Task { await model.loadBuildArgs(for: "apple") }
        try await Self.settle(while: { calls.recorded.count < 2 })
        await firstGate.open()
        await first.value
        XCTAssertTrue(model.isLoadingBuildArgs)
        XCTAssertNil(model.buildArgs)
        await secondGate.open()
        await second.value
        XCTAssertFalse(model.isLoadingBuildArgs)
        XCTAssertNotNil(model.buildArgs)
    }

    /// Explicit release keeps response ordering deterministic without timing races.
    private actor ResponseGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    // Stands in for the CLI so AppModel's error branches can actually run. A nil
    // response means "this call fails", which is how every throwing path is reached.
    private struct FakeFRKClient: FRKClientProtocol {
        static let failureMessage = "FRK could not be reached."

        var capabilitiesResponse: CapabilitiesResponse?
        var projectsResponse: ProjectsResponse?
        var setupStatusResponse: SetupStatusResponse?
        var credentialsResponse: CredentialsResponse?
        var storeVersionsResponse: StoreVersionsResponse?
        /// Makes the store query slow enough to observe in flight, and cancellable:
        /// Task.sleep is what turns a cancelled task into a CancellationError here,
        /// exactly as terminating the real `frk` child does.
        var storeVersionsDelaySeconds: Double = 0
        /// Counts store queries so a test can prove one never happened.
        var storeVersionsCalls = CallCounter()
        var buildArgsGate: ResponseGate?
        var setBuildArgsGate: ResponseGate?
        var setupStatusGate: ResponseGate?
        var setupStatusCalls = CallCounter()
        var buildArgsResponse: BuildArgsResponse?
        var setBuildArgsResponse: BuildArgsResponse?
        var buildArgsCalls = CallCounter()
        /// Records "<projectID>/<platform>/<arg1>|<arg2>..." per call, so a test can
        /// assert both which platform was written and exactly what was sent.
        var setBuildArgsCalls = CallCounter()
        var setTrackResponse: ProjectDocument?
        /// Records "<projectID>/<track>" per call.
        var setTrackCalls = CallCounter()

        func capabilities() async throws -> CapabilitiesResponse {
            try Self.unwrap(capabilitiesResponse)
        }

        func storeVersions(_ id: String) async throws -> StoreVersionsResponse {
            storeVersionsCalls.record(id)
            if storeVersionsDelaySeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(storeVersionsDelaySeconds * 1_000_000_000))
            }
            return try Self.unwrap(storeVersionsResponse)
        }

        func buildArgs(_ id: String) async throws -> BuildArgsResponse {
            buildArgsCalls.record(id)
            await buildArgsGate?.wait()
            return try Self.unwrap(buildArgsResponse)
        }

        func setBuildArgs(_ id: String, platform: PlatformKind, args: [String]) async throws -> BuildArgsResponse {
            setBuildArgsCalls.record("\(id)/\(platform.rawValue)/\(args.joined(separator: "|"))")
            await setBuildArgsGate?.wait()
            return try Self.unwrap(setBuildArgsResponse)
        }

        func setTrack(_ id: String, track: String) async throws -> ProjectDocument {
            setTrackCalls.record("\(id)/\(track)")
            return try Self.unwrap(setTrackResponse)
        }

        func projects() async throws -> ProjectsResponse {
            try Self.unwrap(projectsResponse)
        }

        func setupStatus(_ id: String) async throws -> SetupStatusResponse {
            setupStatusCalls.record(id)
            await setupStatusGate?.wait()
            return try Self.unwrap(setupStatusResponse)
        }

        func credentials() async throws -> CredentialsResponse {
            try Self.unwrap(credentialsResponse)
        }

        func configureGooglePlay(file: URL, force: Bool) async throws -> CredentialsResponse {
            try Self.unwrap(credentialsResponse)
        }

        func configureAppStore(
            file: URL,
            keyID: String,
            issuerID: String,
            force: Bool
        ) async throws -> CredentialsResponse {
            try Self.unwrap(credentialsResponse)
        }

        private static func unwrap<Response>(_ response: Response?) throws -> Response {
            guard let response else { throw FRKClientError.apiError(failureMessage) }
            return response
        }
    }

    /// Shared tally the fake writes to and the test reads, so a copy of the value-type
    /// fake handed to `AppModel` still reports its calls back.
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []

        func record(_ argument: String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(argument)
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private func assertThrows(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        during operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected a thrown error described as \(message.debugDescription)", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }

    private static func capabilitiesResponse(credentialManagement: Bool) -> CapabilitiesResponse {
        CapabilitiesResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            minimumDesktopProtocol: 1,
            maximumDesktopProtocol: 1,
            capabilities: CapabilitiesResponse.Capabilities(
                projectDiscovery: true,
                streamingEvents: true,
                credentialManagement: credentialManagement,
                productionRelease: false,
                platforms: ["android", "ios"],
                actions: ["build"]
            )
        )
    }

    private static func projectsResponse(_ projects: [ProjectSummary]) -> ProjectsResponse {
        ProjectsResponse(protocolVersion: 1, cliVersion: "0.7.0", projects: projects)
    }

    private static func projectSummary(
        id: String,
        name: String,
        buildName: String? = nil,
        buildNumber: Int? = nil,
        platforms: [PlatformKind] = [.android],
        track: String = "internal",
        exists: Bool = true,
        onboarded: Bool = true
    ) -> ProjectSummary {
        ProjectSummary(
            id: id,
            name: name,
            path: "/tmp/\(id)",
            exists: exists,
            onboarded: onboarded,
            state: "ready",
            platforms: platforms,
            version: buildNumber.map { "\(buildName ?? "")+\($0)" },
            buildName: buildName,
            buildNumber: buildNumber,
            android: AndroidSummary(packageId: "org.example.\(id)", signingReady: true, track: track),
            ios: nil,
            artifacts: ArtifactSummary(androidAab: nil, iosIpa: nil),
            addedAt: nil
        )
    }

    private static func iosProject(signingReady: Bool?, profileReady: Bool) -> ProjectSummary {
        ProjectSummary(
            id: "example",
            name: "Example",
            path: "/tmp/example",
            exists: true,
            onboarded: true,
            state: "ready",
            platforms: [.ios],
            version: nil,
            buildName: nil,
            buildNumber: nil,
            android: nil,
            ios: IOSSummary(
                bundleId: "org.example.app",
                teamId: "ABCDE12345",
                profileReady: profileReady,
                profilePath: "/vault/profile.mobileprovision",
                distributionIdentityReady: nil,
                signingReady: signingReady
            ),
            artifacts: ArtifactSummary(androidAab: nil, iosIpa: nil),
            addedAt: nil
        )
    }

    private static func androidSetupStatus(
        propertiesComplete: Bool = true,
        keystoreExists: Bool = true,
        keystoreValidationStatus: String?
    ) -> AndroidSetupStatus {
        AndroidSetupStatus(
            configured: true,
            packageId: "org.example.app",
            projectPropertiesPath: "/app/android/key.properties",
            projectPropertiesExists: true,
            propertiesComplete: propertiesComplete,
            missingPropertiesFields: [],
            referencedKeystorePath: "/app/android/upload.jks",
            keystoreExists: keystoreExists,
            keystoreValidationStatus: keystoreValidationStatus,
            keystoreValidationDetail: nil,
            certificateSHA256: nil,
            gradleConfigured: true,
            gradleConfigurationPath: "/app/android/app/build.gradle.kts",
            gradleConfigurationDetail: nil,
            vaultPath: "/vault/org.example.app",
            vaultReady: true,
            projectLinked: true,
            gitTracked: false,
            propertiesGitIgnored: true,
            keystoreGitTracked: false,
            keystoreGitIgnored: true,
            gitSafe: true,
            signingReady: true
        )
    }

    private static func credentialsResponse(
        configuredAny: Bool,
        error: APIErrorPayload? = nil
    ) -> CredentialsResponse {
        CredentialsResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            vaultPath: "/vault",
            configuredAny: configuredAny,
            googlePlay: nil,
            appStoreConnect: nil,
            error: error
        )
    }

    private static func setupStatusResponse(
        projectId: String,
        error: APIErrorPayload? = nil
    ) -> SetupStatusResponse {
        SetupStatusResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            projectId: projectId,
            android: nil,
            ios: nil,
            error: error
        )
    }

    // MARK: - Store version helpers

    private static func decodeStoreVersions(_ json: String) throws -> StoreVersionsResponse {
        try JSONDecoder().decode(StoreVersionsResponse.self, from: Data(json.utf8))
    }

    private static func storeVersionsJSON(android: String, ios: String) -> String {
        """
        {"protocolVersion":1,"cliVersion":"0.7.0","project":"example_app",\
        "checkedAt":"2026-08-08T09:41:07.412Z","android":\(android),"ios":\(ios)}
        """
    }

    private static func androidVersions(
        status: StoreQueryStatus,
        track: String? = "internal",
        latestVersionCode: Int? = nil,
        latestVersionName: String? = nil,
        tracks: [AndroidTrackVersion] = []
    ) -> AndroidStoreVersions {
        AndroidStoreVersions(
            status: status,
            detail: "what the CLI said",
            track: track,
            latestVersionCode: latestVersionCode,
            latestVersionName: latestVersionName,
            tracks: tracks
        )
    }

    private static func iosVersions(
        status: StoreQueryStatus,
        latestAppStoreVersion: String? = nil,
        builds: [IOSStoreBuild] = []
    ) -> IOSStoreVersions {
        IOSStoreVersions(
            status: status,
            detail: "what the CLI said",
            latestAppStoreVersion: latestAppStoreVersion,
            builds: builds
        )
    }

    private static func storeVersionsResponse(
        android: AndroidStoreVersions? = nil,
        ios: IOSStoreVersions? = nil,
        error: APIErrorPayload? = nil
    ) -> StoreVersionsResponse {
        StoreVersionsResponse(
            protocolVersion: 1,
            cliVersion: "0.7.0",
            project: error == nil ? "apple" : nil,
            checkedAt: error == nil ? "2026-08-08T09:41:07.412Z" : nil,
            android: error == nil ? (android ?? androidVersions(status: .ok)) : nil,
            ios: error == nil ? (ios ?? iosVersions(status: .ok)) : nil,
            error: error
        )
    }

    private static func platformBuildArgs(
        configured: Bool = true,
        own: [String] = [],
        effective: [String]? = nil
    ) -> PlatformBuildArgs {
        PlatformBuildArgs(configured: configured, own: own, effective: effective ?? own)
    }

    private static func buildArgsResponse(
        shared: [String] = [],
        android: PlatformBuildArgs = platformBuildArgs(),
        ios: PlatformBuildArgs = platformBuildArgs()
    ) -> BuildArgsResponse {
        BuildArgsResponse(protocolVersion: 1, cliVersion: "0.7.0", shared: shared, android: android, ios: ios)
    }

    /// Polls until an observable condition clears, and fails rather than hanging when
    /// it does not. Every asynchronous path here settles onto the main actor, so the
    /// condition is read there too.
    @MainActor
    private static func settle(
        while condition: () -> Bool,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(condition(), "the condition never settled within \(timeout)s", file: file, line: line)
    }

    private struct APIKeyContract: Decodable {
        let protocolVersion: Int
        let records: [String: [String: [String]]]
    }

    // protocolVersion and cliVersion are added by the CLI's api_document envelope, and
    // error only appears in failure documents, so none of them belong to a record.
    private static let envelopeKeys: Set<String> = ["protocolVersion", "cliVersion", "error"]

    // CLI keys the app intentionally does not model, keyed by "<record>.<level>"
    // where "." is the record root (so "project_api_record..", "setup_status_record.ios").
    //
    // EMPTY TODAY, and that is a measured fact rather than an assumption: it was
    // enumerated by running the unmodelled check below with an empty allow-list and
    // reading the reported diff. Every key the four records emit is decoded by a
    // Swift property.
    //
    // Every entry added here silences a real signal, so every entry needs a comment
    // saying WHY the app can ignore that field (CLI-internal bookkeeping, a field
    // only the Python side consumes, and so on). An unexplained entry is how this
    // check rots into a rubber stamp.
    private static let cliKeysTheAppIntentionallyIgnores: [String: Set<String>] = [:]

    private static func keyContract() throws -> APIKeyContract {
        let data = try Data(contentsOf: keyContractURL())
        return try JSONDecoder().decode(APIKeyContract.self, from: data)
    }

    private func assertCLIEmitsEveryKey<Model: Encodable>(
        of model: Model,
        forRecord record: String,
        in contract: APIKeyContract,
        ignoringAppKeys ignored: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cliLevels = try XCTUnwrap(contract.records[record], "unknown record \(record)", file: file, line: line)
        let appLevels = try Self.encodedKeyLevels(of: model)

        // Both directions below only compare levels the sample actually produced, so a
        // level the app models nowhere — a nested object or list the CLI emits and no
        // Swift type mirrors — would otherwise be skipped in silence rather than
        // reported. It is the whole nesting level going unchecked, which is strictly
        // worse than one missing key.
        XCTAssertEqual(
            Set(cliLevels.keys).subtracting(appLevels.keys).sorted(),
            [],
            "\(record) has CLI nesting levels the app decodes nothing at",
            file: file,
            line: line
        )

        for (level, appKeys) in appLevels {
            let cliKeys = Set(try XCTUnwrap(
                cliLevels[level],
                "the CLI record \(record) has no level \(level) that the app decodes",
                file: file,
                line: line
            ))
            let missing = Set(appKeys).subtracting(ignored).subtracting(cliKeys).sorted()

            // Direction 1: the app decodes a key the CLI no longer emits.
            XCTAssertEqual(missing, [], "\(record).\(level) is missing app keys", file: file, line: line)

            // Direction 2: the CLI emits a key no Swift model reads any more. Without
            // this, deleting a property from a model shrinks appKeys, leaves `missing`
            // empty, and the app silently stops reading a field the CLI still sends —
            // which is exactly how a refactor breaks this contract. New CLI keys are
            // still a compatible protocol v1 addition, so each one has to be admitted
            // deliberately through the commented allow-list rather than by accident.
            let unmodelled = cliKeys
                .subtracting(appKeys)
                .subtracting(Self.cliKeysTheAppIntentionallyIgnores["\(record).\(level)"] ?? [])
                .sorted()
            XCTAssertEqual(
                unmodelled,
                [],
                "\(record).\(level) has CLI keys no app model decodes; add a Swift property, "
                    + "or allow-list them in cliKeysTheAppIntentionallyIgnores with a reason",
                file: file,
                line: line
            )
        }
    }

    private static func encodedKeyLevels<Model: Encodable>(of model: Model) throws -> [String: [String]] {
        let data = try JSONEncoder().encode(model)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var levels: [String: [String]] = [:]

        // Merged rather than assigned, because a list contributes one level from every
        // element: an optional left nil in one element still has to be seen if another
        // element carries it.
        func record(_ node: [String: Any], at level: String) {
            levels[level] = Set(levels[level] ?? []).union(node.keys).sorted()
        }

        func walk(_ node: [String: Any], _ prefix: String) {
            record(node, at: prefix)
            for (key, value) in node {
                let path = prefix == "." ? key : "\(prefix).\(key)"
                if let child = value as? [String: Any] {
                    walk(child, path)
                } else if let list = value as? [Any] {
                    // The fixture spells the object inside a list as "<path>[]", which
                    // is where the store report keeps its per-track and per-build keys.
                    // Without this the whole nested level would go unchecked in both
                    // directions.
                    for element in list {
                        guard let child = element as? [String: Any] else { continue }
                        walk(child, "\(path)[]")
                    }
                }
            }
        }

        walk(root, ".")
        return levels
    }

    private static func keyContractURL() -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/api_v1_keys.json")
    }

    private static func realCLIURL() -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/frk")
    }

    /// Read-only sample access to a rendered bitmap, so a test can measure what was actually
    /// drawn instead of asking the renderer what it meant to draw.
    ///
    /// Reads `bitmapData` rather than `getPixel(_:atX:y:)`: the island scan touches ~300k
    /// pixels and the accessor is a bridged call per pixel. `y` counts down from the top,
    /// which is both the PNG's row order and the order `NSBitmapImageRep` stores.
    private struct PixelGrid {
        struct Sample: Equatable {
            let r: Int
            let g: Int
            let b: Int
        }

        struct Region {
            let minX: Int
            let minY: Int
            let maxX: Int
            let maxY: Int
        }

        /// A measured extent in pixels, inclusive of both edges.
        struct Box {
            let minX: Int
            let minY: Int
            let maxX: Int
            let maxY: Int

            var width: Int { maxX - minX + 1 }
            var height: Int { maxY - minY + 1 }
            var midX: Double { Double(minX + maxX) / 2 }
            var midY: Double { Double(minY + maxY) / 2 }
        }

        private let rep: NSBitmapImageRep
        private let bytes: UnsafeMutablePointer<UInt8>
        private let rowStride: Int
        private let pixelStride: Int
        private let redOffset: Int

        init?(rep: NSBitmapImageRep) {
            guard let bytes = rep.bitmapData,
                  !rep.isPlanar,
                  rep.bitsPerSample == 8,
                  rep.samplesPerPixel == 3 || rep.samplesPerPixel == 4
            else { return nil }
            self.rep = rep
            self.bytes = bytes
            rowStride = rep.bytesPerRow
            pixelStride = rep.bitsPerPixel / 8
            redOffset = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        }

        init?(png: Data) {
            guard let rep = NSBitmapImageRep(data: png) else { return nil }
            self.init(rep: rep)
        }

        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        func pixel(_ x: Int, _ y: Int) -> Sample {
            let base = bytes + y * rowStride + x * pixelStride + redOffset
            return Sample(r: Int(base[0]), g: Int(base[1]), b: Int(base[2]))
        }

        /// Tightest box around every pixel in `region` the predicate accepts, or nil if none.
        func boundingBox(in region: Region, where matches: (Sample) -> Bool) -> Box? {
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            for y in region.minY...region.maxY {
                for x in region.minX...region.maxX where matches(pixel(x, y)) {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard minX <= maxX else { return nil }
            return Box(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        func firstPixel(in region: Region, where matches: (Sample) -> Bool) -> Sample? {
            for y in region.minY...region.maxY {
                for x in region.minX...region.maxX {
                    let sample = pixel(x, y)
                    if matches(sample) { return sample }
                }
            }
            return nil
        }
    }

    private func testImage(width: Int, height: Int) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }
}
