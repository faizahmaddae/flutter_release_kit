import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A value plus the one fact the Studio kept getting wrong: whether the *user* put it there.
///
/// The whole class of frame and preset bugs came from recording intent as a side effect of
/// the value changing — a SwiftUI Picker does not call its binding's setter when the user
/// re-selects the value already selected, and `select(preset:)` returned early on a no-op
/// before it reached its flag. So deliberately re-asserting a value recorded nothing, and the
/// next automatic seed wrote straight over it.
///
/// Here the two operations are named and separate. `choose` is an explicit interaction and
/// always records intent, whether or not the value moves. `seed` is a default filled in on
/// the user's behalf and refuses once a choice exists. `value` is `private(set)`, so those
/// two are the only writers in the program: there is no third path by which an automatic
/// action can overwrite a chosen value.
struct UserChoice<Value: Equatable>: Equatable {
    private(set) var value: Value
    /// Set by `choose` and never by `seed`.
    private(set) var isUserChosen: Bool

    init(_ value: Value, isUserChosen: Bool = false) {
        self.value = value
        self.isUserChosen = isUserChosen
    }

    /// An explicit interaction: a menu row tapped, a preflight fix applied, a preset row
    /// clicked. Records intent unconditionally, including when `newValue == value`.
    mutating func choose(_ newValue: Value) {
        value = newValue
        isUserChosen = true
    }

    /// A default the app supplies on the user's behalf. Refuses once a choice exists, and
    /// reports whether it actually wrote, so callers can skip the work that goes with a real
    /// change without having to read `isUserChosen` themselves.
    @discardableResult
    mutating func seed(_ newValue: Value) -> Bool {
        guard !isUserChosen, newValue != value else { return false }
        value = newValue
        return true
    }
}

/// One captured, imported or pasted image. The batch queue is a list of these, so the
/// per-size-class count rules have something real to count.
///
/// The image is held in memory and the file it came from is never written to. Capture
/// deletes its own temp file; import and paste never touch the original.
struct StudioShot: Identifiable, Hashable {
    let id = UUID()
    let image: NSImage
    let label: String
    let platform: PlatformKind?
    let pixelSize: PixelSize?
    /// The frame is per shot, not per session. A queue holding an iOS capture and an Android
    /// capture has two right answers at once, and a single global setting can only ever be
    /// one of them - which is exactly how an iPhone capture ended up previewed and exported
    /// inside an Android frame after switching back to it.
    var frame = UserChoice<ScreenshotFrame>(.iphone)

    static func == (lhs: StudioShot, rhs: StudioShot) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ScreenshotRenderOptions {
    /// Every option a preset can lock has to re-derive from `target`, not from whatever the
    /// UI happened to be showing: `resolvedFrame` and `resolvedPaddingPercent` already did,
    /// this is the third. Wear OS forbids an added background, so a `fitPad` carried in from
    /// another preset would letterbox the interface onto canvas colour and ship a rejectable
    /// asset that reports as succeeded.
    var resolvedFit: FitPolicy {
        guard let preset, !target.allowsBackground else { return fit }
        return preset.defaultFit
    }
}

/// The single place render options are built - the preview, the single-PNG export and every
/// batch job all come through here.
///
/// It is a free function rather than a method on the view for one reason: the batch bug was a
/// caller *copying* the live options and reassigning one field. There is now no live options
/// value to copy. Each call states the frame and the target it wants, and every option the
/// target is allowed to override is re-derived from that target on the way out.
enum StudioRenderOptions {
    static func make(
        frame: ScreenshotFrame,
        target: ExportTarget,
        canvas: ScreenshotCanvasStyle,
        paddingPercent: Double,
        fit: FitPolicy,
        sizeOverride: PixelSize?
    ) -> ScreenshotRenderOptions {
        var options = ScreenshotRenderOptions()
        options.target = target
        options.frame = frame
        options.canvas = canvas
        options.paddingPercent = CGFloat(paddingPercent)
        options.fit = fit
        options.sizeOverride = sizeOverride
        // Re-derive every option the target may override. Each is idempotent, so applying it
        // here costs nothing and means the renderer sees resolved values in the fields it
        // actually reads - `layout(source:options:)` reads `options.fit` directly.
        options.frame = options.resolvedFrame
        options.canvas = options.resolvedCanvas
        options.paddingPercent = options.resolvedPaddingPercent
        options.fit = options.resolvedFit
        return options
    }
}

/// What happened to one file in a batch. Reported per file: one failure never aborts the run.
struct StudioExportOutcome: Identifiable, Hashable {
    var id: String { filename }
    let filename: String
    let succeeded: Bool
    let message: String?
}

enum ScreenshotBatchNaming {
    /// `<project>_<store>_<preset>_<NN>.png`. Deterministic on purpose: re-running a batch
    /// overwrites the same files rather than accumulating `-1`, `-2` copies.
    static func filename(project: String, preset: StorePreset, index: Int) -> String {
        "\(token(project))_\(preset.store.fileToken)_\(preset.fileToken)_\(String(format: "%02d", index)).png"
    }

