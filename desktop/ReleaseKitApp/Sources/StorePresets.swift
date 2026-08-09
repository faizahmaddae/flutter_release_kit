import CoreGraphics
import Foundation

// Store export presets: pure data and pure functions, deliberately free of AppKit and
// SwiftUI so the renderer, the preflight checker and the tests can all share one source
// of truth about what the stores actually accept.
//
// Requirements sourced from live Apple/Google documentation verified 2026-08-08.
// Where the source material is contradictory the conservative reading is taken and the
// caveat is kept visible rather than silently resolved.

// MARK: - Sizes

/// An exact output size in whole pixels. Deliberately integral: a store size is a pixel
/// count, not a measurement, and floating point comparison has no business here.
struct PixelSize: Hashable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    var cgSize: CGSize { CGSize(width: width, height: height) }
    var minDimension: Int { min(width, height) }
    var maxDimension: Int { max(width, height) }

    /// width ÷ height. > 1 is landscape.
    var aspectRatio: Double { Double(width) / Double(height) }

    var orientation: PresetOrientation {
        if width == height { return .square }
        return width > height ? .landscape : .portrait
    }

    var swapped: PixelSize { PixelSize(height, width) }

    /// "1320 × 2868" — the string every picker and warning wants.
    var description: String { "\(width) × \(height)" }
}

enum PresetOrientation: String, CaseIterable, Identifiable, Hashable, Sendable {
    case portrait
    case landscape
    case square

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Frames

/// The five device frames the renderer can draw with Core Graphics primitives.
///
/// This is the canonical frame enum for the rebuild; `ScreenshotFrameStyle` in
/// ScreenshotRenderer.swift should become `typealias ScreenshotFrameStyle = ScreenshotFrame`
/// so presets and the renderer cannot drift apart.
enum ScreenshotFrame: String, CaseIterable, Identifiable, Hashable, Sendable {
    case iphone
    case ipad
    case androidPhone
    case androidTablet
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .androidPhone: "Android phone"
        case .androidTablet: "Android tablet"
        case .none: "No frame"
        }
    }

    var systemImage: String {
        switch self {
        case .iphone: "iphone.gen3"
        case .ipad: "ipad.gen2"
        case .androidPhone: "apps.iphone"
        case .androidTablet: "ipad.landscape"
        case .none: "photo"
        }
    }

    var platform: PlatformKind? {
        switch self {
        case .iphone, .ipad: .ios
        case .androidPhone, .androidTablet: .android
        case .none: nil
        }
    }

    var isTablet: Bool { self == .ipad || self == .androidTablet }

    /// The frame that matches a capture's platform, used where a preset accepts any frame.
    static func matching(_ platform: PlatformKind?, tablet: Bool = false) -> ScreenshotFrame {
        switch platform {
        case .ios: tablet ? .ipad : .iphone
        case .android: tablet ? .androidTablet : .androidPhone
        case nil: .none
        }
    }
}

// MARK: - Fit

/// How a capture is fitted into a preset canvas when no device frame is drawn.
///
/// `stretch` is deliberately absent. A non-uniform scale distorts the UI, and there is no
/// case where a distorted store screenshot is the right answer — offering it guarantees
/// someone ships one.
enum FitPolicy: String, CaseIterable, Identifiable, Hashable, Sendable {
    case fitPad
    case fillCrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitPad: "Fit & pad"
        case .fillCrop: "Fill & crop"
        }
    }

    var detail: String {
        switch self {
        case .fitPad: "Scales to fit inside the canvas and fills the remainder with the canvas colour. Loses no pixels."
        case .fillCrop: "Scales to cover the canvas and crops the overflow evenly from both edges. Loses pixels."
        }
    }

    var losesPixels: Bool { self == .fillCrop }
}

// MARK: - Layout modes

/// How the renderer composes a preset.
///
/// Everything but the feature graphic lays the device out centred in the canvas. 1024 × 500
/// landscape fed a portrait phone capture is a 1:2.05 aspect into a 2.05:1 canvas, where a
/// centred device is a postage stamp in a wide empty field — technically valid, visually
/// useless, and the asset is mandatory to publish. §2.5 gives that case its own composition.
enum PresetLayoutMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case standard
    case featureGraphic

    var id: String { rawValue }
}

/// Geometry for §2.5's feature-graphic composition. Pure numbers and pure functions so the
/// renderer, the preflight checker and the tests share one description of where the device
/// goes and which parts of the canvas Google may crop.
enum FeatureGraphicLayout {
    /// The framed device is this fraction of the canvas height.
    static let deviceHeightFraction: CGFloat = 0.82
    /// …with its leading edge here, so the device sits right of centre.
    static let deviceAnchorXFraction: CGFloat = 0.62
    /// The left of the canvas is reserved for the developer's own text and logo. The tool
    /// draws nothing into it — not the device, not a shadow, not a guide fill.
    static let safeAreaWidthFraction: CGFloat = 0.55
    /// Play crops the outer edge of a feature graphic in some homepage formats. Anything
    /// inside this band can disappear.
    static let edgeCutoffFraction: CGFloat = 0.06

