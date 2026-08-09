import Foundation

enum FRKClientError: LocalizedError {
    case executableMissing(String)
    case commandFailed(Int32, String)
    case apiError(String)
    case invalidResponse(String)
    case incompatibleProtocol(Int, Int)

    var errorDescription: String? {
        switch self {
        case let .executableMissing(path):
            "FRK CLI was not found or is not executable at \(path)."
        case let .commandFailed(code, message):
            message.isEmpty ? "FRK exited with status \(code)." : message
        case let .apiError(message):
            message
        case let .invalidResponse(message):
            "FRK returned an invalid response: \(message)"
        case let .incompatibleProtocol(minimum, maximum):
            "This app supports FRK protocol 1, but the CLI supports \(minimum)…\(maximum)."
        }
    }
}

// The async surface AppModel consumes, so the model can be driven by a fake instead
// of the real CLI. makeStreamingProcess is deliberately out: it hands back a live
// Process, which has no honest stand-in, so start() keeps talking to FRKClient itself.
protocol FRKClientProtocol: Sendable {
    func capabilities() async throws -> CapabilitiesResponse
    func projects() async throws -> ProjectsResponse
    func setupStatus(_ id: String) async throws -> SetupStatusResponse
    func credentials() async throws -> CredentialsResponse
    /// Reaches both stores, so it is slow and cancellable. Cancelling the enclosing
    /// Task terminates the `frk` child and throws `CancellationError`.
    func storeVersions(_ id: String) async throws -> StoreVersionsResponse
    /// Local and instant: reads `fastlane/release_kit.yml`, no network, no fastlane.
    func buildArgs(_ id: String) async throws -> BuildArgsResponse
    /// Replaces `platform`'s OWN extra build flags; an empty `args` clears them. Never
    /// touches the shared (top-level) list, which stays a hand-edited YAML setting.
    func setBuildArgs(_ id: String, platform: PlatformKind, args: [String]) async throws -> BuildArgsResponse
    /// Local and instant, like setBuildArgs: rewrites one YAML scalar, no fastlane.
    func setTrack(_ id: String, track: String) async throws -> ProjectDocument
    func configureGooglePlay(file: URL, force: Bool) async throws -> CredentialsResponse
    func configureAppStore(
        file: URL,
        keyID: String,
        issuerID: String,
        force: Bool
    ) async throws -> CredentialsResponse
}

struct FRKClient: FRKClientProtocol {
    static let desktopProtocolVersion = 1
    let executableURL: URL

