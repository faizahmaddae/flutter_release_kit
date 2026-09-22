import AppKit
import Foundation

/// Snapshot inputs before starting: the worker never reads live UI state.
struct ScreenshotExportJob {
    private let source: CGImage?
    let options: ScreenshotRenderOptions
    let destination: URL
    let protectedSources: Set<URL>
    var blockingReason: String? = nil

    init(image: NSImage, options: ScreenshotRenderOptions, destination: URL, protectedSources: Set<URL>, blockingReason: String? = nil) {
        // Asking NSImage for a CGImage with a nil context can apply the display's Retina
        // scale. Read native bitmap pixels instead so a 1080px capture stays 1080px.
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            source = bitmap.cgImage
        } else {
            source = try? ScreenshotRenderer.render(
                image: image,
                options: ScreenshotRenderOptions(frame: .none, canvas: .transparent, paddingPercent: 0)
            ).cgImage
        }
        self.options = options
        self.destination = destination
        self.protectedSources = protectedSources
        self.blockingReason = blockingReason
    }

    func write() -> StudioExportOutcome {
        let filename = destination.lastPathComponent
        if let blockingReason {
            return StudioExportOutcome(filename: filename, succeeded: false, message: blockingReason)
        }
        guard !wouldOverwriteSource else {
            return StudioExportOutcome(
                filename: filename, succeeded: false,
                message: "This is an imported source image. Choose a different filename or folder to keep the original."
            )
        }
        do {
            guard let source else { throw ScreenshotRendererError.invalidSource }
            // Each worker owns its AppKit image; only immutable CGImage pixels cross threads.
            let image = NSImage(size: CGSize(width: source.width, height: source.height))
            image.addRepresentation(NSBitmapImageRep(cgImage: source))
            try ScreenshotRenderer.pngData(image: image, options: options).write(to: destination, options: .atomic)
            return StudioExportOutcome(filename: filename, succeeded: true, message: nil)
        } catch {
            return StudioExportOutcome(filename: filename, succeeded: false, message: error.localizedDescription)
        }
    }

    private var wouldOverwriteSource: Bool {
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        let identity = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        return protectedSources.contains { source in
            if source.resolvingSymlinksInPath().standardizedFileURL == resolved { return true }
            // Also recognise alternate casing on a case-insensitive volume.
            guard let identity,
                  let sourceIdentity = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            else { return false }
            return identity.isEqual(sourceIdentity)
        }
    }
}