    /// Which side of the canvas a rect strays into the cutoff band on. Names are in the
    /// renderer's bottom-left-origin space, which is how the layout reports geometry.
    enum Edge: String, CaseIterable, Hashable, Sendable {
        case leading
        case trailing
        case bottom
        case top

        var title: String {
            switch self {
            case .leading: "left"
            case .trailing: "right"
            case .bottom: "bottom"
            case .top: "top"
            }
        }
    }

    /// The reserved text and logo area, in output pixels.
    static func safeArea(in canvas: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: (canvas.width * safeAreaWidthFraction).rounded(), height: canvas.height)
    }

    /// The region Play is guaranteed not to crop: the canvas minus the outer cutoff band.
    static func uncroppedArea(in canvas: CGSize) -> CGRect {
        let horizontal = (canvas.width * edgeCutoffFraction).rounded()
        let vertical = (canvas.height * edgeCutoffFraction).rounded()
        return CGRect(
            x: horizontal,
            y: vertical,
            width: max(0, canvas.width - horizontal * 2),
            height: max(0, canvas.height - vertical * 2)
        )
    }

    /// Sides on which `deviceBox` reaches into the cutoff band. Empty means nothing the tool
    /// drew can be cropped away.
    static func cutoffOverlaps(deviceBox: CGRect, canvas: CGSize) -> [Edge] {
        let safe = uncroppedArea(in: canvas)
        var edges: [Edge] = []
        if deviceBox.minX < safe.minX { edges.append(.leading) }
        if deviceBox.maxX > safe.maxX { edges.append(.trailing) }
        if deviceBox.minY < safe.minY { edges.append(.bottom) }
        if deviceBox.maxY > safe.maxY { edges.append(.top) }
        return edges
    }

    /// One sentence naming the sides at risk, or `nil` when the device clears the band.
    static func cutoffWarning(edges: [Edge]) -> String? {
        guard !edges.isEmpty else { return nil }
        let sides = edges.map(\.title)
        let list = sides.count == 1
            ? sides[0]
            : sides.dropLast().joined(separator: ", ") + " and " + (sides.last ?? "")
        return "The device reaches into the outer \(Int(edgeCutoffFraction * 100))% of the "
            + "\(list) edge\(edges.count == 1 ? "" : "s"). Play crops that band in some homepage "
            + "formats, so part of the device will be cut off there."
    }
}

// MARK: - Stores

enum StoreKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case apple
    case play

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "App Store"
        case .play: "Google Play"
        }
    }

    /// Filename component for batch export: `<project>_<store>_<presetToken>_<NN>.png`.
    var fileToken: String {
        switch self {
        case .apple: "appstore"
        case .play: "play"
        }
    }

    /// Max assets the store accepts per size class / device type, per localization.
    var maximumAssetsPerClass: Int {
        switch self {
        case .apple: 10
        case .play: 8
        }
    }
}

// MARK: - Requirement tiers

enum PresetRequirement: Hashable, Sendable {
    /// Blocks submission for every project.
    case required
    /// Blocks submission only when the carried condition holds, e.g. "the project has an iPad target".
    case requiredIf(String)
    /// Absence never blocks a release; presence unlocks placement or eligibility.
    case recommended
    case optional
    /// Still accepted, no longer requested. Apple removed the 5.5″ iPhone and 12.9″ iPad
    /// requirements in September 2024 — plenty of stale tooling still marks these required.
    case legacy

    /// Picker sort rank: mandatory first.
    var rank: Int {
        switch self {
        case .required: 0
        case .requiredIf: 1
        case .recommended: 2
        case .optional: 3
        case .legacy: 4
        }
    }

    var isMandatoryTier: Bool {
        switch self {
        case .required, .requiredIf: true
        case .recommended, .optional, .legacy: false
        }
    }

    /// Short badge text. `nil` means draw no badge.
    var badge: String? {
        switch self {
        case .required: "Required"
        case .requiredIf: "Conditional"
        case .recommended: "Recommended"
        case .optional: nil
        case .legacy: "Legacy"
        }
    }

    var label: String {
        switch self {
        case .required: "Required"
        case .requiredIf(let condition): "Required if \(condition)"
        case .recommended: "Recommended"
        case .optional: "Optional"
        case .legacy: "Legacy — no longer requested"
        }
    }
}

// MARK: - Preset