    static func freeFilename(project: String, frame: ScreenshotFrame) -> String {
        "\(token(project))_\(frameToken(frame))_screenshot.png"
    }

    static func frameToken(_ frame: ScreenshotFrame) -> String {
        switch frame {
        case .iphone: "iphone"
        case .ipad: "ipad"
        case .androidPhone: "android-phone"
        case .androidTablet: "android-tablet"
        case .none: "screen"
        }
    }

    static func token(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let trimmed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "app" : trimmed.lowercased()
    }
}

struct ScreenshotStudioView: View {
    @Environment(\.dismiss) private var dismiss

    let project: ProjectSummary

    // Capture sources.
    @State private var targets: [ScreenshotTarget] = []
    @State private var selectedTargetID = ""
    @State private var isDiscovering = false
    @State private var isCapturing = false

    // The queue. `selectedShotID` is the one being previewed and single-exported.
    @State private var shots: [StudioShot] = []
    @State private var selectedShotID: StudioShot.ID?
    @State private var previewImage: NSImage?
    // Sources stay protected even after being removed from the queue.
    @State private var importedSourceURLs: Set<URL> = []

    // Export target. The preset is global on purpose - it is the export's destination, not a
    // property of any one image - so it carries its own intent flag.
    @State private var presetChoice = UserChoice<String?>(StorePresetCatalog.defaultPreset.id)
    @State private var sizeOverride: PixelSize?
    @State private var batchPresetIDs: Set<String> = []
    @State private var showsLegacyPresets = false
    @State private var showsBatchPresets = false

    // Composition. The frame lives on the shot (see `StudioShot.frame`); `pendingFrame` is
    // only what the picker edits while the queue is empty, and what a new shot inherits when
    // the user set it deliberately before capturing anything.
    @State private var pendingFrame = UserChoice<ScreenshotFrame>(.iphone)
    @State private var fit = UserChoice<FitPolicy>(.fitPad)
    @State private var canvasStyle: ScreenshotCanvasStyle = .accent
    @State private var paddingPercent: Double = 6
    @State private var canvasSwitchNote: String?

    // Results.
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var batchDirectory: URL?
    @State private var batchOutcomes: [StudioExportOutcome] = []
    @State private var isExportingBatch = false
    @State private var isExportingPNG = false
    @State private var exportTask: Task<Void, Never>?
    @State private var batchTotal = 0
    @State private var batchWasStopped = false

    private var isExporting: Bool { isExportingBatch || isExportingPNG }

