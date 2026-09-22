import AppKit
import Foundation

// The five frames live in StorePresets.swift so the catalogue and the renderer cannot drift
// apart about what a frame is; this alias keeps the renderer's own vocabulary intact.
typealias ScreenshotFrameStyle = ScreenshotFrame

enum ScreenshotCanvasStyle: String, CaseIterable, Identifiable {
    case transparent
    case light
    case dark
    case accent

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var isTransparent: Bool { self == .transparent }

    var color: NSColor {
        switch self {
        case .transparent: .clear
        case .light: NSColor(calibratedWhite: 0.96, alpha: 1)
        case .dark: NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.07, alpha: 1)
        case .accent: NSColor(calibratedRed: 0.88, green: 0.97, blue: 0.97, alpha: 1)
        }
    }
}

struct ScreenshotRenderOptions: Equatable {
    /// What the export is aimed at. `.free` keeps the pre-rebuild behaviour: the canvas is
    /// derived from the capture and a transparent canvas is allowed. A preset makes the
    /// canvas exact and forbids alpha.
    var target: ExportTarget = .free
    var frame: ScreenshotFrameStyle = .iphone
    var canvas: ScreenshotCanvasStyle = .accent
    /// Gap between the device and the canvas edge, as a percentage of the canvas short edge.
    /// It is the spacing *around the device*, so it only bites when a frame is drawn - see
    /// `paddingApplies`.
    var paddingPercent: CGFloat = 6
    /// Frameless fitting only. `stretch` does not exist: a distorted store screenshot is
    /// never the right answer, and offering it guarantees someone ships one.
    var fit: FitPolicy = .fitPad
    /// The capture is never enlarged past this multiple of its native width. This is what
    /// makes a 750px legacy capture in a 2064px iPad canvas come out small and obviously
    /// wrong instead of silently soft and full-bleed.
    var maxUpscale: CGFloat = 1
    /// One of the preset's equally-accepted alternate sizes. Ignored unless the preset
    /// actually accepts it, so an illegal size cannot be smuggled through this door.
    var sizeOverride: PixelSize?

    var preset: StorePreset? { target.preset }

    /// Presets that allow exactly one frame (Wear OS, Mac, TV) override the user's choice.
    /// Everything else keeps it: a cross-family mockup is a legitimate thing to want, and
    /// preflight warns about it rather than preventing it.
    var resolvedFrame: ScreenshotFrameStyle {
        guard let preset, preset.isFrameLocked, !preset.allows(frame) else { return frame }
        return preset.defaultFrame
    }

    /// Play forbids added backgrounds on Wear OS screenshots, so that padding is not the
    /// user's to set.
    var resolvedPaddingPercent: CGFloat { target.allowsBackground && paddingApplies ? paddingPercent : 0 }

    /// Without a frame there is no device to inset, so the bars a fitted capture leaves are
    /// purely the aspect mismatch - which is what the preflight messages quote in pixels.
    var paddingApplies: Bool { resolvedFrame != .none }

    /// Both stores reject an alpha channel even when every pixel is opaque, so a preset
    /// export is composited onto an opaque canvas whatever the picker says. The UI also
    /// switches away from Transparent when a preset is chosen; this is the belt to that pair
    /// of braces.
    var resolvedCanvas: ScreenshotCanvasStyle {
        canvas.isTransparent && !target.allowsAlpha ? .light : canvas
    }

    /// True only in Free mode with a transparent canvas - the one place alpha is meaningful.
    var preservesAlpha: Bool { resolvedCanvas.isTransparent }
}

/// Chrome that exists only on screen.
///
/// Deliberately NOT a field on `ScreenshotRenderOptions`: options are what the export path
/// carries, so anything living there can reach an exported file, and "remember not to draw
/// the guide when exporting" is exactly the kind of rule that survives one refactor. Instead
/// this travels as an argument to `renderedImage` alone — `render` and `pngData` pass
/// `.none` as a literal and expose no parameter, so there is no code path from an export to
/// a drawn guide.
enum ScreenshotPreviewChrome: String, CaseIterable, Hashable, Sendable {
    case none
    /// The dashed feature-graphic safe-area and edge-cutoff guides.
    case safeAreaGuide
}

