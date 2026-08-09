import AppKit
import Foundation

struct ScreenshotTarget: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let platform: PlatformKind
}

enum ScreenshotCaptureError: LocalizedError {
    case toolMissing(String)
    case noDevice(PlatformKind)
    case commandFailed(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case let .toolMissing(tool):
            "\(tool) is not available on this Mac."
        case let .noDevice(platform):
            "No running \(platform == .android ? "Android emulator or device" : "iOS Simulator") was found."
        case let .commandFailed(message):
            message
        case .invalidImage:
            "The captured file is not a readable image."
        }
    }
}

enum ScreenshotCaptureService {
    static func discoverTargets(for platforms: [PlatformKind]) async -> [ScreenshotTarget] {
        await Task.detached(priority: .userInitiated) {
            var targets: [ScreenshotTarget] = []
            if platforms.contains(.android), let adb = adbExecutable() {
                targets += androidTargets(adb: adb)
            }
            if platforms.contains(.ios) {
                targets += iosTargets()
            }
            return targets.sorted {
                if $0.platform != $1.platform { return $0.platform.rawValue < $1.platform.rawValue }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }

    static func capture(_ target: ScreenshotTarget) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("frk-screenshot-\(UUID().uuidString).png")
            switch target.platform {
            case .android:
                guard let adb = adbExecutable() else { throw ScreenshotCaptureError.toolMissing("adb") }
                let result = run(adb, ["-s", target.id, "exec-out", "screencap", "-p"])
                guard result.status == 0, !result.stdout.isEmpty else {
                    throw ScreenshotCaptureError.commandFailed(cleanError(result.stderr, fallback: "Android screenshot capture failed."))
                }
                try result.stdout.write(to: destination, options: .atomic)
            case .ios:
                let result = run(URL(fileURLWithPath: "/usr/bin/xcrun"), [
                    "simctl", "io", target.id, "screenshot", "--type=png", destination.path,
                ])
                guard result.status == 0 else {
                    throw ScreenshotCaptureError.commandFailed(cleanError(result.stderr, fallback: "iOS Simulator screenshot capture failed."))
                }
            }
            guard NSImage(contentsOf: destination) != nil else {
                try? FileManager.default.removeItem(at: destination)
                throw ScreenshotCaptureError.invalidImage
            }
            return destination
        }.value
    }

    /// Short edge, in source pixels, at or above which a capture is treated as a tablet (spec §4).
    ///
    /// Orientation-invariant by construction: the short edge is the same number before and after
    /// a rotation, so a landscape iPad capture classifies the same as a portrait one.
    static let tabletShortEdgeThreshold: CGFloat = 1400

    /// The frame to *start* from for a capture.
    ///
    /// A suggestion for the initial value only. Nothing in this service reads, or may be made to
    /// read, the frame the user subsequently picked - the previous build round-tripped that value
    /// through the capture target and the user's choice could never survive.
    ///
    /// `ScreenshotTarget` carries no display size: neither `adb devices -l` nor
    /// `simctl list devices -j` reports one, and querying for it would mean a second per-device
    /// shell-out on every discovery pass. The caller already holds the captured image, so it
    /// passes those dimensions here. Without a size the phone frame is assumed.
    ///
    /// Known false positive, kept because the spec pins the threshold at 1400: a 1440x3120 Galaxy
    /// S24 Ultra capture reads as a tablet. Correcting it would need an aspect guard the spec does
    /// not authorise, and the user overrides the suggestion in one click.
    static func suggestedFrame(for platform: PlatformKind, sourceSize: CGSize? = nil) -> ScreenshotFrame {
        let shortEdge = sourceSize.map { min($0.width, $0.height) } ?? 0
        return ScreenshotFrame.matching(platform, tablet: shortEdge >= tabletShortEdgeThreshold)
    }