    private struct PreviewInput: Equatable {
        let shotID: UUID?
        let options: ScreenshotRenderOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                controls
                    .frame(minWidth: 330, idealWidth: 380, maxWidth: 430, maxHeight: .infinity)
                preview
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 660, idealHeight: 800)
        .task { await refreshTargets() }
        // The only two inputs a render depends on. Nothing here writes back to any frame, so
        // there is no path from a rendered preview to a changed frame. Both are needed:
        // selecting a shot whose frame happens to match the previous one leaves `options`
        // equal, and the preview still has to switch to the new image.
        .onChange(of: PreviewInput(shotID: selectedShotID, options: options)) { _, _ in refreshPreview() }
        .onDisappear { exportTask?.cancel() }
        .alert("Screenshot Studio", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.frkAccent.gradient, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Screenshot Studio")
                    .font(.title2.bold())
                Text("\(project.name) · Capture, frame, and export store-sized PNGs locally")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Nothing is uploaded", systemImage: "lock.shield.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.frkSuccess)
        }
        .padding(22)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceCard.disabled(isExporting)
                presetCard.disabled(isExporting)
                compositionCard.disabled(isExporting)
                batchPresetCard.disabled(isExporting)
                preflightCard.disabled(isExporting)
                resultsCard
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.36))
    }

    // MARK: - 1. Source

    private var sourceCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("1. Add screenshots", subtitle: "Capture a device, import PNG, JPEG or HEIC files, or paste an image.")

                if isDiscovering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finding running devices…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if targets.isEmpty {
                    Label("No running emulator or simulator found", systemImage: "iphone.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Selecting a capture device changes what Capture talks to. It does not
                    // touch the frame, the preset, or anything else.
                    Picker("Capture source", selection: $selectedTargetID) {
                        ForEach(targets) { target in
                            Label("\(target.platform.title) · \(target.name)", systemImage: target.platform.systemImage)
                                .tag(target.id)
                        }
                    }

                    if let target = selectedTarget {
                        Text(target.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await captureSelectedTarget() }
                    } label: {
                        if isCapturing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(captureButtonTitle, systemImage: "camera")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTarget == nil || isCapturing || isDiscovering)
                    .help("Take a PNG screenshot from the selected running device. The app and device are not modified.")

                    Button {
                        Task { await refreshTargets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isDiscovering || isCapturing)
                    .help("Refresh the list of running Android devices and iOS Simulators.")
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Import Images…") { importImage() }
                        .help("Choose one or more PNG, JPEG, or HEIC files. Originals are never changed.")
                    Button("Paste") { pasteImage() }
                        .keyboardShortcut("v", modifiers: .command)
                        .help("Use the image currently copied to the macOS clipboard.")
                }

                if shots.isEmpty {
                    Text("No images yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        queueList
                    }
                    .frame(height: min(180, CGFloat(shots.count) * 64 + 22))
                }
            }
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queue · \(shots.count) image\(shots.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                HStack(spacing: 8) {
                    Button {
                        selectedShotID = shot.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: shot.image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 44)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(String(format: "%02d", index + 1)) · \(shot.label)")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(queueDetail(shot))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(4)
                        .background(shot.id == selectedShotID ? Color.frkAccent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    Button {
                        remove(shot)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(shot.label)")
                    .help("Remove this image from the queue. The file it came from is untouched.")
                }
                .padding(.vertical, 3)
            }
        }
    }

    /// The frame is per shot, so the queue has to show it: otherwise a mixed queue looks
    /// identical whichever row is selected.
    private func queueDetail(_ shot: StudioShot) -> String {
        let platform = shot.platform.map(\.title) ?? "Imported"
        let size = shot.pixelSize.map(\.description) ?? "unknown size"
        return "\(platform) · \(size) · \(shot.frame.value.title)"
    }

    // MARK: - 2. Preset

    private var presetCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("2. Output size", subtitle: "Choose a store size, or Free to follow the source image.")
                LabeledContent("Preset") {
                    // Buttons also record a deliberate re-selection of the current preset.
                    Menu {
                        Button("Free — no preset") { select(preset: nil) }
                        Divider()
                        ForEach(StorePresetCatalog.groups(includingLegacy: false)) { group in
                            Menu(group.title) {
                                ForEach(group.presets) { preset in
                                    presetMenuRow(preset)
                                }
                            }
                        }
                        Menu("Legacy sizes") {
                            ForEach(StorePresetCatalog.legacy) { preset in
                                presetMenuRow(preset)
                            }
                        }
                    } label: {
                        Text(activePreset?.name ?? "Free — no preset")
                    }
                }
                if let preset = activePreset {
                    if preset.alternates.isEmpty {
                        Text("\(preset.pixelSize.description) · \(preset.requirement.label)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Size", selection: sizeBinding(preset)) {
                            ForEach(preset.acceptedSizes, id: \.self) { size in
                                Text(size.description).tag(size)
                            }
                        }
                        .font(.caption)
                    }
                }
                if exportTarget.note != nil || activePreset?.followsPlayDimensionRules == true {
                    DisclosureGroup("Size guidance") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let note = exportTarget.note {
                                Text(note)
                            }
                            if activePreset?.followsPlayDimensionRules == true {
                                Text(PlayImageRules.dimensionCaveat)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func presetMenuRow(_ preset: StorePreset) -> some View {
        Button {
            select(preset: preset)
        } label: {
            if activePreset?.id == preset.id {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }

    private var batchPresetCard: some View {
        SectionCard {
            DisclosureGroup(isExpanded: $showsBatchPresets) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tick sizes to export every queued image in those sizes. Click a name to preview it.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Tick required") { batchPresetIDs = Set(StorePresetCatalog.mandatory.map(\.id)) }
                            .help("Select every preset either store requires or conditionally requires.")
                        Button("Clear ticks") { batchPresetIDs = [] }
                            .disabled(batchPresetIDs.isEmpty)
                    }
                    .font(.caption)
                    ForEach(StorePresetCatalog.groups(includingLegacy: false)) { group in
                        presetGroupView(group)
                    }
                    DisclosureGroup("Legacy sizes", isExpanded: $showsLegacyPresets) {
                        ForEach(StorePresetCatalog.legacy) { preset in
                            presetRow(preset)
                        }
                    }
                    .font(.caption)
                }
                .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Batch export sizes").font(.headline)
                    Text(batchPresetIDs.isEmpty ? "Optional · export several sizes at once" : "\(batchPresetIDs.count) sizes selected · \(shots.count * batchPresetIDs.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func presetGroupView(_ group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(group.presets) { preset in
                presetRow(preset)
            }
        }
    }

    private func presetRow(_ preset: StorePreset) -> some View {
        let isActive = presetChoice.value == preset.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Toggle(isOn: batchBinding(preset)) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Include \(preset.name) in batch")
                    .help("Include this preset in the batch export.")
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.frkAccent : .secondary)
                Button {
                    select(preset: preset)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(preset.name)
                                .font(.callout.weight(.medium))
                            if let badge = preset.requirement.badge {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badgeTint(preset).opacity(0.16), in: Capsule())
                                    .foregroundStyle(badgeTint(preset))
                            }
                        }
                        Text("\(preset.pixelSize.description) · \(preset.requirement.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

        }
    }

    private func badgeTint(_ preset: StorePreset) -> Color {
        switch preset.requirement {
        case .required, .requiredIf: Color.frkAccent
        case .recommended: .blue
        case .optional, .legacy: .secondary
        }
    }

    // MARK: - 3. Composition

    private var compositionCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 13) {
                sectionTitle("3. Frame and canvas", subtitle: "Frame applies to the selected image. Canvas and spacing apply to all images.")

                framePicker
                canvasPicker
                fitPicker
                paddingSlider
            }
        }
    }

    private var framePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Deliberately a Menu of Buttons rather than a Picker. SwiftUI does not call a
            // Picker binding's setter when the user re-selects the value already selected, so
            // a user who re-picks the current frame to assert it would record no intent and a
            // later platform-tagged capture would seed straight over it. Every row here is a
            // Button, so every explicit interaction records intent whether the value moves or
            // not.
            LabeledContent("Frame") {
                Menu {
                    ForEach(orderedFrames) { frame in
                        frameMenuRow(frame)
                    }
                } label: {
                    Text(frameMenuTitle(displayFrame))
                }
                .disabled(frameIsLocked)
                .help("Choose the device frame for the selected image.")
            }

            if shots.count > 1, !frameIsLocked {
                Button("Apply \(displayFrame.title) to all \(shots.count) images") { applyFrameToAllShots() }
                    .font(.caption)
                    .controlSize(.small)
                    .help("Apply this frame to every image in the queue.")
            }

            if let preset = activePreset, preset.isFrameLocked {
                Label(frameLockReason(preset), systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preset = activePreset {
                Text("Suggested for this preset: \(preset.allowedFrames.map(\.title).joined(separator: ", ")). Any other frame still exports and only warns.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canvasPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Canvas")
                .font(.caption.weight(.medium))
            HStack(spacing: 6) {
                ForEach(ScreenshotCanvasStyle.allCases) { style in
                    canvasChip(style)
                }
            }
            if !exportTarget.allowsBackground {
                Label("Google Play forbids device frames, backgrounds and masking on Wear OS screenshots.", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if activePreset != nil {
                Text("Store presets require an opaque background. Use Free for transparency.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let canvasSwitchNote {
                HStack(alignment: .top, spacing: 6) {
                    Text(canvasSwitchNote)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Dismiss") { self.canvasSwitchNote = nil }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.semibold))
                }
                .padding(8)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func canvasChip(_ style: ScreenshotCanvasStyle) -> some View {
        let selected = canvasStyle == style
        let enabled = canvasIsSelectable(style)
        return Button {
            canvasStyle = style
            canvasSwitchNote = nil
        } label: {
            Text(style.title)
                .font(.caption.weight(.medium))
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? Color.frkAccent.opacity(0.16) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? Color.frkAccent : Color.clear, lineWidth: 1.2)
                }
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? style.title : disabledCanvasReason)
    }

    @ViewBuilder
    private var fitPicker: some View {
        // A framed export preserves the capture's aspect exactly inside the screen rect and
        // the canvas absorbs the whole mismatch, so there is no fit decision to make.
        if !options.paddingApplies {
            VStack(alignment: .leading, spacing: 5) {
                Picker("Fit", selection: fitBinding) {
                    ForEach(FitPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(fitIsLocked)
                Text(effectiveFit.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var paddingSlider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Outer spacing")
                Spacer()
                Text("\(Int(options.resolvedPaddingPercent))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            Slider(value: $paddingPercent, in: 0...20, step: 1)
                .disabled(!options.paddingApplies || !exportTarget.allowsBackground)
            if !options.paddingApplies && exportTarget.allowsBackground {
                Text("Spacing is the gap around the device, so it only applies when a frame is drawn.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 4. Preflight

    private var preflightCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("4. Export checks", subtitle: "Checks update as you edit. Warnings include a suggested fix.")
                if let report {
                    if report.findings.isEmpty {
                        Label("No issues found for this combination.", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.frkSuccess)
                    } else {
                        ForEach(report.findings) { finding in
                            findingRow(finding)
                        }
                    }
                } else {
                    Text("Add an image to run the checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func findingRow(_ finding: PreflightFinding) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(finding.title, systemImage: finding.severity.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(severityTint(finding.severity))
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let fix = finding.fix, canApply(fix) {
                Button(fix.title) { apply(fix) }
                    .font(.caption2)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(severityTint(finding.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func severityTint(_ severity: PreflightSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .warn: .orange
        case .block: .red
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsCard: some View {
        if exportedURL != nil || !batchOutcomes.isEmpty {
            SectionCard {
                VStack(alignment: .leading, spacing: 9) {
                    if let exportedURL {
                        Label("PNG exported", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.frkSuccess)
                        Text(exportedURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                        }
                    }
                    if !batchOutcomes.isEmpty {
                        Divider()
                        Label(batchSummary, systemImage: "square.grid.2x2")
                            .font(.callout.weight(.semibold))
                        ForEach(batchOutcomes) { outcome in
                            VStack(alignment: .leading, spacing: 1) {
                                Label(outcome.filename, systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(outcome.succeeded ? Color.frkSuccess : .orange)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let message = outcome.message {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let batchDirectory {
                            Button("Reveal folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([batchDirectory])
                            }
                        }
                    }
                }
            }
        }
    }

    private var batchSummary: String {
        if isExportingBatch { return "Exporting · \(batchOutcomes.count) of \(batchTotal) files processed" }
        let status = batchWasStopped ? "Batch stopped" : "Batch complete"
        let written = batchOutcomes.filter(\.succeeded).count
        let skipped = batchOutcomes.count - written
        return skipped == 0
            ? "\(status) · \(written) file\(written == 1 ? "" : "s") written"
            : "\(status) · \(written) written, \(skipped) skipped"
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: max(200, geometry.size.width - 56),
                            maxHeight: max(200, geometry.size.height - 84)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                        .padding(28)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }
            .background(checkerboard)
        } else {
            ContentUnavailableView {
                Label("No screenshot yet", systemImage: "iphone.gen3")
            } description: {
                Text("Run the app in an emulator or Simulator and choose Capture, or import an existing image.")
            } actions: {
                Button("Import Images…") { importImage() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let square: CGFloat = 18
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)),
                        with: .color(.secondary.opacity(0.045))
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Close", role: .cancel) { dismiss() }
                .disabled(isExporting)
            if isExportingBatch {
                Button(batchWasStopped ? "Stopping…" : "Stop batch") {
                    batchWasStopped = true
                    exportTask?.cancel()
                }
                .disabled(batchWasStopped)
                .help("Finish the current file, then stop. Completed exports are kept.")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(outputLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let scaleLine {
                    Text(scaleLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(plan.map { $0.upscale > 1.15 } == true ? .orange : .secondary)
                }
            }
            Spacer()
            Button {
                exportBatch()
            } label: {
                if isExportingBatch {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(batchOutcomes.count)/\(batchTotal)").monospacedDigit()
                    }
                } else {
                    Label("Export Batch…", systemImage: "square.grid.2x2")
                }
            }
            .disabled(shots.isEmpty || batchPresetIDs.isEmpty || isExporting || isCapturing)
            .help(batchPresetIDs.isEmpty
                ? "Open Batch export sizes and tick one or more sizes."
                : "Render every queued image into every ticked preset, into one folder you choose.")

            Button {
                exportPNG()
            } label: {
                if isExportingPNG {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Export PNG…", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedShot == nil || isBlocked || isExporting || isCapturing)
            .help(report?.blockingReason ?? "Render a new PNG and save it where you choose. The source screenshot is never overwritten.")
        }
        .padding(18)
    }

    private var outputLine: String {
        guard let plan else { return "Output: add an image" }
        let size = PixelSize(Int(plan.canvas.width), Int(plan.canvas.height))
        return "Output: \(size.description) PNG"
    }

    private var scaleLine: String? {
        guard let plan else { return nil }
        let scale = String(format: "%.2f", plan.upscale)
        if plan.isEnlargedForReadability {
            return "Capture scaled \(scale)× · enlarged to stay readable"
        }
        return plan.upscale > 1
            ? "Capture enlarged \(scale)× past native"
            : "Capture scaled \(scale)×"
    }

    // MARK: - Derived state

    private var selectedTarget: ScreenshotTarget? {
        targets.first { $0.id == selectedTargetID }
    }

    private var captureButtonTitle: String {
        guard let target = selectedTarget else { return "Capture" }
        return "Capture \(target.platform.title)"
    }

    private var selectedShot: StudioShot? {
        shots.first { $0.id == selectedShotID }
    }

    private var selectedShotIndex: Int? {
        shots.firstIndex { $0.id == selectedShotID }
    }

    /// What the frame control shows and what the preview and the single-PNG export use: the
    /// selected shot's own frame, or the pending one while the queue is empty.
    private var displayFrame: ScreenshotFrame {
        (selectedShot?.frame ?? pendingFrame).value
    }

    private var activePreset: StorePreset? {
        presetChoice.value.flatMap(StorePresetCatalog.preset(id:))
    }

    private var exportTarget: ExportTarget {
        activePreset.map(ExportTarget.preset) ?? .free
    }

    /// Play forbids any added background on Wear OS, so `fillCrop` is not the user's to
    /// change there: a `fitPad` export would put canvas colour around the interface.
    private var fitIsLocked: Bool { !exportTarget.allowsBackground }

    /// Read off the options the preview and the export actually use, so the label under the
    /// Fit control can never disagree with what was rendered.
    private var effectiveFit: FitPolicy { options.fit }

    private var frameIsLocked: Bool { activePreset?.isFrameLocked ?? false }

    private func renderOptions(
        frame: ScreenshotFrame,
        target: ExportTarget,
        sizeOverride: PixelSize?
    ) -> ScreenshotRenderOptions {
        StudioRenderOptions.make(
            frame: frame,
            target: target,
            canvas: canvasStyle,
            paddingPercent: paddingPercent,
            fit: fit.value,
            sizeOverride: sizeOverride
        )
    }

    private var options: ScreenshotRenderOptions {
        renderOptions(frame: displayFrame, target: exportTarget, sizeOverride: sizeOverride)
    }

    private var plan: ScreenshotLayout? {
        guard let shot = selectedShot, let size = shot.pixelSize else { return nil }
        return ScreenshotRenderer.layout(source: size.cgSize, options: options)
    }

    private var report: PreflightReport? {
        guard let shot = selectedShot else { return nil }
        return evaluate(shot: shot, options: options)
    }

    private var isBlocked: Bool { report?.isBlocked ?? false }

    /// Suggested frames first, then the rest. Cross-family stays selectable because a mockup
    /// is a legitimate thing to want; preflight warns instead of the picker refusing.
    private var orderedFrames: [ScreenshotFrame] {
        guard let preset = activePreset, !preset.isFrameLocked else { return ScreenshotFrame.allCases }
        let allowed = preset.allowedFrames
        return allowed + ScreenshotFrame.allCases.filter { !allowed.contains($0) }
    }

    private func frameMenuTitle(_ frame: ScreenshotFrame) -> String {
        guard let preset = activePreset, !preset.allows(frame) else { return frame.title }
        return "\(frame.title) — warns"
    }

    @ViewBuilder
    private func frameMenuRow(_ frame: ScreenshotFrame) -> some View {
        Button {
            choose(frame: frame)
        } label: {
            if frame == displayFrame {
                Label(frameMenuTitle(frame), systemImage: "checkmark")
            } else {
                Text(frameMenuTitle(frame))
            }
        }
    }

    private func frameLockReason(_ preset: StorePreset) -> String {
        preset.allowsBackground
            ? "\(preset.name) accepts only the \(preset.defaultFrame.title) option."
            : "Google Play forbids device frames, backgrounds and masking on Wear OS screenshots."
    }

    private func canvasIsSelectable(_ style: ScreenshotCanvasStyle) -> Bool {
        guard exportTarget.allowsBackground else { return false }
        return !style.isTransparent || exportTarget.allowsAlpha
    }

    private var disabledCanvasReason: String {
        exportTarget.allowsBackground
            ? "App Store Connect and Google Play both reject images containing an alpha channel."
            : "Google Play forbids device frames, backgrounds and masking on Wear OS screenshots."
    }

    private var batchPresets: [StorePreset] {
        StorePresetCatalog.all.filter { batchPresetIDs.contains($0.id) }
    }

    /// One queued image produces one asset per ticked preset, so the per-size-class counts
    /// Apple and Play publish are simply the queue depth.
    private var queuedCounts: [String: Int] {
        guard !shots.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: batchPresetIDs.map { ($0, shots.count) })
    }

    // MARK: - Bindings

    private var fitBinding: Binding<FitPolicy> {
        Binding(
            get: { effectiveFit },
            set: { newValue in fit.choose(newValue) }
        )
    }

    private func sizeBinding(_ preset: StorePreset) -> Binding<PixelSize> {
        Binding(
            get: { sizeOverride ?? preset.pixelSize },
            set: { newValue in
                sizeOverride = preset.accepts(newValue) ? newValue : nil
            }
        )
    }

    private func batchBinding(_ preset: StorePreset) -> Binding<Bool> {
        Binding(
            get: { batchPresetIDs.contains(preset.id) },
            set: { included in
                if included {
                    batchPresetIDs.insert(preset.id)
                } else {
                    batchPresetIDs.remove(preset.id)
                }
            }
        )
    }

    // MARK: - Frame selection

    /// The single writable door to a frame from the UI. `UserChoice.choose` records intent
    /// unconditionally - re-choosing the frame that is already selected is a deliberate
    /// assertion and must lock it exactly as a change would, or the next platform-tagged
    /// capture seeds straight over it.
    private func choose(frame: ScreenshotFrame) {
        if let index = selectedShotIndex {
            shots[index].frame.choose(frame)
        } else {
            // Nothing queued yet, so the choice is about the images to come.
            pendingFrame.choose(frame)
        }
    }

    /// The only way one image's frame reaches another. Explicit, labelled with the frame and
    /// the count, and it locks every shot it touches - there is no implicit propagation.
    private func applyFrameToAllShots() {
        let frame = displayFrame
        for index in shots.indices {
            shots[index].frame.choose(frame)
        }
        pendingFrame.choose(frame)
    }

    // MARK: - Preset selection

    /// Selecting a preset changes the output size and may *seed* a frame and a fit policy.
    /// Both seeds are gated on the user never having touched those controls, so a preset can
    /// fill a blank but can never replace a decision.
    private func select(preset: StorePreset?) {
        // Before the guard on purpose. Clicking the row that is already active is an
        // explicit assertion of the preset, so it has to stop the next capture switching it -
        // the early return used to swallow the intent along with the no-op.
        let changed = presetChoice.value != preset?.id
        presetChoice.choose(preset?.id)
        guard changed else { return }
        sizeOverride = nil
        exportedURL = nil

        if let preset {
            fit.seed(preset.defaultFit)
            let seeded = preset.resolvedDefaultFrame(capturePlatform: selectedShot?.platform)
            if let index = selectedShotIndex {
                // Only the selected shot, and only if its frame is still a seed. Every other
                // queued image keeps the frame it was given.
                shots[index].frame.seed(seeded)
            } else {
                pendingFrame.seed(seeded)
            }
        }
        enforceOpaqueCanvas()
    }

    /// Never a silent swap: the canvas moves off Transparent only with a note saying why.
    private func enforceOpaqueCanvas() {
        guard let preset = activePreset, !preset.allowsAlpha, canvasStyle.isTransparent else { return }
        canvasStyle = .light
        canvasSwitchNote = "Canvas switched from Transparent to Light. \(preset.store.title) rejects images that carry an alpha channel, even when every pixel is opaque."
    }

    // MARK: - Sources

    private func refreshTargets() async {
        isDiscovering = true
        let discovered = await ScreenshotCaptureService.discoverTargets(for: project.platforms)
        targets = discovered
        if !discovered.contains(where: { $0.id == selectedTargetID }) {
            selectedTargetID = discovered.first?.id ?? ""
        }
        isDiscovering = false
    }

    private func captureSelectedTarget() async {
        guard let target = selectedTarget else { return }
        await capture(target)
    }

    private func capture(_ target: ScreenshotTarget) async {
        isCapturing = true
        errorMessage = nil
        defer { isCapturing = false }
        do {
            let url = try await ScreenshotCaptureService.capture(target)
            // The capture's own temp file is the only file this view ever deletes, and it
            // deletes it after reading. Imported and pasted sources are never written to.
            defer { try? FileManager.default.removeItem(at: url) }
            guard let image = NSImage(data: try Data(contentsOf: url)) else { throw ScreenshotCaptureError.invalidImage }
            adopt(image: image, label: target.name, platform: target.platform)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose app screenshots"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var unreadable: [String] = []
        for url in panel.urls {
            // Retain the bytes so later changes to a file cannot change a queued image.
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            importedSourceURLs.insert(url)
            adopt(image: image, label: url.lastPathComponent, platform: nil)
        }
        if !unreadable.isEmpty {
            errorMessage = "Could not read these images: " + unreadable.joined(separator: ", ")
        }
    }

    private func pasteImage() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else {
            errorMessage = "No image is on the clipboard. Copy an image, then choose Paste again."
            return
        }
        adopt(image: image, label: "Clipboard", platform: nil)
    }

    private func adopt(image: NSImage, label: String, platform: PlatformKind?) {
        let size = ScreenshotRenderer.sourcePixelSize(image).map { PixelSize(Int($0.width), Int($0.height)) }
        var shot = StudioShot(image: image, label: label, platform: platform, pixelSize: size)
        seedFrame(of: &shot)
        shots.append(shot)
        selectedShotID = shot.id
        exportedURL = nil
        batchOutcomes = []
        seedPreset(for: shot)
    }

    /// Runs once, on the shot being added, and never again. It writes only to the new shot,
    /// so no capture can reach an existing shot's frame - that is the per-shot form of the
    /// guarantee that a chosen frame is never overwritten.
    private func seedFrame(of shot: inout StudioShot) {
        guard !pendingFrame.isUserChosen else {
            // A frame chosen before anything was queued is a real decision about the images
            // to come, so the new shot inherits it already locked rather than being seeded
            // from its own platform on top of it.
            shot.frame = pendingFrame
            return
        }
        guard let platform = shot.platform else {
            shot.frame.seed(pendingFrame.value)
            return
        }
        shot.frame.seed(ScreenshotCaptureService.suggestedFrame(for: platform, sourceSize: shot.pixelSize?.cgSize))
    }

    private func seedPreset(for shot: StudioShot) {
        guard let platform = shot.platform else { return }
        let suggested = StorePresetCatalog.suggested(for: platform)
        guard presetChoice.seed(suggested.id) else { return }
        sizeOverride = nil
        fit.seed(suggested.defaultFit)
        enforceOpaqueCanvas()
    }

    private func remove(_ shot: StudioShot) {
        shots.removeAll { $0.id == shot.id }
        if selectedShotID == shot.id {
            selectedShotID = shots.first?.id
        }
        batchOutcomes = []
    }

    private func refreshPreview() {
        guard let shot = selectedShot else {
            previewImage = nil
            return
        }
        do {
            previewImage = try ScreenshotRenderer.renderedImage(
                image: shot.image,
                options: options,
                chrome: .safeAreaGuide,
                maxPixelDimension: 1600
            )
        } catch {
            previewImage = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Preflight plumbing

    private func facts(for shot: StudioShot) -> SourceImageFacts? {
        guard let size = shot.pixelSize else { return nil }
        let rep = shot.image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        return SourceImageFacts(
            size: size,
            bitsPerSample: rep?.bitsPerSample ?? 8,
            colourModel: rep.map(colourModel(of:)) ?? .rgb,
            platform: shot.platform
        )
    }

    private func colourModel(of rep: NSBitmapImageRep) -> SourceColourModel {
        switch rep.colorSpace.colorSpaceModel {
        case .rgb: .rgb
        case .gray: .grayscale
        case .cmyk: .cmyk
        default: .unknown
        }
    }

    private func evaluate(shot: StudioShot, options: ScreenshotRenderOptions) -> PreflightReport? {
        guard let facts = facts(for: shot) else { return nil }
        let plan = ScreenshotRenderer.layout(source: facts.size.cgSize, options: options)
        return ScreenshotPreflight.evaluate(PreflightInput(
            target: options.target,
            source: facts,
            options: PreflightOptions(
                frame: options.resolvedFrame,
                fit: options.resolvedFit,
                canvasIsTransparent: options.canvas.isTransparent,
                paddingPercent: Double(options.resolvedPaddingPercent),
                outputSizeOverride: options.sizeOverride
            ),
            layout: PreflightLayout(
                canvas: PixelSize(Int(plan.canvas.width), Int(plan.canvas.height)),
                screenWidth: plan.screenRect.width,
                screenHeight: plan.screenRect.height
            ),
            queuedCountsByPresetID: queuedCounts
        ))
    }

    private func canApply(_ fix: PreflightFix) -> Bool {
        switch fix {
        case .useOpaqueCanvas:
            return exportTarget.allowsBackground
        case .useFit:
            return !fitIsLocked && !options.paddingApplies
        case .useFrame:
            return !frameIsLocked
        case .usePadding:
            return options.paddingApplies && exportTarget.allowsBackground
        case .useOutputSize(let size):
            return activePreset?.accepts(size) ?? false
        case .recaptureOn(let platform):
            return targets.contains { $0.platform == platform }
        }
    }

    private func apply(_ fix: PreflightFix) {
        switch fix {
        case .useOpaqueCanvas:
            canvasStyle = .light
            canvasSwitchNote = nil
        case .useFit(let policy):
            fit.choose(policy)
        case .useFrame(let frame):
            // A preflight fix is the user tapping a button, so it counts as their choice -
            // for the selected shot, which is the one the report was computed against.
            choose(frame: frame)
        case .usePadding(let percent):
            paddingPercent = min(max(percent, 0), 20)
        case .useOutputSize(let size):
            if activePreset?.accepts(size) == true { sizeOverride = size }
        case .recaptureOn(let platform):
            // Points Capture at the other platform. It deliberately does not touch the frame.
            if let target = targets.first(where: { $0.platform == platform }) {
                selectedTargetID = target.id
            }
        }
    }

    // MARK: - Export

    private func exportPNG() {
        guard let shot = selectedShot else { return }
        let panel = NSSavePanel()
        panel.title = "Export framed screenshot"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = activePreset
            .map { ScreenshotBatchNaming.filename(project: project.name, preset: $0, index: 1) }
            ?? ScreenshotBatchNaming.freeFilename(project: project.name, frame: options.resolvedFrame)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let job = ScreenshotExportJob(
            image: shot.image, options: options, destination: url,
            protectedSources: importedSourceURLs, blockingReason: report?.blockingReason
        )
        isExportingPNG = true
        exportTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                autoreleasepool { job.write() }
            }.value
            isExportingPNG = false
            if outcome.succeeded {
                exportedURL = url
                batchOutcomes = []
            } else {
                errorMessage = outcome.message
            }
            exportTask = nil
        }
    }

    private func batchJobs(into directory: URL) -> [ScreenshotExportJob] {
        batchPresets.flatMap { preset in
            let limit = preset.store.maximumAssetsPerClass
            return shots.enumerated().map { offset, shot in
                let index = offset + 1
                // Resolve all settings now, including variants and each shot's own frame.
                let options = renderOptions(
                    frame: shot.frame.value, target: .preset(preset),
                    sizeOverride: preset.id == presetChoice.value ? sizeOverride : nil
                )
                let reason = index > limit
                    ? "\(preset.store.title) accepts at most \(limit) assets per size class per localization; this would be number \(index)."
                    : evaluate(shot: shot, options: options)?.blockingReason
                let filename = ScreenshotBatchNaming.filename(project: project.name, preset: preset, index: index)
                return ScreenshotExportJob(
                    image: shot.image, options: options,
                    destination: directory.appendingPathComponent(filename),
                    protectedSources: importedSourceURLs, blockingReason: reason
                )
            }
        }
    }

    private func exportBatch() {
        guard !shots.isEmpty, !batchPresets.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the batch"
        panel.message = "Existing exports with matching names will be replaced. Imported source images are protected."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let jobs = batchJobs(into: directory)
        isExportingBatch = true
        batchWasStopped = false
        batchTotal = jobs.count
        batchDirectory = directory
        batchOutcomes = []
        exportedURL = nil
        exportTask = Task { @MainActor in
            for job in jobs {
                guard !Task.isCancelled else { break }
                // Serial background rendering keeps the window responsive without retaining
                // several full-resolution output bitmaps at once.
                let outcome = await Task.detached(priority: .userInitiated) {
                    autoreleasepool { job.write() }
                }.value
                batchOutcomes.append(outcome)
            }
            isExportingBatch = false
            exportTask = nil
        }
    }

    // MARK: - Small helpers

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