/// Everything the renderer decided, in output pixels, before a single pixel was drawn.
/// Pure geometry: preflight and the tests read it without rasterising anything, and it is
/// the single place any rounding happens.
struct ScreenshotLayout: Equatable {
    /// Exactly `preset.pixelSize` for a preset export. Derived from the capture in Free mode.
    let canvas: CGSize
    /// Where the capture lands.
    let screenRect: CGRect
    /// The shell. Equal to `screenRect` when no frame is drawn.
    let boxRect: CGRect
    /// The region of the capture that is drawn, in source pixels. Smaller than the source
    /// only under `fillCrop`.
    let sourceRect: CGRect
    let bezel: CGFloat
    let screenRadius: CGFloat
    /// Always `screenRadius + bezel`. Non-concentric corners are the single thing that makes
    /// a hand-drawn frame read as fake, so this is computed and never authored.
    let outerRadius: CGFloat
    /// Rendered screen width ÷ drawn source width. > 1 means the capture is being enlarged.
    let upscale: CGFloat
    /// The fit left the device too small to read and the minimum-readable-size rule enlarged
    /// it past `maxUpscale`. Not the same question as "is the capture being enlarged" - read
    /// `upscale` for that.
    let isEnlargedForReadability: Bool
    /// Fraction of the source discarded by `fillCrop`. 0 whenever nothing was cropped.
    let croppedFraction: CGFloat
    /// Feature graphic only: sides on which the device box reaches into the outer 6% band
    /// Play crops in some homepage formats. Always empty for every other layout, because no
    /// other asset is cropped by the store.
    let cutoffEdges: [FeatureGraphicLayout.Edge]

    /// Present when the device strays into Play's feature-graphic edge cutoff band.
    var cutoffWarning: String? { FeatureGraphicLayout.cutoffWarning(edges: cutoffEdges) }

    /// Canvas colour visible on each vertical edge, in output pixels.
    var horizontalBar: CGFloat { max(0, (canvas.width - boxRect.width) / 2) }
    /// Canvas colour visible on each horizontal edge, in output pixels.
    var verticalBar: CGFloat { max(0, (canvas.height - boxRect.height) / 2) }
}

enum ScreenshotRendererError: LocalizedError {
    case invalidSource
    case renderFailed
    case alphaChannelRejected(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidSource: "The source screenshot has no readable pixel dimensions."
        case .renderFailed: "The framed screenshot could not be rendered."
        case let .alphaChannelRejected(colorType):
            "The encoded PNG carries an alpha channel (colour type \(colorType)). "
                + "App Store Connect and Google Play reject those even when every pixel is opaque."
        }
    }
}

enum ScreenshotRenderer {
    static func sourcePixelSize(_ image: NSImage) -> CGSize? {
        let representations = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        if let best = representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return CGSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size
    }

    static func outputPixelSize(source: CGSize, options: ScreenshotRenderOptions) -> CGSize {
        layout(source: source, options: options).canvas
    }

    // The one place a framed screenshot is rasterised. Both the preview and the export start
    // here, so they cannot drift; only the export goes on to flatten and encode a PNG.
    //
    // Every export entry point calls this overload, which has no way to ask for preview
    // chrome: the guide argument exists on the private rasteriser and on `renderedImage`,
    // and nowhere else.
    static func render(image: NSImage, options: ScreenshotRenderOptions) throws -> NSBitmapImageRep {
        try rasterise(image: image, options: options, chrome: .none)
    }

    private static func rasterise(
        image: NSImage,
        options: ScreenshotRenderOptions,
        chrome: ScreenshotPreviewChrome,
        maxPixelDimension: CGFloat? = nil
    ) throws -> NSBitmapImageRep {
        guard let sourceSize = sourcePixelSize(image) else { throw ScreenshotRendererError.invalidSource }
        let plan = layout(source: sourceSize, options: options)
        // Lay out in export pixels, then rasterise the same composition at display size.
        // Export never passes a limit, so its dimensions and source quality stay intact.
        let longestEdge = max(plan.canvas.width, plan.canvas.height)
        let scale = min(1, max(1, maxPixelDimension ?? longestEdge) / longestEdge)
        // RGBA even when the export must not carry alpha: antialiased frame corners and the
        // drop shadow need a real alpha buffer mid-render. It is flattened before encoding.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int((plan.canvas.width * scale).rounded())),
            pixelsHigh: max(1, Int((plan.canvas.height * scale).rounded())),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ScreenshotRendererError.renderFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(
            x: CGFloat(bitmap.pixelsWide) / plan.canvas.width,
            y: CGFloat(bitmap.pixelsHigh) / plan.canvas.height
        )
        draw(image: image, source: sourceSize, plan: plan, options: options, chrome: chrome, shadowScale: scale)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap
    }

    static func render(image: NSImage, preset: StorePreset?, options: ScreenshotRenderOptions) throws -> NSBitmapImageRep {
        var options = options
        options.target = preset.map(ExportTarget.preset) ?? .free
        return try render(image: image, options: options)
    }