    private static func androidTargets(adb: URL) -> [ScreenshotTarget] {
        let result = run(adb, ["devices", "-l"])
        guard result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return [] }
        return parseAndroidDevices(text)
    }

    /// Parses the body of `adb devices -l`, dropping its "List of devices attached" header.
    static func parseAndroidDevices(_ text: String) -> [ScreenshotTarget] {
        text.split(separator: "\n").dropFirst().compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 2, columns[1] == "device" else { return nil }
            let serial = columns[0]
            // adb is free to repeat a key (and has been seen to), and
            // Dictionary(uniqueKeysWithValues:) traps rather than throws on a
            // duplicate, which would kill the app from a detached Task. Keeping the
            // first value is what the unique-key initialiser produced for every
            // well-formed line anyway.
            let properties = Dictionary(
                columns.dropFirst(2).compactMap { token -> (String, String)? in
                    let pair = token.split(separator: ":", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? (pair[0], pair[1].replacingOccurrences(of: "_", with: " ")) : nil
                },
                uniquingKeysWith: { first, _ in first }
            )
            let model = properties["model"] ?? properties["device"] ?? "Android device"
            let detail = serial.hasPrefix("emulator-") ? "Android Emulator · \(serial)" : "Android device · \(serial)"
            return ScreenshotTarget(id: serial, name: model, detail: detail, platform: .android)
        }
    }

    private static func iosTargets() -> [ScreenshotTarget] {
        let result = run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "list", "devices", "booted", "-j"])
        guard result.status == 0,
              let payload = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let runtimes = payload["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.flatMap { runtime, devices in
            devices.compactMap { device in
                guard device["state"] as? String == "Booted",
                      device["isAvailable"] as? Bool != false,
                      let id = device["udid"] as? String,
                      let name = device["name"] as? String else { return nil }
                let os = runtime.split(separator: ".").last.map(String.init)?
                    .replacingOccurrences(of: "iOS-", with: "iOS ")
                    .replacingOccurrences(of: "-", with: ".") ?? "iOS Simulator"
                return ScreenshotTarget(id: id, name: name, detail: os, platform: .ios)
            }
        }
    }

    private static func adbExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            environment["ANDROID_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("platform-tools/adb") },
            environment["ANDROID_SDK_ROOT"].map { URL(fileURLWithPath: $0).appendingPathComponent("platform-tools/adb") },
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Collects both of a child's pipes.
    ///
    /// The pipes stay separate on purpose: `adb exec-out screencap -p` streams a
    /// binary PNG on stdout, so interleaving stderr into it would corrupt the
    /// capture. They must therefore be drained concurrently - reading one to EOF
    /// first deadlocks as soon as the child fills the other pipe's 64 KiB buffer.
    /// The deadline is generous because a cold `adb start-server` is legitimately
    /// slow; it only exists so a wedged child cannot hold the detached task forever.
    private static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval = 45
    ) -> (stdout: Data, stderr: Data, status: Int32) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (Data(), Data("Tool not found: \(executable.path)".utf8), 127)
        }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return (Data(), Data(error.localizedDescription.utf8), 126)
        }

        let collected = OutputBuffers()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: group) {
            collected.setStandardOutput(output.fileHandleForReading.readDataToEndOfFile())
        }
        queue.async(group: group) {
            collected.setStandardError(error.fileHandleForReading.readDataToEndOfFile())
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
            process.waitUntilExit()
            let status = process.terminationStatus
            return (
                collected.standardOutput,
                Data("\(executable.lastPathComponent) did not finish within \(Int(timeout)) seconds.".utf8),
                status == 0 ? 124 : status
            )
        }
        process.waitUntilExit()
        return (collected.standardOutput, collected.standardError, process.terminationStatus)
    }

    private final class OutputBuffers {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func setStandardOutput(_ data: Data) {
            lock.lock()
            out = data
            lock.unlock()
        }

        func setStandardError(_ data: Data) {
            lock.lock()
            err = data
            lock.unlock()
        }

        var standardOutput: Data {
            lock.lock()
            defer { lock.unlock() }
            return out
        }

        var standardError: Data {
            lock.lock()
            defer { lock.unlock() }
            return err
        }
    }

    private static func cleanError(_ data: Data, fallback: String) -> String {
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? fallback : message
    }
}