struct StorePreset: Identifiable, Hashable, Sendable {
    /// Stable identity, e.g. "apple.iphone69.portrait". Persisted and used in filenames.
    let id: String
    let store: StoreKind
    /// Section header in the picker.
    let group: String
    let name: String
    /// The exact output size. Non-negotiable — the renderer emits this, byte for byte.
    let pixelSize: PixelSize
    /// Equally-accepted sizes for the same slot, offered as a variant menu on this one row.
    /// `pixelSize` is always the largest: App Store Connect scales *down* from the largest
    /// asset into every smaller class and never up.
    let alternates: [PixelSize]
    /// The store mandates this exact size and publishes no range around it. Matters because
    /// Play's universal screenshot rules must not be applied to these — see
    /// `followsPlayDimensionRules`.
    let hasFixedSize: Bool
    /// How the renderer composes the canvas. Only the feature graphic departs from centred.
    let layoutMode: PresetLayoutMode
    let requirement: PresetRequirement
    /// False for every preset shipped — both stores reject an alpha channel even when
    /// every pixel is opaque. Alpha survives only in Free mode.
    let allowsAlpha: Bool
    let defaultFit: FitPolicy
    let allowedFrames: [ScreenshotFrame]
    let defaultFrame: ScreenshotFrame
    /// False only where the store forbids added backgrounds, padding and masking (Wear OS).
    /// The canvas picker and the padding slider must be disabled when this is false.
    let allowsBackground: Bool
    /// Collapsed behind a "Legacy sizes" disclosure, off by default.
    let isLegacy: Bool
    /// Caveat or uncertainty the user must see. Surfaced in the UI, never swallowed.
    let note: String?

    // Spelled out so `hasFixedSize` and `layoutMode` can default; the rest stays explicit at
    // every call site because a wrong preset value is a store rejection.
    init(
        id: String,
        store: StoreKind,
        group: String,
        name: String,
        pixelSize: PixelSize,
        alternates: [PixelSize],
        hasFixedSize: Bool = false,
        layoutMode: PresetLayoutMode = .standard,
        requirement: PresetRequirement,
        allowsAlpha: Bool,
        defaultFit: FitPolicy,
        allowedFrames: [ScreenshotFrame],
        defaultFrame: ScreenshotFrame,
        allowsBackground: Bool,
        isLegacy: Bool,
        note: String?
    ) {
        self.id = id
        self.store = store
        self.group = group
        self.name = name
        self.pixelSize = pixelSize
        self.alternates = alternates
        self.hasFixedSize = hasFixedSize
        self.layoutMode = layoutMode
        self.requirement = requirement
        self.allowsAlpha = allowsAlpha
        self.defaultFit = defaultFit
        self.allowedFrames = allowedFrames
        self.defaultFrame = defaultFrame
        self.allowsBackground = allowsBackground
        self.isLegacy = isLegacy
        self.note = note
    }

    var orientation: PresetOrientation { pixelSize.orientation }
    var isMandatory: Bool { requirement.isMandatoryTier }
    /// §2.5's dedicated composition rather than a device centred in the canvas.
    var usesFeatureGraphicLayout: Bool { layoutMode == .featureGraphic }
    /// The user cannot change the frame when only one is allowed (Wear OS, Mac, TV).
    var isFrameLocked: Bool { allowedFrames.count <= 1 }
    /// Every size accepted for this slot, largest first.
    var acceptedSizes: [PixelSize] { [pixelSize] + alternates }

    /// Whether `PlayImageRules` governs this preset. Google's universal rules describe Play
    /// *screenshots*; the assets it specifies at an exact size are outside them. The feature
    /// graphic proves it — 1024 × 500 is 2.048:1 and fails Play's own 2:1 screenshot cap.
    var followsPlayDimensionRules: Bool { store == .play && !hasFixedSize }

    /// Filename component: "apple.iphone69.portrait" → "iphone69-portrait".
    var fileToken: String {
        let stripped = id.hasPrefix(store.rawValue + ".") ? String(id.dropFirst(store.rawValue.count + 1)) : id
        return stripped.replacingOccurrences(of: ".", with: "-")
    }

    func accepts(_ size: PixelSize) -> Bool { acceptedSizes.contains(size) }
    func allows(_ frame: ScreenshotFrame) -> Bool { allowedFrames.contains(frame) }

    /// The frame to preselect. Presets that accept any frame (the feature graphic) follow
    /// the capture's platform; everything else has one right answer.
    func resolvedDefaultFrame(capturePlatform: PlatformKind?) -> ScreenshotFrame {
        guard allowedFrames.count > 2 else { return defaultFrame }
        let matched = ScreenshotFrame.matching(capturePlatform)
        return allows(matched) ? matched : defaultFrame
    }
}

// MARK: - Export target