    static func pngData(image: NSImage, options: ScreenshotRenderOptions) throws -> Data {
        let bitmap = try render(image: image, options: options)
        guard !options.preservesAlpha else {
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw ScreenshotRendererError.renderFailed
            }
            return data
        }
        let flattened = try flattened(bitmap, over: options.resolvedCanvas.color)
        guard let data = flattened.representation(using: .png, properties: [:]) else {
            throw ScreenshotRendererError.renderFailed
        }
        try assertNoAlpha(data)
        return data
    }

    static func pngData(image: NSImage, preset: StorePreset?, options: ScreenshotRenderOptions) throws -> Data {
        var options = options
        options.target = preset.map(ExportTarget.preset) ?? .free
        return try pngData(image: image, options: options)
    }

    // The preview wraps the bitmap directly. It used to encode a PNG and decode it straight
    // back - roughly 26 MB through the codec twice for a phone-sized capture, on the main
    // actor, for every tick of the padding slider.
    //
    // This is the only entry point that can draw preview chrome, and the only caller that
    // asks for it is the studio's preview pane. The default is `.none` on purpose: chrome
    // must be opted into by the preview, never inherited by a caller that writes to disk.
    static func renderedImage(
        image: NSImage,
        options: ScreenshotRenderOptions,
        chrome: ScreenshotPreviewChrome = .none,
        maxPixelDimension: CGFloat? = nil
    ) throws -> NSImage {
        let bitmap = try rasterise(image: image, options: options, chrome: chrome, maxPixelDimension: maxPixelDimension)
        let result = NSImage(size: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        result.addRepresentation(bitmap)
        return result
    }

    // MARK: - Alpha

    /// PNG colour type from the IHDR header, or nil if this is not a PNG.
    /// 0 grey, 2 truecolour, 3 indexed, 4 grey+alpha, 6 truecolour+alpha.
    static func pngColorType(_ data: Data) -> UInt8? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let header = [UInt8](data.prefix(26))
        guard header.count == 26,
              Array(header[0..<8]) == signature,
              Array(header[12..<16]) == Array("IHDR".utf8) else { return nil }
        return header[25]
    }

    /// The last line of defence before a rejection the user discovers weeks later. Both
    /// stores reject an image carrying an alpha channel even when every pixel is fully
    /// opaque - the presence of the channel is the failure, not visible transparency.
    static func assertNoAlpha(_ data: Data) throws {
        guard let colorType = pngColorType(data) else { throw ScreenshotRendererError.renderFailed }
        guard colorType != 4, colorType != 6 else {
            throw ScreenshotRendererError.alphaChannelRejected(colorType)
        }
    }

    /// Converts to sRGB and flattens into a 24-bit rep, which PNG-encodes as colour type 2.
    /// The render itself has to be RGBA - antialiased corners and the drop shadow need a real
    /// alpha buffer - so the flatten happens after, and it copies samples rather than drawing:
    /// CGBitmapContext has no 24-bit packed RGB format, so `NSGraphicsContext` cannot be
    /// created over the destination rep at all.
    private static func flattened(_ bitmap: NSBitmapImageRep, over background: NSColor) throws -> NSBitmapImageRep {
        let converted = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
        // The conversion is expected to stay 8-bit RGBA; anything else gets normalised
        // through a format a graphics context can actually back.
        let source = try rgba8(converted)
        guard let input = source.bitmapData else { throw ScreenshotRendererError.renderFailed }

        let width = source.pixelsWide
        let height = source.pixelsHigh
        guard let opaque = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let output = opaque.bitmapData else {
            throw ScreenshotRendererError.renderFailed
        }

        let canvas = (background.alphaComponent > 0 ? background : .white)
            .usingColorSpace(.sRGB) ?? .white
        let fill = (
            UInt8(clamping: Int((canvas.redComponent * 255).rounded())),
            UInt8(clamping: Int((canvas.greenComponent * 255).rounded())),
            UInt8(clamping: Int((canvas.blueComponent * 255).rounded()))
        )
        let alphaFirst = source.bitmapFormat.contains(.alphaFirst)
        let premultiplied = !source.bitmapFormat.contains(.alphaNonpremultiplied)
        let colorOffset = alphaFirst ? 1 : 0
        let alphaOffset = alphaFirst ? 0 : 3

        for row in 0..<height {
            let inRow = input + row * source.bytesPerRow
            let outRow = output + row * opaque.bytesPerRow
            for column in 0..<width {
                let pixel = inRow + column * 4
                let target = outRow + column * 3
                let alpha = Int(pixel[alphaOffset])
                for channel in 0..<3 {
                    let raw = Int(pixel[colorOffset + channel])
                    let over = premultiplied ? raw : raw * alpha / 255
                    let under = Int(channel == 0 ? fill.0 : (channel == 1 ? fill.1 : fill.2))
                    target[channel] = UInt8(clamping: over + under * (255 - alpha) / 255)
                }
            }
        }

        // The samples are literally sRGB now, so retagging labels them correctly without
        // touching a byte. `.deviceRGB` above is only what the initialiser accepts.
        return opaque.retagging(with: source.colorSpace) ?? opaque
    }

    /// A non-planar 8-bit RGBA rep, which is the only layout `flattened` reads.
    private static func rgba8(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        if !rep.isPlanar, rep.bitsPerSample == 8, rep.samplesPerPixel == 4, rep.bitsPerPixel == 32 {
            return rep
        }
        guard let normalised = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: normalised) else {
            throw ScreenshotRendererError.renderFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        rep.draw(in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return normalised
    }

    // MARK: - Layout

    /// The inversion this rebuild exists for: the canvas comes from the preset, and the
    /// device is laid out inside it. Nothing here derives an output dimension from the
    /// capture unless the export is in Free mode.
    static func layout(source rawSource: CGSize, options: ScreenshotRenderOptions) -> ScreenshotLayout {
        let source = CGSize(
            width: max(1, rawSource.width.rounded()),
            height: max(1, rawSource.height.rounded())
        )
        let frame = options.resolvedFrame
        let metrics = FrameMetrics.of(frame)
        let padding = min(max(options.resolvedPaddingPercent, 0), 20)

        guard let canvas = presetCanvas(options) else {
            return freeLayout(source: source, metrics: metrics, padding: padding)
        }
        if options.preset?.usesFeatureGraphicLayout == true {
            return featureGraphicLayout(source: source, canvas: canvas, metrics: metrics)
        }
        guard frame != .none else {
            return framelessLayout(source: source, canvas: canvas, fit: options.fit)
        }
        return framedLayout(
            source: source,
            canvas: canvas,
            metrics: metrics,
            padding: padding,
            maxUpscale: max(0.01, options.maxUpscale)
        )
    }

    private static func presetCanvas(_ options: ScreenshotRenderOptions) -> CGSize? {
        guard let preset = options.preset else { return nil }
        let size = options.sizeOverride.flatMap { preset.accepts($0) ? $0 : nil } ?? preset.pixelSize
        return size.cgSize
    }

    /// Free mode: the capture is drawn at native size and the canvas grows to hold it. The
    /// only mode where an output dimension is an accident of the booted device - which is
    /// exactly why no store preset uses it.
    private static func freeLayout(source: CGSize, metrics: FrameMetrics, padding: CGFloat) -> ScreenshotLayout {
        let bezel = metrics.isDrawn ? max(2, (metrics.bezel * min(source.width, source.height)).rounded()) : 0
        let box = CGSize(width: source.width + bezel * 2, height: source.height + bezel * 2)
        let margin = (max(box.width, box.height) * padding / 100).rounded()
        let canvas = CGSize(width: box.width + margin * 2, height: box.height + margin * 2)
        let boxRect = centred(box, in: canvas)
        let screenRect = boxRect.insetBy(dx: bezel, dy: bezel)
        let radius = metrics.screenRadius * min(screenRect.width, screenRect.height)
        return ScreenshotLayout(
            canvas: canvas,
            screenRect: screenRect,
            boxRect: boxRect,
            sourceRect: CGRect(origin: .zero, size: source),
            bezel: bezel,
            screenRadius: radius,
            outerRadius: radius + bezel,
            upscale: 1,
            isEnlargedForReadability: false,
            croppedFraction: 0,
            cutoffEdges: []
        )
    }

    /// §2.5. Google Play's feature graphic is 1024 × 500 landscape, it is mandatory to
    /// publish, and the source is almost always a portrait phone capture — a 1:2.05 aspect
    /// into a 2.05:1 canvas. Centring a device there produces a postage stamp in a wide empty
    /// field, so this is the one composition in the tool that is authored rather than fitted:
    /// a tall device right of centre with the left of the canvas left empty for the
    /// developer's own text and logo.
    private static func featureGraphicLayout(
        source: CGSize,
        canvas: CGSize,
        metrics: FrameMetrics
    ) -> ScreenshotLayout {
        let ratio = source.height / source.width
        let basis = min(1, ratio)
        let unitBezel = metrics.isDrawn ? metrics.bezel * basis : 0
        let unitWidth = 1 + unitBezel * 2
        let unitHeight = ratio + unitBezel * 2

        // The device is 0.82 of the canvas height…
        var width = FeatureGraphicLayout.deviceHeightFraction * canvas.height / unitHeight
        // …except that the left 55% is reserved and the tool draws nothing into it. A box too
        // wide for the remaining strip is scaled down to fit it rather than bled arbitrarily
        // off the right: the spec permits a bleed, it does not require one, and a device
        // running a third of its width off the canvas reads as a bug rather than a choice.
        // For the portrait capture this mode exists for, neither clamp bites.
        let strip = canvas.width * (1 - FeatureGraphicLayout.safeAreaWidthFraction)
        width = min(width, max(1, strip) / unitWidth)

        let screenWidth = max(1, width.rounded(.down))
        let screenHeight = max(1, (screenWidth * ratio).rounded())
        let bezel = metrics.isDrawn ? max(2, (metrics.bezel * min(screenWidth, screenHeight)).rounded()) : 0
        let box = CGSize(width: screenWidth + bezel * 2, height: screenHeight + bezel * 2)

        // Leading edge anchored at 0.62 W, pulled left only far enough to keep the device on
        // the canvas, and never past the safe-area boundary — that clamp is the invariant,
        // the anchor is the preference.
        let safeEdge = (canvas.width * FeatureGraphicLayout.safeAreaWidthFraction).rounded()
        let anchor = (canvas.width * FeatureGraphicLayout.deviceAnchorXFraction).rounded()
        let originX = max(safeEdge, min(anchor, canvas.width - box.width))
        let boxRect = CGRect(
            x: originX.rounded(),
            y: ((canvas.height - box.height) / 2).rounded(),
            width: box.width,
            height: box.height
        )
        let screenRect = boxRect.insetBy(dx: bezel, dy: bezel)
        let radius = metrics.screenRadius * min(screenRect.width, screenRect.height)

        return ScreenshotLayout(
            canvas: canvas,
            screenRect: screenRect,
            boxRect: boxRect,
            sourceRect: CGRect(origin: .zero, size: source),
            bezel: bezel,
            screenRadius: radius,
            outerRadius: radius + bezel,
            upscale: screenRect.width / source.width,
            isEnlargedForReadability: false,
            croppedFraction: 0,
            cutoffEdges: FeatureGraphicLayout.cutoffOverlaps(deviceBox: boxRect, canvas: canvas)
        )
    }

    /// No frame, so the canvas cannot absorb the aspect mismatch and one of the two honest
    /// fit policies has to. Padding does not apply: the bars here are the mismatch itself.
    private static func framelessLayout(source: CGSize, canvas: CGSize, fit: FitPolicy) -> ScreenshotLayout {
        let widthScale = canvas.width / source.width
        let heightScale = canvas.height / source.height
        switch fit {
        case .fitPad:
            let scale = min(widthScale, heightScale)
            let drawn = CGSize(
                width: max(1, (source.width * scale).rounded()),
                height: max(1, (source.height * scale).rounded())
            )
            let rect = centred(drawn, in: canvas)
            return ScreenshotLayout(
                canvas: canvas,
                screenRect: rect,
                boxRect: rect,
                sourceRect: CGRect(origin: .zero, size: source),
                bezel: 0,
                screenRadius: 0,
                outerRadius: 0,
                upscale: rect.width / source.width,
                isEnlargedForReadability: false,
                croppedFraction: 0,
                cutoffEdges: []
            )
        case .fillCrop:
            let scale = max(widthScale, heightScale)
            let visible = CGSize(
                width: max(1, min(source.width, (canvas.width / scale).rounded())),
                height: max(1, min(source.height, (canvas.height / scale).rounded()))
            )
            let sourceRect = centred(visible, in: source)
            let rect = CGRect(origin: .zero, size: canvas)
            let kept = (visible.width * visible.height) / (source.width * source.height)
            return ScreenshotLayout(
                canvas: canvas,
                screenRect: rect,
                boxRect: rect,
                sourceRect: sourceRect,
                bezel: 0,
                screenRadius: 0,
                outerRadius: 0,
                upscale: rect.width / visible.width,
                isEnlargedForReadability: false,
                croppedFraction: max(0, 1 - kept),
                cutoffEdges: []
            )
        }
    }

    /// The key insight of the rebuild: a framed export never crops, pads or distorts. The
    /// capture's aspect ratio is preserved exactly inside the frame's screen rect and the
    /// canvas absorbs 100% of the mismatch as background - which is what every good store
    /// screenshot looks like anyway.
    private static func framedLayout(
        source: CGSize,
        canvas: CGSize,
        metrics: FrameMetrics,
        padding: CGFloat,
        maxUpscale: CGFloat
    ) -> ScreenshotLayout {
        // Everything below is in units of the rendered screen width, so the whole device box
        // is one number. The bezel is a fraction of the screen's SHORT edge: §4's metrics are
        // physical device proportions, and driving them from the width would give a landscape
        // render absurdly fat bezels and round corners.
        let ratio = source.height / source.width
        let basis = min(1, ratio)
        let unitBezel = metrics.bezel * basis
        let unitWidth = 1 + unitBezel * 2
        let unitHeight = ratio + unitBezel * 2

        let margin = padding / 100 * min(canvas.width, canvas.height)
        let usable = CGSize(
            width: max(1, canvas.width - margin * 2),
            height: max(1, canvas.height - margin * 2)
        )
        var width = min(usable.width / unitWidth, usable.height / unitHeight)
        // Never enlarge the capture past native: a small capture in a large canvas should
        // look small and wrong, not soft and full-bleed.
        width = min(width, maxUpscale * source.width)

        // ...unless it lands so small it cannot be read, in which case enlarging it and
        // saying so is more useful than shipping a postage stamp. Clamped to the canvas
        // rather than the usable rect, because a clipped device is worse than a tight one.
        var forced = false
        if width * unitWidth < 0.55 * canvas.width {
            let readable = min(
                0.55 * canvas.width / unitWidth,
                min(canvas.width / unitWidth, canvas.height / unitHeight)
            )
            if readable > width {
                width = readable
                forced = true
            }
        }

        let screenWidth = max(1, width.rounded())
        let screenHeight = max(1, (screenWidth * ratio).rounded())
        let bezel = max(2, (metrics.bezel * min(screenWidth, screenHeight)).rounded())
        let box = CGSize(width: screenWidth + bezel * 2, height: screenHeight + bezel * 2)
        let boxRect = centred(box, in: canvas)
        let screenRect = boxRect.insetBy(dx: bezel, dy: bezel)
        let radius = metrics.screenRadius * min(screenRect.width, screenRect.height)

        return ScreenshotLayout(
            canvas: canvas,
            screenRect: screenRect,
            boxRect: boxRect,
            sourceRect: CGRect(origin: .zero, size: source),
            bezel: bezel,
            screenRadius: radius,
            outerRadius: radius + bezel,
            upscale: screenRect.width / source.width,
            isEnlargedForReadability: forced,
            croppedFraction: 0,
            cutoffEdges: []
        )
    }

    private static func centred(_ size: CGSize, in container: CGSize) -> CGRect {
        CGRect(
            x: ((container.width - size.width) / 2).rounded(),
            y: ((container.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Drawing

    private static func draw(
        image: NSImage,
        source: CGSize,
        plan: ScreenshotLayout,
        options: ScreenshotRenderOptions,
        chrome: ScreenshotPreviewChrome,
        shadowScale: CGFloat
    ) {
        let canvasStyle = options.resolvedCanvas
        let canvasRect = CGRect(origin: .zero, size: plan.canvas)
        canvasStyle.color.setFill()
        canvasRect.fill(using: canvasStyle.isTransparent ? .copy : .sourceOver)

        let frame = options.resolvedFrame
        let metrics = FrameMetrics.of(frame)

        if metrics.isDrawn {
            let shell = NSBezierPath(
                roundedRect: plan.boxRect,
                xRadius: plan.outerRadius,
                yRadius: plan.outerRadius
            )
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.32)
            // NSShadow uses bitmap pixels; the context transform scales paths but not
            // its blur or offset. Apply the preview scale explicitly to match the export.
            shadow.shadowBlurRadius = plan.boxRect.width * 0.018 * shadowScale
            shadow.shadowOffset = CGSize(width: 0, height: -plan.boxRect.width * 0.008 * shadowScale)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            metrics.shell.setFill()
            shell.fill()
            NSGraphicsContext.restoreGraphicsState()

            drawButtons(metrics.buttons, in: plan.boxRect, color: metrics.button)
        }

        NSGraphicsContext.saveGraphicsState()
        if plan.screenRadius > 0 {
            NSBezierPath(
                roundedRect: plan.screenRect,
                xRadius: plan.screenRadius,
                yRadius: plan.screenRadius
            ).addClip()
        }
        image.draw(
            in: plan.screenRect,
            from: imageRect(for: plan.sourceRect, image: image, source: source),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        defer {
            // Last, so the guides sit over the device, and only ever on the preview: this is
            // the sole call site and `chrome` can only be `.safeAreaGuide` when the caller
            // came through `renderedImage`.
            if chrome == .safeAreaGuide, options.preset?.usesFeatureGraphicLayout == true {
                drawFeatureGraphicGuides(canvas: plan.canvas)
            }
        }

        guard metrics.isDrawn else { return }

        // A hairline seam where the display meets the shell. Any thicker and it reads as a
        // drawn outline rather than the edge of a screen.
        let seam = NSBezierPath(
            roundedRect: plan.screenRect,
            xRadius: plan.screenRadius,
            yRadius: plan.screenRadius
        )
        NSColor.black.withAlphaComponent(0.92).setStroke()
        seam.lineWidth = 1
        seam.stroke()

        drawCamera(metrics.camera, screen: plan.screenRect, bezel: plan.bezel)
    }

    /// §2.5's guides: the reserved text and logo area on the left, and the outer band Play
    /// crops in some homepage formats. Preview only — see `ScreenshotPreviewChrome`. They are
    /// strokes, never fills, so they never obscure the composition underneath, and each is
    /// drawn twice with offset dash phases in white then black so it stays legible on a light
    /// canvas, a dark canvas and the device itself.
    private static func drawFeatureGraphicGuides(canvas: CGSize) {
        let unit = max(1, (min(canvas.width, canvas.height) * 0.004).rounded())
        var dash: [CGFloat] = [unit * 4, unit * 4]

        for rect in [
            FeatureGraphicLayout.safeArea(in: canvas),
            FeatureGraphicLayout.uncroppedArea(in: canvas),
        ] where rect.width > 0 && rect.height > 0 {
            // Inset by half a line width so the stroke lands inside the region it describes
            // rather than straddling its edge.
            let path = NSBezierPath(rect: rect.insetBy(dx: unit / 2, dy: unit / 2))
            path.lineWidth = unit
            path.setLineDash(&dash, count: dash.count, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke()
            path.stroke()
            path.setLineDash(&dash, count: dash.count, phase: dash[0])
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.stroke()
        }
    }

    /// `from:` is in the image's own coordinate space, which is points, not pixels.
    private static func imageRect(for sourceRect: CGRect, image: NSImage, source: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0, source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: image.size)
        }
        let x = image.size.width / source.width
        let y = image.size.height / source.height
        return CGRect(
            x: sourceRect.minX * x,
            y: sourceRect.minY * y,
            width: sourceRect.width * x,
            height: sourceRect.height * y
        )
    }

    private static func drawButtons(_ style: FrameMetrics.Buttons, in box: CGRect, color: NSColor) {
        let unit = box.width * 0.008
        guard unit > 0 else { return }
        let radius = unit * 0.45
        color.setFill()

        func pill(_ rect: CGRect) {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }

        switch style {
        case .iphone:
            // Two on the left, one on the right - the silhouette that separates an iPhone
            // from an Android phone at a glance.
            pill(CGRect(x: box.minX, y: box.minY + box.height * 0.62, width: unit, height: box.height * 0.085))
            pill(CGRect(x: box.minX, y: box.minY + box.height * 0.73, width: unit, height: box.height * 0.055))
            pill(CGRect(x: box.maxX - unit, y: box.minY + box.height * 0.64, width: unit, height: box.height * 0.12))
        case .androidPhone:
            pill(CGRect(x: box.maxX - unit, y: box.minY + box.height * 0.66, width: unit, height: box.height * 0.12))
            pill(CGRect(x: box.maxX - unit, y: box.minY + box.height * 0.80, width: unit, height: box.height * 0.06))
        case .ipad:
            let thickness = box.height * 0.006
            pill(CGRect(x: box.minX + box.width * 0.78, y: box.maxY - thickness, width: box.width * 0.10, height: thickness))
            pill(CGRect(x: box.maxX - unit, y: box.minY + box.height * 0.72, width: unit, height: box.height * 0.05))
            pill(CGRect(x: box.maxX - unit, y: box.minY + box.height * 0.79, width: unit, height: box.height * 0.05))
        case .none:
            break
        }
    }

    /// Camera geometry is authored for a portrait device. In a landscape render the cutout
    /// moves to the left edge, which is where it physically is once the device is rotated;
    /// modelling anything more of a rotated device is out of scope.
    private static func drawCamera(_ style: FrameMetrics.Camera, screen: CGRect, bezel: CGFloat) {
        let basis = min(screen.width, screen.height)
        let isLandscape = screen.width > screen.height

        switch style {
        case .island:
            // Measured off an iPhone 16 Pro: a 402pt-wide display carrying a 125 × 36.7pt
            // Dynamic Island whose top edge sits 11pt below the top of the display. That is
            // width 0.311 W, height 0.091 W, height ÷ width 0.294, top inset 0.027 W.
            //
            // The spec's "height = 0.075 × islandWidth" is a quarter of the real ratio: it
            // rendered a 0.021 W thin black bar rather than a pill, and the island is the
            // single most recognisable feature of a modern iPhone.
            let length = basis * 0.311
            let thickness = length * 0.294
            let inset = basis * 0.027
            let island = isLandscape
                ? CGRect(x: screen.minX + inset, y: screen.midY - length / 2, width: thickness, height: length)
                : CGRect(x: screen.midX - length / 2, y: screen.maxY - thickness - inset, width: length, height: thickness)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: island, xRadius: thickness / 2, yRadius: thickness / 2).fill()

            // 0.38 of the island height, so ≈14pt across on a 402pt display against a real
            // front-camera aperture of roughly 13pt. Its centre sits 0.6 × thickness in from
            // the pill's end, which keeps the whole dot inside the rounded cap (the cap
            // radius is 0.5 × thickness and the dot reaches only 0.09 × thickness past its
            // centre) rather than filling the pill now that the pill is four times taller.
            let sensor = thickness * 0.38
            let centre = isLandscape
                ? CGPoint(x: island.midX, y: island.minY + thickness * 0.6)
                : CGPoint(x: island.maxX - thickness * 0.6, y: island.midY)
            NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.18, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: centre.x - sensor / 2,
                y: centre.y - sensor / 2,
                width: sensor,
                height: sensor
            )).fill()

        case let .punchHole(fraction):
            let diameter = basis * fraction
            let inset = basis * 0.012 + diameter / 2
            let centre = isLandscape
                ? CGPoint(x: screen.minX + inset, y: screen.midY)
                : CGPoint(x: screen.midX, y: screen.maxY - inset)
            let hole = CGRect(
                x: centre.x - diameter / 2,
                y: centre.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: hole).fill()
            NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.21, alpha: 1).setFill()
            NSBezierPath(ovalIn: hole.insetBy(dx: diameter * 0.27, dy: diameter * 0.27)).fill()

        case let .bezelDot(fraction):
            // Outside the screen, in the bezel. Modern iPad Pro moved the camera to the
            // landscape long edge and older iPads keep it on the portrait short edge; the
            // tool cannot know which, and a neutral dot is unremarkable for either.
            let diameter = basis * fraction
            let centre = CGPoint(x: screen.midX, y: screen.maxY + bezel / 2)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: centre.x - diameter / 2,
                y: centre.y - diameter / 2,
                width: diameter,
                height: diameter
            )).fill()

        case .none:
            break
        }
    }

    // MARK: - Frame metrics
    //
    // Every value is a fraction of the rendered screen's short edge in output pixels,
    // computed after the fit scale. There are no pixel floors except the 2px minimum bezel,
    // and no independent outer radius: it is always screenRadius + bezel.

    private struct FrameMetrics {
        enum Camera {
            case island
            case punchHole(CGFloat)
            case bezelDot(CGFloat)
            case none
        }

        enum Buttons {
            case iphone
            case androidPhone
            case ipad
            case none
        }

        let bezel: CGFloat
        let screenRadius: CGFloat
        let shell: NSColor
        let button: NSColor
        let camera: Camera
        let buttons: Buttons

        var isDrawn: Bool { bezel > 0 }

        static func of(_ style: ScreenshotFrameStyle) -> FrameMetrics {
            switch style {
            case .iphone:
                // 0.135 is the real display corner radius: ≈55-62pt on a 390-402pt display.
                // The pre-rebuild 0.064 was roughly half that and read as visibly too square.
                FrameMetrics(
                    bezel: 0.030,
                    screenRadius: 0.135,
                    shell: NSColor(calibratedWhite: 0.47, alpha: 1),
                    button: NSColor(calibratedWhite: 0.33, alpha: 1),
                    camera: .island,
                    buttons: .iphone
                )
            case .ipad:
                FrameMetrics(
                    bezel: 0.048,
                    screenRadius: 0.025,
                    shell: NSColor(calibratedWhite: 0.47, alpha: 1),
                    button: NSColor(calibratedWhite: 0.33, alpha: 1),
                    // Checked against a 13″ iPad Pro the same way the island was: a ≈197mm-wide
                    // display beside a front-camera aperture of ≈2.5mm is 0.013 W. 0.012 is
                    // inside that, so it stays.
                    camera: .bezelDot(0.012),
                    buttons: .ipad
                )
            case .androidPhone:
                FrameMetrics(
                    bezel: 0.032,
                    screenRadius: 0.085,
                    shell: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.12, alpha: 1),
                    button: NSColor(calibratedWhite: 0.18, alpha: 1),
                    // Pixel 8 Pro: a 1344px-wide display at 489ppi is ≈70mm across, and the
                    // punch-hole aperture measures ≈3.5mm — 0.050 W. 0.045 is at the low end
                    // of the Pixel/Galaxy range rather than wrong, and unlike the island the
                    // exact aperture is not a figure the vendors publish, so it stays.
                    camera: .punchHole(0.045),
                    buttons: .androidPhone
                )
            case .androidTablet:
                FrameMetrics(
                    bezel: 0.055,
                    screenRadius: 0.030,
                    shell: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.12, alpha: 1),
                    button: NSColor(calibratedWhite: 0.18, alpha: 1),
                    // Galaxy Tab S9: a ≈273mm landscape display beside a ≈3mm aperture is
                    // 0.011 W. 0.010 is inside that, so it stays.
                    camera: .bezelDot(0.010),
                    buttons: .none
                )
            case .none:
                FrameMetrics(
                    bezel: 0,
                    screenRadius: 0,
                    shell: .clear,
                    button: .clear,
                    camera: .none,
                    buttons: .none
                )
            }
        }
    }
}
