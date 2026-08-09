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

struct FRKClient {
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

    func project(_ id: String) async throws -> ProjectResponse {
        try await runJSON(arguments: ["api", "project", id])
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

    func runJSON<T: Decodable>(arguments: [String]) async throws -> T {
        let executableURL = executableURL
        let environment = Self.processEnvironment()
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.capture(executableURL: executableURL, arguments: arguments, environment: environment)
        }.value
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
        environment: [String: String]
    ) throws -> (output: Data, error: String, status: Int32) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw FRKClientError.executableMissing(executableURL.path)
        }
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let error = process.terminationStatus == 0 ? "" : (String(data: output, encoding: .utf8) ?? "")
        return (output, error, process.terminationStatus)
    }
}

private struct APIErrorResponse: Decodable {
    let error: APIErrorPayload?
}
