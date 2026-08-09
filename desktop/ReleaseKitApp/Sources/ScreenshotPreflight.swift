import Foundation

// Preflight: one model, one call site, re-run on every option change.
//
// Deliberately free of AppKit, SwiftUI and I/O. It takes facts about the source, the export
// target and the options and returns findings, so all twelve checks are unit-testable
// without a window and the renderer and the studio view cannot disagree about what is safe.
//
// Only three checks block — alpha where forbidden, a Play dimension-bound violation, and a
// device frame on a Wear OS asset. Everything else exports on confirmation: the job here is
// to make the consequence visible, not to be right about the user's intent.
//
// Requirements sourced from live Apple/Google documentation verified 2026-08-08.

// MARK: - Findings

enum PreflightSeverity: String, CaseIterable, Identifiable, Hashable, Sendable {
    case info
    case warn
    case block

    var id: String { rawValue }

    /// Sort key: the thing that stops an export goes first.
    var rank: Int {
        switch self {
        case .block: 0
        case .warn: 1
        case .info: 2
        }
    }

    var title: String {
        switch self {
        case .info: "Note"
        case .warn: "Warning"
        case .block: "Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle"
        case .block: "xmark.octagon"
        }
    }
}

/// A remedy the UI can apply in one tap. `nil` on a finding means there is no in-app fix —
/// check 2 is the honest example: an undersized capture needs a new capture, not a setting.
enum PreflightFix: Hashable, Sendable {
    case useOpaqueCanvas
    case useFit(FitPolicy)
    case useFrame(ScreenshotFrame)
    case usePadding(Double)
    case useOutputSize(PixelSize)
    case recaptureOn(PlatformKind)

    /// Button label.
    var title: String {
        switch self {
        case .useOpaqueCanvas: "Use an opaque canvas"
        case .useFit(let fit): "Switch to \(fit.title)"
        case .useFrame(.none): "Remove the device frame"
        case .useFrame(let frame): "Use the \(frame.title) frame"
        case .usePadding(let percent): "Set padding to \(Int(percent.rounded()))%"
        case .useOutputSize(let size): "Resize to \(size)"
        case .recaptureOn(.ios): "Capture on the iOS Simulator"
        case .recaptureOn(.android): "Capture on an Android device"
        }
    }
}

struct PreflightFinding: Identifiable, Hashable, Sendable {
    /// Stable across re-renders so the list does not flicker while a slider moves.
    let id: String
    let severity: PreflightSeverity
    /// One line, factual.
    let title: String
    /// What will happen, in concrete pixels or percentages. Never "may not look right".
    let detail: String
    let fix: PreflightFix?