    static func suggestedExecutable() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL?] = [
            environment["FLUTTER_RELEASE_KIT_CLI"].map { URL(fileURLWithPath: $0) },
            home.appendingPathComponent(".local/bin/frk"),
            home.appendingPathComponent(".flutter-release-kit/bin/frk"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bin/frk"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        } ?? home.appendingPathComponent(".local/bin/frk")
    }

    func capabilities() async throws -> CapabilitiesResponse {
        let response: CapabilitiesResponse = try await runJSON(arguments: ["api", "capabilities"])
        guard response.minimumDesktopProtocol <= Self.desktopProtocolVersion,
              response.maximumDesktopProtocol >= Self.desktopProtocolVersion else {
            throw FRKClientError.incompatibleProtocol(
                response.minimumDesktopProtocol,
                response.maximumDesktopProtocol
            )
        }
        return response
    }

    func projects() async throws -> ProjectsResponse {
        try await runJSON(arguments: ["api", "projects"])
    }

    func setupStatus(_ id: String) async throws -> SetupStatusResponse {
        try await runJSON(arguments: ["api", "setup", id])
    }

    func credentials() async throws -> CredentialsResponse {
        try await runJSON(arguments: ["api", "credentials"])
    }

    func configureGooglePlay(file: URL, force: Bool) async throws -> CredentialsResponse {
        var arguments = ["api", "configure-credentials", "google-play", "--file", file.path]
        if force { arguments.append("--force") }
        return try await runJSON(arguments: arguments)
    }

    func configureAppStore(
        file: URL,
        keyID: String,
        issuerID: String,
        force: Bool
    ) async throws -> CredentialsResponse {
        var arguments = [
            "api", "configure-credentials", "app-store",
            "--file", file.path,
            "--key-id", keyID,
            "--issuer-id", issuerID,
        ]
        if force { arguments.append("--force") }
        return try await runJSON(arguments: arguments)
    }

    func storeVersions(_ id: String) async throws -> StoreVersionsResponse {
        try await runCancellableJSON(arguments: ["api", "store-versions", id])
    }

    func buildArgs(_ id: String) async throws -> BuildArgsResponse {
        try await runJSON(arguments: ["api", "build-args", id])
    }

    func setBuildArgs(_ id: String, platform: PlatformKind, args: [String]) async throws -> BuildArgsResponse {
        var arguments = ["api", "set-build-args", id, "--platform", platform.rawValue]
        for arg in args {
            arguments.append(contentsOf: ["--arg", arg])
        }
        return try await runJSON(arguments: arguments)
    }

    func setTrack(_ id: String, track: String) async throws -> ProjectDocument {
        try await runJSON(arguments: ["api", "set-track", id, "--track", track])
    }

    func runJSON<T: Decodable>(arguments: [String]) async throws -> T {
        let executableURL = executableURL
        let environment = Self.processEnvironment()
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.capture(executableURL: executableURL, arguments: arguments, environment: environment)
        }.value
        return try Self.decode(result)
    }

    /// `runJSON` for a command slow enough that a user will want to stop it.
    ///
    /// `api store-versions` queries two stores behind fastlane and can take minutes,
    /// and the documented way to stop it is to terminate the `frk` process. The child
    /// is handed to a box the cancellation handler can reach, so cancelling the task
    /// kills it. The capture itself is deliberately left uncancellable: it has to run
    /// to completion to reap the child and close the pipes, and it returns as soon as
    /// the child is gone. The status it reports afterwards describes a process we
    /// killed, so cancellation is re-checked before that status is read as a failure.
    private func runCancellableJSON<T: Decodable>(arguments: [String]) async throws -> T {
        let executableURL = executableURL
        let environment = Self.processEnvironment()
        let child = ChildProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.capture(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    register: { child.adopt($0) }
                )
            }.value
            try Task.checkCancellation()
            return try Self.decode(result)
        } onCancel: {
            child.terminate()
        }
    }

    private static func decode<T: Decodable>(_ result: (output: Data, error: String, status: Int32)) throws -> T {
        guard result.status == 0 else {
            if let response = try? JSONDecoder().decode(APIErrorResponse.self, from: result.output),
               let error = response.error {
                throw FRKClientError.apiError(error.message)
            }
            throw FRKClientError.commandFailed(result.status, result.error)
        }
        do {
            return try JSONDecoder().decode(T.self, from: result.output)
        } catch {
            let preview = String(data: result.output, encoding: .utf8) ?? "Unreadable output"
            throw FRKClientError.invalidResponse("\(error.localizedDescription)\n\(preview.prefix(400))")
        }
    }

    func makeStreamingProcess(arguments: [String], pipe: Pipe) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw FRKClientError.executableMissing(executableURL.path)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.processEnvironment()
        process.standardOutput = pipe
        process.standardError = pipe
        return process
    }

    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.local/bin",
            "\(home)/development/flutter/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = environment["PATH", default: ""].split(separator: ":").map(String.init)
        environment["PATH"] = Array(NSOrderedSet(array: preferred + existing))
            .compactMap { $0 as? String }
            .joined(separator: ":")
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "en_US.UTF-8"
        return environment
    }

    private static func capture(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        register: (Process) -> Void = { _ in }
    ) throws -> (output: Data, error: String, status: Int32) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw FRKClientError.executableMissing(executableURL.path)
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        register(process)

        // A one-shot `api` command answers with a single JSON document, so stderr gets
        // its own pipe: one warning from a shell rc file or a Ruby gem used to be
        // interleaved into stdout and invalidate the whole document. The two pipes are
        // then drained CONCURRENTLY - a child that fills the 64 KiB stderr buffer
        // blocks before it writes stdout, so reading stdout to EOF first would hang.
        let stderrBytes = PipeDrain()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stderrBytes.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else {
            return (output, "", process.terminationStatus)
        }
        // Unchanged for a CLI that diagnoses on stdout: the message still falls back
        // to stdout text whenever stderr contributed nothing.
        let stderrText = String(data: stderrBytes.data, encoding: .utf8) ?? ""
        let error = stderrText.isEmpty ? (String(data: output, encoding: .utf8) ?? "") : stderrText
        return (output, error, process.terminationStatus)
    }
}

// Hands the stderr reader's bytes back to the thread draining stdout. group.wait()
// happens-after the write, so the read on the far side is ordered.
private final class PipeDrain: @unchecked Sendable {
    var data = Data()
}

// Lets a cancellation handler, which runs on whichever thread cancelled, reach a child
// started on the detached capture thread. A cancellation that lands in the window
// between run() and adoption is remembered rather than lost, so the child started a
// moment ago is still stopped.
private final class ChildProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            process.terminate()
            return
        }
        self.process = process
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

private struct APIErrorResponse: Decodable {
    let error: APIErrorPayload?
}