/// What an export is aimed at. `.free` is the escape hatch that preserves today's
/// behaviour: size derived from the source, transparent canvas permitted.
enum ExportTarget: Hashable, Sendable, Identifiable {
    case free
    case preset(StorePreset)

    var id: String {
        switch self {
        case .free: "free"
        case .preset(let preset): preset.id
        }
    }

    var preset: StorePreset? {
        switch self {
        case .free: nil
        case .preset(let preset): preset
        }
    }

    var title: String {
        switch self {
        case .free: "Free (no preset)"
        case .preset(let preset): preset.name
        }
    }

    /// `nil` means "derive the canvas from the source", which only Free mode does.
    var pixelSize: PixelSize? { preset?.pixelSize }

    /// Free mode is the only place a transparent canvas is representable. No store accepts one.
    var allowsAlpha: Bool { preset?.allowsAlpha ?? true }

    var allowsBackground: Bool { preset?.allowsBackground ?? true }

    var note: String? {
        switch self {
        case .free: "No store accepts a transparent canvas. Free mode only."
        case .preset(let preset): preset.note
        }
    }
}

// MARK: - Google Play universal validator

/// Applies to every Play *screenshot* preset and to any custom size the user types. Assets
/// Google specifies at one exact size are exempt — see `StorePreset.followsPlayDimensionRules`.
enum PlayImageRules {
    static let minDimension = 320
    static let maxDimension = 3840
    /// The long edge may never exceed twice the short edge.
    static let maxAspectMultiple = 2

    // ⚠︎CONTRADICTORY: the same Play help page says "Upload screenshots between 1,080 and
    // 7,680px" under its large-screens bullet, while the formal Requirements block on the
    // same page says "Maximum dimension: 3840px" — and the page's own preamble states the
    // Requirements block is the mandatory one. 7680 > 3840, so we cap at 3840 everywhere
    // and surface the contradiction rather than pretending it is resolved.
    static let dimensionCaveat = """
        Google documents two different maximums on the same page: a "1,080 to 7,680px" \
        range for large screens and a "Maximum dimension: 3840px" requirement. The \
        requirements block is the binding one, so this tool caps every size at 3840px.
        """

    enum Violation: Hashable, Sendable {
        case tooSmall(dimension: Int)
        case tooLarge(dimension: Int)
        case tooElongated(size: PixelSize)

        var message: String {
            switch self {
            case .tooSmall(let dimension):
                "\(dimension)px is below Google Play's \(PlayImageRules.minDimension)px minimum for any dimension."
            case .tooLarge(let dimension):
                "\(dimension)px exceeds Google Play's \(PlayImageRules.maxDimension)px maximum dimension."
            case .tooElongated(let size):
                "\(size) is \(PlayImageRules.aspectLabel(size)). Play rejects anything steeper than 2:1."
            }
        }
    }

    static func validate(_ size: PixelSize) -> [Violation] {
        var violations: [Violation] = []
        if size.minDimension < minDimension { violations.append(.tooSmall(dimension: size.minDimension)) }
        if size.maxDimension > maxDimension { violations.append(.tooLarge(dimension: size.maxDimension)) }
        if size.maxDimension > maxAspectMultiple * size.minDimension { violations.append(.tooElongated(size: size)) }
        return violations
    }

    static func isValid(_ size: PixelSize) -> Bool { validate(size).isEmpty }

    /// One sentence explaining why Play would reject this size, or `nil` if it would not.
    /// The case this exists for: 1080 × 2400 — the native aspect of most modern Android
    /// phones and of the default Pixel emulator — is 20:9 and violates the 2:1 cap, so a
    /// raw Pixel capture is not a legal Play screenshot.
    static func rejectionReason(for size: PixelSize) -> String? {
        let violations = validate(size)
        guard !violations.isEmpty else { return nil }
        return violations.map(\.message).joined(separator: " ")
    }

    /// Nearest size Play accepts, reached by padding the short edge rather than cropping
    /// the long one (§2.3: pad, never crop). Deterministic; used as the one-tap preflight fix.
    static func nearestLegalSize(for size: PixelSize) -> PixelSize {
        var result = padToAspectCap(size)
        if result.maxDimension > maxDimension {
            result = padToAspectCap(scaled(result, longEdge: maxDimension))
        }
        if result.minDimension < minDimension {
            result = padToAspectCap(scaled(result, shortEdge: minDimension))
        }
        return result
    }

    /// Long edge first, reduced to lowest terms — "20:9" for the common Android phone case,
    /// which is how both stores and every spec sheet write it, portrait or not.
    static func aspectLabel(_ size: PixelSize) -> String {
        let divisor = greatestCommonDivisor(size.width, size.height)
        guard divisor > 0 else { return "\(size.maxDimension):\(size.minDimension)" }
        return "\(size.maxDimension / divisor):\(size.minDimension / divisor)"
    }