    init(id: String, severity: PreflightSeverity, title: String, detail: String, fix: PreflightFix? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

// MARK: - Inputs

enum SourceColourModel: String, Hashable, Sendable {
    case rgb
    case grayscale
    case cmyk
    case unknown

    var title: String {
        switch self {
        case .rgb: "RGB"
        case .grayscale: "greyscale"
        case .cmyk: "CMYK"
        case .unknown: "an unrecognised colour model"
        }
    }
}

/// Pixel-format facts the caller reads off the source bitmap. The source itself is never
/// touched — this tool renders and exports, it never mutates a capture.
struct SourceImageFacts: Hashable, Sendable {
    var size: PixelSize
    var bitsPerSample: Int = 8
    var colourModel: SourceColourModel = .rgb
    /// Where the capture came from. Drives checks 6 and 7.
    var platform: PlatformKind?

    init(size: PixelSize, bitsPerSample: Int = 8, colourModel: SourceColourModel = .rgb, platform: PlatformKind? = nil) {
        self.size = size
        self.bitsPerSample = bitsPerSample
        self.colourModel = colourModel
        self.platform = platform
    }
}

struct PreflightOptions: Hashable, Sendable {
    var frame: ScreenshotFrame = .none
    var fit: FitPolicy = .fitPad
    var canvasIsTransparent: Bool = false
    var paddingPercent: Double = 6
    /// An alternate from the preset's variant menu, or a size the user typed. `nil` means
    /// the preset's own `pixelSize`.
    var outputSizeOverride: PixelSize?

    init(
        frame: ScreenshotFrame = .none,
        fit: FitPolicy = .fitPad,
        canvasIsTransparent: Bool = false,
        paddingPercent: Double = 6,
        outputSizeOverride: PixelSize? = nil
    ) {
        self.frame = frame
        self.fit = fit
        self.canvasIsTransparent = canvasIsTransparent
        self.paddingPercent = paddingPercent
        self.outputSizeOverride = outputSizeOverride
    }
}

/// Geometry the renderer actually produced. Supplying it keeps every pixel figure in the
/// findings honest; when it is absent the checker recomputes the layout in pure arithmetic
/// so the checks still run — and still run in a test with no graphics context.
struct PreflightLayout: Hashable, Sendable {
    let canvas: PixelSize
    /// The rect the capture is drawn into, in output pixels: the screen rect inside the
    /// bezel for a framed render, the fitted image rect otherwise.
    let screenWidth: Double
    let screenHeight: Double

    init(canvas: PixelSize, screenWidth: Double, screenHeight: Double) {
        self.canvas = canvas
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

struct PreflightInput: Hashable, Sendable {
    var target: ExportTarget
    var source: SourceImageFacts
    var options: PreflightOptions
    var layout: PreflightLayout?
    /// Assets already queued per preset id, per localization. Empty means the caller is not
    /// batching, and the count checks stay quiet rather than inventing a number.
    var queuedCountsByPresetID: [String: Int]
    /// PNG colour type of an already-encoded export. `nil` before the encode.
    var encodedColourType: Int?

    init(
        target: ExportTarget,
        source: SourceImageFacts,
        options: PreflightOptions = PreflightOptions(),
        layout: PreflightLayout? = nil,
        queuedCountsByPresetID: [String: Int] = [:],
        encodedColourType: Int? = nil
    ) {
        self.target = target
        self.source = source
        self.options = options
        self.layout = layout
        self.queuedCountsByPresetID = queuedCountsByPresetID
        self.encodedColourType = encodedColourType
    }
}

// MARK: - Report

struct PreflightReport: Hashable, Sendable {
    /// Severest first, then declaration order of the checks.
    let findings: [PreflightFinding]
    /// The size the export will be, or `nil` in Free mode where it derives from the source.
    let outputSize: PixelSize?
    /// The preview should tint the padding bars — the mismatch is large enough that the
    /// user should see how much of the frame is background before shipping it.
    let highlightsPadBars: Bool
    /// The preview should overlay the crop rectangle on the full source.
    let highlightsCropRect: Bool
    /// An orientation flip is never auto-cropped; the fit policy is pinned to fit & pad.
    let forcesFitPad: Bool

    var blocking: [PreflightFinding] { findings.filter { $0.severity == .block } }
    var isBlocked: Bool { !blocking.isEmpty }
    var warnings: [PreflightFinding] { findings.filter { $0.severity == .warn } }
    var highestSeverity: PreflightSeverity? { findings.first?.severity }
    /// One line for the disabled export button's tooltip.
    var blockingReason: String? { blocking.first.map { "\($0.title) \($0.detail)" } }
}

// MARK: - Errors

enum ScreenshotPreflightError: LocalizedError {
    case unreadablePNG
    case alphaChannelPresent(colourType: Int)

    var errorDescription: String? {
        switch self {
        case .unreadablePNG:
            "The encoded image is not a readable PNG."
        case .alphaChannelPresent(let colourType):
            "The encoded PNG is colour type \(colourType), which carries an alpha channel. App Store Connect and Google Play both reject that, even when every pixel is opaque."
        }
    }
}

// MARK: - Checker

enum ScreenshotPreflight {
    /// §2.2 — never enlarge a capture past native inside a frame…
    static let maximumUpscale = 1.0
    /// …unless that leaves the device too small a fraction of the canvas to read.
    static let minimumDeviceWidthFraction = 0.55

    // Play's large-screen rules cover the tablet and Chromebook slots. Matched on the stable
    // preset id rather than the display group so a copy edit cannot switch a rule off.
    private static let largeScreenIDPrefixes = ["play.tablet", "play.chromebook"]
    private static let playPhoneIDPrefixes = ["play.phone"]

    static func evaluate(_ input: PreflightInput) -> PreflightReport {
        let preset = input.target.preset
        let outputSize = effectiveOutputSize(input)
        let layout = input.layout ?? estimateLayout(input, outputSize: outputSize)

        var findings: [PreflightFinding] = []
        var highlightsPadBars = false
        var highlightsCropRect = false
        var forcesFitPad = false

        // 1 — alpha where forbidden. Both stores reject the channel, not the transparency.
        findings += alphaFindings(input, preset: preset)

        // 2 — upscaling past native.
        findings += upscaleFindings(input, layout: layout)

        // Checks 3, 4 and 5 describe what the fit policy does to a bare image. A framed
        // export has no fit policy: the capture keeps its aspect exactly inside the frame's
        // screen rect and the canvas absorbs 100% of the mismatch as background (§2.2).
        if input.options.frame == .none, let layout, let outputSize {
            // 4 — orientation flip. Checked first because it pins the fit policy.
            if let finding = orientationFinding(input, outputSize: outputSize) {
                findings.append(finding)
                forcesFitPad = true
            }
            let fit = forcesFitPad ? .fitPad : input.options.fit
            switch fit {
            case .fitPad:
                // 3 — aspect mismatch.
                if let result = aspectFinding(input, layout: layout, outputSize: outputSize) {
                    findings.append(result.finding)
                    highlightsPadBars = result.hatchesBars
                }
            case .fillCrop:
                // 5 — crop loss.
                if let result = cropFinding(input, outputSize: outputSize) {
                    findings.append(result.finding)
                    highlightsCropRect = result.overlaysCropRect
                }
            }
        }

        // 6 and 7 — platform mismatch, cosmetic and reviewable.
        findings += platformFindings(input, preset: preset)

        // 8 and 9 — Google Play dimension rules.
        if let preset, let outputSize {
            findings += playFindings(preset: preset, outputSize: outputSize)
            // 10 — counts, per size class per localization.
            findings += countFindings(input, preset: preset)
            // 11 — Wear OS forbids frames, backgrounds and masking.
            findings += wearFindings(input, preset: preset)
        }

        // 12 — source pixel format.
        findings += sourceFormatFindings(input)

        return PreflightReport(
            findings: findings.sorted { $0.severity.rank < $1.severity.rank },
            outputSize: outputSize,
            highlightsPadBars: highlightsPadBars,
            highlightsCropRect: highlightsCropRect,
            forcesFitPad: forcesFitPad
        )
    }

    /// The size this export will produce. `nil` only in Free mode with no explicit size,
    /// where the canvas derives from the source.
    static func effectiveOutputSize(_ input: PreflightInput) -> PixelSize? {
        input.options.outputSizeOverride ?? input.target.pixelSize
    }

    // MARK: Check 1 — alpha

    private static func alphaFindings(_ input: PreflightInput, preset: StorePreset?) -> [PreflightFinding] {
        var findings: [PreflightFinding] = []

        if let preset, input.options.canvasIsTransparent {
            findings.append(PreflightFinding(
                id: "alpha.transparent-canvas",
                severity: .block,
                title: "A transparent canvas cannot be exported to \(preset.store.title).",
                detail: "App Store Connect and Google Play both reject an image that carries an alpha channel, even when every pixel is fully opaque. Switch the canvas to Light, Dark or Accent.",
                fix: .useOpaqueCanvas
            ))
        }

        if let colourType = input.encodedColourType, colourType == 4 || colourType == 6 {
            findings.append(PreflightFinding(
                id: "alpha.png-colour-type",
                severity: .block,
                title: "The encoded PNG carries an alpha channel.",
                detail: "The file is colour type \(colourType); the stores accept only colour type 2 (24-bit RGB). Every pixel being opaque does not help — the presence of the channel is the rejection.",
                fix: .useOpaqueCanvas
            ))
        }

        if input.target.preset == nil, input.options.canvasIsTransparent {
            findings.append(PreflightFinding(
                id: "alpha.free-mode",
                severity: .info,
                title: "This export will carry an alpha channel.",
                detail: "No store accepts a transparent canvas. Free mode only — pick a preset before uploading anywhere.",
                fix: nil
            ))
        }

        return findings
    }

    // MARK: Check 2 — upscaling

    private static func upscaleFindings(_ input: PreflightInput, layout: PreflightLayout?) -> [PreflightFinding] {
        guard let layout, input.target.preset != nil else { return [] }
        let sourceWidth = Double(input.source.size.width)
        guard sourceWidth > 0, layout.screenWidth > 0 else { return [] }
        let ratio = layout.screenWidth / sourceWidth
        guard ratio > 1.0 else { return [] }

        let detail = "This \(input.source.size.width)px capture is being enlarged \(multiple(ratio)) to fill a \(layout.canvas.width)px preset. Re-capture on a larger device or simulator."
        var findings = [
            PreflightFinding(
                id: "scale.upscale",
                severity: ratio > 1.15 ? .warn : .info,
                title: "The capture is being enlarged past its native size.",
                detail: detail,
                fix: nil
            ),
        ]
        if ratio > 2.0 {
            findings.append(PreflightFinding(
                id: "scale.upscale-severe",
                severity: .warn,
                title: "At \(multiple(ratio)) the result will be visibly soft.",
                detail: "Text and icons at more than double their captured size read as blurry in a store listing. A capture of at least \(Int(layout.screenWidth.rounded()))px wide would render 1:1.",
                fix: nil
            ))
        }
        return findings
    }

    // MARK: Check 3 — aspect mismatch

    private static func aspectFinding(
        _ input: PreflightInput,
        layout: PreflightLayout,
        outputSize: PixelSize
    ) -> (finding: PreflightFinding, hatchesBars: Bool)? {
        let sourceAspect = input.source.size.aspectRatio
        let targetAspect = outputSize.aspectRatio
        guard sourceAspect > 0, targetAspect > 0 else { return nil }
        let mismatch = max(targetAspect / sourceAspect, sourceAspect / targetAspect)
        guard mismatch > 1.10 else { return nil }

        let sideBar = (Double(outputSize.width) - layout.screenWidth) / 2
        let endBar = (Double(outputSize.height) - layout.screenHeight) / 2
        let horizontal = sideBar >= endBar
        let bar = max(0, horizontal ? sideBar : endBar)
        let span = Double(horizontal ? outputSize.width : outputSize.height)
        let coverage = span > 0 ? (bar * 2) / span : 0

        // §2.6's numeric bands put R ≤ 1.30 at .info, but both §2.6 and §5 use 20:9 → 16:9 —
        // R = 1.25 — as their worked .warn example. That is the Pixel-capture case this tool
        // exists to catch, so the contradiction is resolved upward: escalate on how much
        // canvas actually shows, not on R alone.
        let severity: PreflightSeverity = mismatch > 1.30 || coverage >= 0.15 ? .warn : .info
        let detail: String
        if severity == .info {
            detail = "Padded ~\(percent(coverage)) on the \(horizontal ? "short" : "long") edge — \(px(bar)) of canvas on each side."
        } else {
            detail = "The capture is \(PlayImageRules.aspectLabel(input.source.size)); the preset is \(PlayImageRules.aspectLabel(outputSize)). \(px(bar)) of canvas will show on \(horizontal ? "each side" : "the top and bottom"), \(percent(coverage)) of the image."
        }

        return (
            PreflightFinding(
                id: "aspect.mismatch",
                severity: severity,
                title: "The capture does not match the preset's shape.",
                detail: detail,
                // The only other policy there is. Offered once the bars are worth trading
                // pixels for; at .info they are not.
                fix: severity == .warn ? .useFit(.fillCrop) : nil
            ),
            mismatch >= 1.75
        )
    }

    // MARK: Check 4 — orientation flip

    private static func orientationFinding(_ input: PreflightInput, outputSize: PixelSize) -> PreflightFinding? {
        let source = input.source.size.orientation
        let target = outputSize.orientation
        guard source != .square, target != .square, source != target else { return nil }

        let detail = "A \(source.title.lowercased()) capture in a \(target.title.lowercased()) preset produces large side bands, and the capture is never cropped across an orientation flip. Capture in \(target.title.lowercased()), or pick a \(source.title.lowercased()) preset."
        return PreflightFinding(
            id: "orientation.flip",
            severity: .warn,
            title: "The capture and the preset have opposite orientations.",
            detail: detail,
            fix: input.options.fit == .fitPad ? nil : .useFit(.fitPad)
        )
    }

    // MARK: Check 5 — crop loss

    private static func cropFinding(
        _ input: PreflightInput,
        outputSize: PixelSize
    ) -> (finding: PreflightFinding, overlaysCropRect: Bool)? {
        let source = input.source.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = max(Double(outputSize.width) / Double(source.width), Double(outputSize.height) / Double(source.height))
        guard scale > 0 else { return nil }
        let visibleWidth = min(Double(source.width), Double(outputSize.width) / scale)
        let visibleHeight = min(Double(source.height), Double(outputSize.height) / scale)
        let kept = (visibleWidth * visibleHeight) / (Double(source.width) * Double(source.height))
        let lost = max(0, 1 - kept)
        guard lost > 0.15 else { return nil }

        // A centred vertical crop on a portrait capture eats the two regions a reviewer uses
        // to confirm the shot is a real device capture.
        let verticalCrop = visibleHeight < Double(source.height) - 1
        let casualty = verticalCrop ? ", including the status bar and the bottom safe area" : ", trimmed evenly from the left and right edges"

        return (
            PreflightFinding(
                id: "crop.loss",
                severity: .warn,
                title: "Fill & crop will discard \(percent(lost)) of the capture.",
                detail: "Scaling to cover \(outputSize) cuts \(percent(lost)) of the capture\(casualty). Fit & pad keeps every pixel and costs only canvas colour.",
                fix: .useFit(.fitPad)
            ),
            lost > 0.30
        )
    }

    // MARK: Checks 6 and 7 — platform mismatch

    private static func platformFindings(_ input: PreflightInput, preset: StorePreset?) -> [PreflightFinding] {
        guard let capture = input.source.platform else { return [] }
        var findings: [PreflightFinding] = []

        // 7 — reviewable. This replaces the old hard block: a mockup is a legitimate use, so
        // the correct behaviour is a warning plus "Export anyway", not a disabled button.
        var reviewable = false
        if let preset {
            switch (capture, preset.store) {
            case (.android, .apple):
                reviewable = true
                findings.append(PreflightFinding(
                    id: "platform.store-mismatch",
                    severity: .warn,
                    title: "An Android capture is going into an App Store preset.",
                    detail: "App Review guideline 2.3.3 requires screenshots to show the app in use on the platform. A visible Android status bar or navigation bar in this image is a rejection risk. Export anyway if this is a deliberate mockup.",
                    fix: .recaptureOn(.ios)
                ))
            case (.ios, .play):
                reviewable = true
                findings.append(PreflightFinding(
                    id: "platform.store-mismatch",
                    severity: .warn,
                    title: "An iOS capture is going into a Google Play preset.",
                    detail: "The listing will show an iOS status bar and home indicator to Android users, and Play expects the asset to show the app as it runs on Android. Export anyway if this is a deliberate mockup.",
                    fix: .recaptureOn(.android)
                ))
            default:
                break
            }
        }

        // 6 — cosmetic. Suppressed when 7 already said the same thing louder.
        if !reviewable, let framePlatform = input.options.frame.platform, framePlatform != capture {
            findings.append(PreflightFinding(
                id: "platform.frame-mismatch",
                severity: .info,
                title: "\(capture.title) capture in \(articled(input.options.frame.title)) frame.",
                detail: "The frame drawn around this capture is not the platform it came from. Deliberate for a mockup, a mistake otherwise.",
                fix: .useFrame(ScreenshotFrame.matching(capture, tablet: input.options.frame.isTablet))
            ))
        }

        return findings
    }

    // MARK: Checks 8 and 9 — Google Play dimension rules

    private static func playFindings(preset: StorePreset, outputSize: PixelSize) -> [PreflightFinding] {
        var findings: [PreflightFinding] = []

        // 8 — the universal validator. Assets Google specifies at one exact size are exempt:
        // the feature graphic is 1024 × 500, which is 2.048:1 and fails Google's own 2:1 cap.
        if preset.followsPlayDimensionRules || (preset.store == .play && preset.pixelSize != outputSize) {
            if let reason = PlayImageRules.rejectionReason(for: outputSize) {
                let legal = PlayImageRules.nearestLegalSize(for: outputSize)
                findings.append(PreflightFinding(
                    id: "play.dimension-bounds",
                    severity: .block,
                    title: "Google Play rejects \(outputSize).",
                    detail: "\(reason) The nearest size Play accepts is \(legal), reached by padding the short edge rather than cropping the long one.",
                    fix: .useOutputSize(legal)
                ))
            }
        }

        // 9 — Play's large-screen guidance is exactly 16:9 or 9:16, not "about".
        if largeScreenIDPrefixes.contains(where: { preset.id.hasPrefix($0) }), !isSixteenByNine(outputSize) {
            findings.append(PreflightFinding(
                id: "play.large-screen-aspect",
                severity: .warn,
                title: "\(outputSize) is not exactly 16:9 or 9:16.",
                detail: "Play's large-screen guidance specifies exactly 16:9 landscape or 9:16 portrait; this is \(PlayImageRules.aspectLabel(outputSize)). The asset still uploads, but it may not qualify for large-screen homepage placement.",
                fix: nil
            ))
        }

        return findings
    }

    // MARK: Check 10 — counts

    private static func countFindings(_ input: PreflightInput, preset: StorePreset) -> [PreflightFinding] {
        let counts = input.queuedCountsByPresetID
        guard !counts.isEmpty else { return [] }
        var findings: [PreflightFinding] = []

        let queued = counts[preset.id] ?? 0
        let maximum = preset.store.maximumAssetsPerClass
        if queued > maximum {
            findings.append(PreflightFinding(
                id: "count.over-maximum",
                severity: .warn,
                title: "\(queued) assets are queued for \(preset.name).",
                detail: "\(preset.store.title) accepts at most \(maximum) per size class per localization. \(queued - maximum) will be refused at upload.",
                fix: nil
            ))
        }

        if playPhoneIDPrefixes.contains(where: { preset.id.hasPrefix($0) }) {
            let phones = total(counts, prefixes: playPhoneIDPrefixes)
            if phones > 0, phones < 2 {
                findings.append(PreflightFinding(
                    id: "count.play-phone-minimum",
                    severity: .warn,
                    title: "Google Play needs at least 2 screenshots to publish.",
                    detail: "\(phones) phone screenshot is queued. Play's wording is \"a minimum of two screenshots across different device types\", and it is genuinely unclear whether two phone shots alone satisfy it — the Console has historically accepted them.",
                    fix: nil
                ))
            }
        }

        if largeScreenIDPrefixes.contains(where: { preset.id.hasPrefix($0) }) {
            let largeScreen = total(counts, prefixes: largeScreenIDPrefixes)
            if largeScreen > 0, largeScreen < 4 {
                findings.append(PreflightFinding(
                    id: "count.large-screen-minimum",
                    severity: .warn,
                    title: "\(largeScreen) of 4 large-screen screenshots queued.",
                    detail: "Play states at least 4 screenshots of 1080px or more in 16:9 or 9:16 as the bar for large-screen and recommendation placement (3 for games). Fewer never blocks a release — it only forfeits the placement.",
                    fix: nil
                ))
            }
        }

        return findings
    }

    // MARK: Check 11 — Wear OS

    private static func wearFindings(_ input: PreflightInput, preset: StorePreset) -> [PreflightFinding] {
        guard !preset.allowsBackground else { return [] }
        var findings: [PreflightFinding] = []

        if input.options.frame != .none {
            findings.append(PreflightFinding(
                id: "wear.frame-forbidden",
                severity: .block,
                title: "Wear OS screenshots cannot carry a device frame.",
                detail: "Play forbids device frames, added backgrounds and masking on Wear OS screenshots — interface only, 1:1, at least \(preset.pixelSize). The \(input.options.frame.title) frame must be removed.",
                fix: .useFrame(.none)
            ))
        }

        if input.options.paddingPercent > 0 {
            findings.append(PreflightFinding(
                id: "wear.padding-forbidden",
                severity: .block,
                title: "Wear OS screenshots cannot carry an added background.",
                detail: "\(Int(input.options.paddingPercent.rounded()))% padding would surround the interface with canvas colour, which Play counts as an added background. Padding must be 0%.",
                fix: .usePadding(0)
            ))
        }

        // The third leg of the same rule, and the one that has no visible control to give it
        // away: a fit policy carried in from whatever preset happened to be active elsewhere
        // (a batch job that reassigns `target` and nothing else) letterboxes the interface
        // onto canvas colour, which Play reads as an added background. Blocking here means
        // the asset cannot reach disk even if a caller forgets to re-derive the policy.
        if input.options.fit != preset.defaultFit {
            findings.append(PreflightFinding(
                id: "wear.fit-forbidden",
                severity: .block,
                title: "Wear OS screenshots must fill the square canvas.",
                detail: "\(input.options.fit.title) leaves canvas colour beside the interface, which Play counts as an added background. Wear OS is locked to \(preset.defaultFit.title) at \(preset.pixelSize) — the fit policy chosen for another preset never follows the export here.",
                fix: .useFit(preset.defaultFit)
            ))
        }

        return findings
    }

    // MARK: Check 12 — source pixel format

    private static func sourceFormatFindings(_ input: PreflightInput) -> [PreflightFinding] {
        let odd = input.source.bitsPerSample != 8 || input.source.colourModel != .rgb
        guard odd else { return [] }
        let description = input.source.bitsPerSample == 8
            ? input.source.colourModel.title
            : "\(input.source.bitsPerSample)-bit \(input.source.colourModel.title)"
        return [
            PreflightFinding(
                id: "source.colour-conversion",
                severity: .info,
                title: "The source is \(description).",
                detail: "It will be converted to 8-bit sRGB on export. Apple documents no colour space for screenshots, so sRGB is this tool's conservative choice.",
                fix: nil
            ),
        ]
    }

    // MARK: Layout estimate

    // Bezel thickness as a fraction of rendered screen width, mirroring §4. Used only to
    // reconstruct the geometry when the renderer has not handed over a measured layout —
    // the renderer remains the authority on what is actually drawn.
    private static func bezelFraction(_ frame: ScreenshotFrame) -> Double {
        switch frame {
        case .iphone: 0.030
        case .ipad: 0.048
        case .androidPhone: 0.032
        case .androidTablet: 0.055
        case .none: 0
        }
    }

    private static func estimateLayout(_ input: PreflightInput, outputSize: PixelSize?) -> PreflightLayout? {
        guard let canvas = outputSize else { return nil }
        let source = input.source.size
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else { return nil }

        let aspect = source.aspectRatio
        let canvasWidth = Double(canvas.width)
        let canvasHeight = Double(canvas.height)
        let margin = min(max(input.options.paddingPercent, 0), 20) / 100 * min(canvasWidth, canvasHeight)
        let usableWidth = max(1, canvasWidth - 2 * margin)
        let usableHeight = max(1, canvasHeight - 2 * margin)

        if input.options.frame == .none {
            let width: Double
            switch input.options.fit {
            case .fitPad:
                width = min(usableWidth, usableHeight * aspect)
            case .fillCrop:
                // Filling ignores the margin: there is no remainder left to pad.
                width = max(canvasWidth, canvasHeight * aspect)
            }
            return PreflightLayout(canvas: canvas, screenWidth: width, screenHeight: width / aspect)
        }

        let bezel = bezelFraction(input.options.frame)
        var width = min(usableWidth / (1 + 2 * bezel), usableHeight / (1 / aspect + 2 * bezel))
        width = min(width, maximumUpscale * Double(source.width))
        if width * (1 + 2 * bezel) < minimumDeviceWidthFraction * canvasWidth {
            width = minimumDeviceWidthFraction * canvasWidth / (1 + 2 * bezel)
        }
        return PreflightLayout(canvas: canvas, screenWidth: width, screenHeight: width / aspect)
    }

    // MARK: PNG inspection
    //
    // §3.3's post-export validator. Twenty lines standing between this tool and a silent
    // rejection weeks later, so it runs on every preset export rather than only Apple's.

    /// PNG colour type from the IHDR chunk: 0 greyscale, 2 RGB, 3 palette, 4 greyscale+alpha,
    /// 6 RGBA. Only 2 is acceptable to either store.
    static func pngColourType(_ data: Data) -> Int? {
        guard isPNG(data), data.count > 25 else { return nil }
        return Int(data[data.startIndex + 25])
    }

    /// Encoded pixel dimensions from the IHDR chunk, for asserting an export hit its preset.
    static func pngPixelSize(_ data: Data) -> PixelSize? {
        guard isPNG(data), data.count > 23 else { return nil }
        let base = data.startIndex
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 << 8 | Int(data[base + offset + $1]) }
        }
        let size = PixelSize(word(16), word(20))
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// Throws unless the encoded PNG is colour type 2. Both stores reject an alpha channel
    /// even when every pixel is fully opaque — the channel is the failure, not the pixels.
    static func assertNoAlpha(_ data: Data) throws {
        guard let colourType = pngColourType(data) else { throw ScreenshotPreflightError.unreadablePNG }
        guard colourType != 4, colourType != 6 else {
            throw ScreenshotPreflightError.alphaChannelPresent(colourType: colourType)
        }
    }

    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        let base = data.startIndex
        return !signature.indices.contains { data[base + $0] != signature[$0] }
    }

    // MARK: Formatting

    private static func isSixteenByNine(_ size: PixelSize) -> Bool {
        size.width * 9 == size.height * 16 || size.width * 16 == size.height * 9
    }

    private static func total(_ counts: [String: Int], prefixes: [String]) -> Int {
        counts.reduce(0) { running, entry in
            prefixes.contains(where: { entry.key.hasPrefix($0) }) ? running + entry.value : running
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func px(_ value: Double) -> String {
        "\(Int(value.rounded()))px"
    }

    private static func multiple(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    private static func articled(_ noun: String) -> String {
        "aeiouAEIOU".contains(noun.first ?? "x") ? "an \(noun)" : "a \(noun)"
    }
}