    private static func padToAspectCap(_ size: PixelSize) -> PixelSize {
        guard size.maxDimension > maxAspectMultiple * size.minDimension else { return size }
        let needed = Int((Double(size.maxDimension) / Double(maxAspectMultiple)).rounded(.up))
        return size.width < size.height ? PixelSize(needed, size.height) : PixelSize(size.width, needed)
    }

    private static func scaled(_ size: PixelSize, longEdge: Int) -> PixelSize {
        scaled(size, by: Double(longEdge) / Double(size.maxDimension))
    }

    private static func scaled(_ size: PixelSize, shortEdge: Int) -> PixelSize {
        scaled(size, by: Double(shortEdge) / Double(size.minDimension))
    }

    private static func scaled(_ size: PixelSize, by factor: Double) -> PixelSize {
        PixelSize(
            max(1, Int((Double(size.width) * factor).rounded())),
            max(1, Int((Double(size.height) * factor).rounded()))
        )
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

// MARK: - Groups

struct PresetGroup: Identifiable, Hashable, Sendable {
    let id: String
    let store: StoreKind
    let presets: [StorePreset]

    var title: String { id }
    var isLegacy: Bool { presets.allSatisfy(\.isLegacy) }
}

// MARK: - Catalogue

enum StorePresetCatalog {
    /// Sorted for the picker: requirement rank, then store, then declaration order.
    static let all: [StorePreset] = declared
        .enumerated()
        .sorted { lhs, rhs in
            if lhs.element.requirement.rank != rhs.element.requirement.rank {
                return lhs.element.requirement.rank < rhs.element.requirement.rank
            }
            if lhs.element.store != rhs.element.store {
                return lhs.element.store == .apple
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)

    /// The safe default for a fresh export: the one iPhone slot every iOS submission needs.
    static var defaultPreset: StorePreset { preset(id: "apple.iphone69.portrait")! }

    static var mandatory: [StorePreset] { all.filter(\.isMandatory) }
    static var recommended: [StorePreset] { all.filter { $0.requirement == .recommended } }
    static var legacy: [StorePreset] { all.filter(\.isLegacy) }
    /// Everything the picker shows before the "Legacy sizes" disclosure is expanded.
    static var current: [StorePreset] { all.filter { !$0.isLegacy } }

    static func preset(id: String) -> StorePreset? { all.first { $0.id == id } }

    static func presets(for store: StoreKind) -> [StorePreset] { all.filter { $0.store == store } }

    /// Sections in picker order; legacy groups sort last because their presets do.
    static func groups(includingLegacy: Bool = false) -> [PresetGroup] {
        var order: [String] = []
        var buckets: [String: [StorePreset]] = [:]
        for preset in all where includingLegacy || !preset.isLegacy {
            if buckets[preset.group] == nil { order.append(preset.group) }
            buckets[preset.group, default: []].append(preset)
        }
        return order.compactMap { title in
            guard let presets = buckets[title], let store = presets.first?.store else { return nil }
            return PresetGroup(id: title, store: store, presets: presets)
        }
    }

    /// The preset to preselect for a capture from this platform.
    static func suggested(for platform: PlatformKind?) -> StorePreset {
        switch platform {
        case .android: preset(id: "play.phone.portrait") ?? defaultPreset
        case .ios, nil: defaultPreset
        }
    }

    // Declaration order below is the tiebreak for sorting; the tiers themselves come from
    // `requirement`, so rows can be reordered here without changing what is mandatory.
    private static let declared: [StorePreset] = appleMandatory
        + playMandatory
        + playRecommended
        + appleOptional
        + playConditional
        + appleLegacy

    // MARK: Apple — mandatory tier
    //
    // A typical iOS submission needs exactly ONE iPhone set (6.9″ or 6.5″) plus one iPad 13″
    // set iff the app ships an iPad target. Nothing else is mandatory. The 5.5″ iPhone and
    // 12.9″ iPad requirements were removed in September 2024.

    private static let appleMandatory: [StorePreset] = [
        StorePreset(
            id: "apple.iphone69.portrait",
            store: .apple,
            group: "App Store — iPhone",
            name: "iPhone 6.9″ Portrait",
            pixelSize: PixelSize(1320, 2868),
            alternates: [PixelSize(1290, 2796), PixelSize(1260, 2736)],
            requirement: .required,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.iphone, .none],
            defaultFrame: .iphone,
            allowsBackground: true,
            isLegacy: false,
            note: "The iPhone slot. 1290 × 2796 and 1260 × 2736 are equally accepted; the largest is the default because App Store Connect scales down from it into every smaller iPhone class and never up."
        ),
        StorePreset(
            id: "apple.iphone69.landscape",
            store: .apple,
            group: "App Store — iPhone",
            name: "iPhone 6.9″ Landscape",
            pixelSize: PixelSize(2868, 1320),
            alternates: [PixelSize(2796, 1290), PixelSize(2736, 1260)],
            requirement: .requiredIf("the app is landscape-only"),
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.iphone, .none],
            defaultFrame: .iphone,
            allowsBackground: true,
            isLegacy: false,
            note: nil
        ),
        StorePreset(
            id: "apple.ipad13.portrait",
            store: .apple,
            group: "App Store — iPad",
            name: "iPad 13″ Portrait",
            pixelSize: PixelSize(2064, 2752),
            alternates: [PixelSize(2048, 2732)],
            requirement: .requiredIf("the project has an iPad target"),
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.ipad, .none],
            defaultFrame: .ipad,
            allowsBackground: true,
            isLegacy: false,
            note: "Apple's label is literally \"Required if app runs on iPad\". Nothing scales up into this slot. The 2048 × 2732 alternate also legally fills the retired 12.9″ slot — one asset, two slots."
        ),
        StorePreset(
            id: "apple.ipad13.landscape",
            store: .apple,
            group: "App Store — iPad",
            name: "iPad 13″ Landscape",
            pixelSize: PixelSize(2752, 2064),
            alternates: [PixelSize(2732, 2048)],
            requirement: .requiredIf("the project has an iPad target and ships landscape"),
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.ipad, .none],
            defaultFrame: .ipad,
            allowsBackground: true,
            isLegacy: false,
            note: nil
        ),
        StorePreset(
            id: "apple.mac",
            store: .apple,
            group: "App Store — Mac",
            name: "Mac",
            pixelSize: PixelSize(2880, 1800),
            alternates: [PixelSize(2560, 1600), PixelSize(1440, 900), PixelSize(1280, 800)],
            requirement: .requiredIf("the project has a macOS target"),
            allowsAlpha: false,
            // 16:10 target against a near-16:10 window capture: the mismatch is small, and
            // letterbox bars around a desktop app read as a bug rather than a design choice.
            defaultFit: .fillCrop,
            allowedFrames: [.none],
            defaultFrame: .none,
            allowsBackground: true,
            isLegacy: false,
            note: "Landscape only, strict 16:10. Flutter ships a macOS target, so this is mandatory whenever that target is enabled."
        ),
    ]

    // MARK: Google Play — mandatory tier

    private static let playMandatory: [StorePreset] = [
        StorePreset(
            id: "play.phone.portrait",
            store: .play,
            group: "Google Play — Phone",
            name: "Phone Portrait",
            pixelSize: PixelSize(1080, 1920),
            alternates: [],
            requirement: .required,
            allowsAlpha: false,
            // The dominant case is a 20:9 capture into a 16:9 target; fillCrop would discard
            // roughly a fifth of the vertical UI.
            defaultFit: .fitPad,
            allowedFrames: [.androidPhone, .none],
            defaultFrame: .androidPhone,
            allowsBackground: true,
            isLegacy: false,
            note: "Play specifies a size range, not a fixed size. 1080 × 1920 is chosen because it satisfies both the publish gate and the ≥1080px, exactly-9:16 promo-eligibility gate. A raw 1080 × 2400 Pixel capture is 20:9 and is rejected — it will be padded to fit."
        ),
        StorePreset(
            id: "play.phone.landscape",
            store: .play,
            group: "Google Play — Phone",
            name: "Phone Landscape",
            pixelSize: PixelSize(1920, 1080),
            alternates: [],
            requirement: .requiredIf("the app is landscape-only"),
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.androidPhone, .none],
            defaultFrame: .androidPhone,
            allowsBackground: true,
            isLegacy: false,
            note: nil
        ),
        StorePreset(
            id: "play.featureGraphic",
            store: .play,
            group: "Google Play — Feature graphic",
            name: "Feature Graphic",
            pixelSize: PixelSize(1024, 500),
            alternates: [],
            hasFixedSize: true,
            layoutMode: .featureGraphic,
            requirement: .required,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: ScreenshotFrame.allCases,
            defaultFrame: .none,
            allowsBackground: true,
            isLegacy: false,
            note: "Not a screenshot: fixed size, landscape only, and its absence blocks publication. The device is composed right of centre at 82% of the canvas height and the left 55% is left empty for your own text and logo. Play crops the outer 6% in some homepage formats, so keep logos, app names and UI out of that band."
        ),
    ]

    // MARK: Google Play — recommended tier
    //
    // Absence never blocks a release. What these gate is large-screen homepage placement
    // and screenshot-based recommendation formats. Label them "Recommended", never "Required".

    private static let playRecommended: [StorePreset] = [
        StorePreset(
            id: "play.tablet.landscape.hd",
            store: .play,
            group: "Google Play — Tablet & large screen",
            name: "Tablet Landscape (HD)",
            pixelSize: PixelSize(1920, 1080),
            alternates: [],
            requirement: .recommended,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.androidTablet, .none],
            defaultFrame: .androidTablet,
            allowsBackground: true,
            isLegacy: false,
            note: "Play now gives one rule for 7″, 10″ and Chromebook: at least 4 screenshots, strictly 16:9 landscape or 9:16 portrait. Most real 10″ tablets are 16:10, so a raw emulator capture does not match — it is padded, never cropped."
        ),
        StorePreset(
            id: "play.tablet.landscape.qhd",
            store: .play,
            group: "Google Play — Tablet & large screen",
            name: "Tablet Landscape (QHD)",
            pixelSize: PixelSize(2560, 1440),
            alternates: [],
            requirement: .recommended,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.androidTablet, .none],
            defaultFrame: .androidTablet,
            allowsBackground: true,
            isLegacy: false,
            note: "Preferred when the capture is at least 1440px tall."
        ),
        StorePreset(
            id: "play.tablet.portrait",
            store: .play,
            group: "Google Play — Tablet & large screen",
            name: "Tablet Portrait",
            // 1440 × 2560 is exactly 9:16 (1440 × 16 = 2560 × 9). The 1600 × 2560 this row
            // used to default to is 8:5 — it uploads fine under Play's universal rules, but
            // it fails Play's own large-screen 16:9/9:16 requirement, so the tool's own
            // check fired on every single use of the default. The spec records 1600 × 2560
            // while describing it as "9:16 within the size band"; the number is the wrong
            // half of that sentence.
            pixelSize: PixelSize(1440, 2560),
            alternates: [PixelSize(1600, 2560)],
            requirement: .recommended,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.androidTablet, .none],
            defaultFrame: .androidTablet,
            allowsBackground: true,
            isLegacy: false,
            note: "1440 × 2560 is exactly 9:16, which is what Play's large-screen guidance asks for. The 1600 × 2560 alternate is 8:5: Play accepts the upload, but the asset does not qualify for large-screen placement, and the preflight check says so when you pick it."
        ),
        StorePreset(
            id: "play.chromebook.landscape",
            store: .play,
            group: "Google Play — Chromebook",
            name: "Chromebook Landscape",
            pixelSize: PixelSize(1920, 1080),
            alternates: [],
            requirement: .recommended,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.androidTablet, .none],
            defaultFrame: .androidTablet,
            allowsBackground: true,
            isLegacy: false,
            note: "A separate upload slot — Play does not copy tablet assets into it."
        ),
    ]

    // MARK: Apple — optional
    //
    // Offer, don't push. Landscape twins are produced by swapping the pair rather than
    // enumerating them here.

    private static let appleOptional: [StorePreset] = [
        StorePreset(
            id: "apple.iphone65.portrait",
            store: .apple,
            group: "App Store — iPhone",
            name: "iPhone 6.5″ Portrait",
            pixelSize: PixelSize(1284, 2778),
            alternates: [PixelSize(1242, 2688)],
            requirement: .optional,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.iphone, .none],
            defaultFrame: .iphone,
            allowsBackground: true,
            isLegacy: false,
            note: "The fallback half of a 6.9″-or-6.5″ either/or. Only useful if you deliberately skip 6.9″."
        ),
        StorePreset(
            id: "apple.iphone63.portrait",
            store: .apple,
            group: "App Store — iPhone",
            name: "iPhone 6.3″ Portrait",
            pixelSize: PixelSize(1206, 2622),
            alternates: [PixelSize(1179, 2556)],
            requirement: .optional,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.iphone, .none],
            defaultFrame: .iphone,
            allowsBackground: true,
            isLegacy: false,
            note: "Auto-scaled from 6.5″ if absent."
        ),
        StorePreset(
            id: "apple.iphone61.portrait",
            store: .apple,
            group: "App Store — iPhone",
            name: "iPhone 6.1″ Portrait",
            pixelSize: PixelSize(1170, 2532),
            alternates: [PixelSize(1125, 2436), PixelSize(1080, 2340)],
            requirement: .optional,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.iphone, .none],
            defaultFrame: .iphone,
            allowsBackground: true,
            isLegacy: false,
            note: nil
        ),
        StorePreset(
            id: "apple.ipad11.portrait",
            store: .apple,
            group: "App Store — iPad",
            name: "iPad 11″ Portrait",
            pixelSize: PixelSize(1488, 2266),
            alternates: [PixelSize(1668, 2420), PixelSize(1668, 2388), PixelSize(1640, 2360)],
            requirement: .optional,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.ipad, .none],
            defaultFrame: .ipad,
            allowsBackground: true,
            isLegacy: false,
            // The alternates here are taller than pixelSize, so this is the one row where
            // "largest first" does not hold. Apple lists 1488 × 2266 as the primary size.
            note: "Apple's primary 11″ size is 1488 × 2266; the taller alternates are equally accepted."
        ),
    ]

    // MARK: Google Play — conditional form factors
    //
    // Only relevant when the app is distributed to that form factor, but the constraints
    // (especially Wear OS) are strict enough that the preflight checker needs them typed.

    private static let playConditional: [StorePreset] = [
        StorePreset(
            id: "play.tv.screenshot",
            store: .play,
            group: "Google Play — Android TV",
            name: "Android TV Screenshot",
            pixelSize: PixelSize(1920, 1080),
            alternates: [],
            requirement: .requiredIf("the app is distributed to Android TV"),
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.none],
            defaultFrame: .none,
            allowsBackground: true,
            isLegacy: false,
            note: "No TV-specific pixel size is published; the universal Play rule applies. TV captures are already 16:9, so any padding here means something is wrong upstream."
        ),
        StorePreset(
            id: "play.tv.banner",
            store: .play,
            group: "Google Play — Android TV",
            name: "Android TV Banner",
            pixelSize: PixelSize(1280, 720),
            alternates: [],
            hasFixedSize: true,
            requirement: .requiredIf("the app is TV-enabled"),
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [.none],
            defaultFrame: .none,
            allowsBackground: true,
            isLegacy: false,
            note: "Fixed size, no range. Required to publish a TV-enabled app."
        ),
        StorePreset(
            id: "play.wear",
            store: .play,
            group: "Google Play — Wear OS",
            name: "Wear OS",
            pixelSize: PixelSize(384, 384),
            alternates: [],
            requirement: .requiredIf("the app is distributed to Wear OS"),
            allowsAlpha: false,
            // Forced: the asset must be the interface and nothing else.
            defaultFit: .fillCrop,
            allowedFrames: [.none],
            defaultFrame: .none,
            allowsBackground: false,
            isLegacy: false,
            note: "Play forbids device frames, added backgrounds, masking, transparency and added text on Wear OS screenshots — interface only, 1:1, at least 384 × 384. The frame, canvas and padding controls are locked off for this preset."
        ),
    ]

    // MARK: Apple — legacy
    //
    // Still accepted, no longer requested. Never labelled required anywhere in the UI.
    // The 4″, 3.5″ and 9.7″ classes are the only ones where Apple publishes distinct
    // with/without-status-bar heights; the without-status-bar variants are deliberately
    // not shipped in v1 rather than building a toggle nothing uses.

    private static let appleLegacy: [StorePreset] = [
        legacyApple("apple.iphone55.portrait", "iPhone 5.5″ Portrait", PixelSize(1242, 2208), .iphone,
                    note: "Apple removed the 5.5″ requirement in September 2024. Optional now, whatever older tooling says."),
        legacyApple("apple.iphone47.portrait", "iPhone 4.7″ Portrait", PixelSize(750, 1334), .iphone,
                    note: nil),
        legacyApple("apple.iphone40.portrait", "iPhone 4″ Portrait", PixelSize(640, 1136), .iphone,
                    note: "Apple also publishes a shorter without-status-bar height (640 × 1096) for this class. Not shipped in v1."),
        legacyApple("apple.iphone35.portrait", "iPhone 3.5″ Portrait", PixelSize(640, 960), .iphone,
                    note: "Apple also publishes a shorter without-status-bar height (640 × 920) for this class. Not shipped in v1."),
        legacyApple("apple.ipad129.portrait", "iPad 12.9″ Portrait", PixelSize(2048, 2732), .ipad,
                    note: "Apple removed the 12.9″ requirement in September 2024. This asset also legally fills the current iPad 13″ slot."),
        legacyApple("apple.ipad105.portrait", "iPad 10.5″ Portrait", PixelSize(1668, 2224), .ipad,
                    note: nil),
        legacyApple("apple.ipad97.portrait", "iPad 9.7″ Portrait", PixelSize(1536, 2048), .ipad,
                    note: "Apple also publishes a shorter without-status-bar height (1536 × 2008) for this class. Not shipped in v1."),
    ]

    private static func legacyApple(
        _ id: String,
        _ name: String,
        _ size: PixelSize,
        _ frame: ScreenshotFrame,
        note: String?
    ) -> StorePreset {
        StorePreset(
            id: id,
            store: .apple,
            group: "App Store — Legacy sizes",
            name: name,
            pixelSize: size,
            alternates: [],
            requirement: .legacy,
            allowsAlpha: false,
            defaultFit: .fitPad,
            allowedFrames: [frame, .none],
            defaultFrame: frame,
            allowsBackground: true,
            isLegacy: true,
            note: note
        )
    }
}
