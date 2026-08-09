import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var selectedProjectID: String? {
        didSet { syncVersionFields() }
    }
    @Published private(set) var capabilities: CapabilitiesResponse?
    @Published private(set) var connectionMessage = "Connecting…"
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningTitle: String?
    @Published private(set) var activity: [ActivityLine] = []
    @Published private(set) var lastRunOutcome: RunOutcome?
    @Published private(set) var setupStatus: SetupStatusResponse?
    @Published private(set) var isLoadingSetup = false
    @Published private(set) var credentialsStatus: CredentialsResponse?
    @Published private(set) var isLoadingCredentials = false
    @Published var buildName = ""
    @Published var buildNumber = ""
    @Published var errorMessage: String?
    @Published var showAddProject = false
    @Published var showSettings = false
    @Published var showCredentialOnboarding = false
    @Published var cliPath: String

    private var activeProcess: Process?
    private var lineRemainder = ""
    private var selectionAfterRunPath: String?
    private var cancellationRequested = false
    private var client: FRKClient { FRKClient(executableURL: URL(fileURLWithPath: cliPath)) }

    init() {
        let saved = UserDefaults.standard.string(forKey: "frkCLIPath")
        cliPath = saved ?? FRKClient.suggestedExecutable().path
    }

    var selectedProject: ProjectSummary? {
        projects.first { $0.id == selectedProjectID }
    }

    var canRunVersionedAction: Bool {
        !buildName.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(buildNumber) != nil
            && Int(buildNumber, default: 0) > 0
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            capabilities = try await client.capabilities()
            isConnected = true
            connectionMessage = "FRK \(capabilities?.cliVersion ?? "") · Protocol v1"
            if capabilities?.capabilities.credentialManagement == true {
                try await loadCredentialStatus()
            }
            try await reloadProjects()
        } catch {
            isConnected = false
            connectionMessage = "CLI unavailable"
            capabilities = nil
            projects = []
            selectedProjectID = nil
            credentialsStatus = nil
            showCredentialOnboarding = false
            errorMessage = error.localizedDescription
        }
    }

    func reloadProjects() async throws {
        let response = try await client.projects()
        projects = response.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) {
            syncVersionFields()
        } else {
            self.selectedProjectID = projects.first?.id
        }
    }

    func reconnect() {
        UserDefaults.standard.set(cliPath, forKey: "frkCLIPath")
        Task { await bootstrap() }
    }

    func selectCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the frk executable"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            cliPath = url.path
        }
    }

    func revealVault() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".flutter-release")
        NSWorkspace.shared.open(url)
    }

    func loadCredentialStatus(presentFirstRunIfNeeded: Bool = true) async throws {
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }
        let response = try await client.credentials()
        if let error = response.error {
            throw FRKClientError.apiError(error.message)
        }
        credentialsStatus = response
        guard presentFirstRunIfNeeded else { return }
        let setupDecisionMade = UserDefaults.standard.bool(forKey: "credentialSetupDecisionMade")
        showCredentialOnboarding = CredentialOnboardingPolicy.shouldPresent(
            hasConfiguredStore: response.hasConfiguredStore,
            setupDecisionMade: setupDecisionMade
        )
    }

    func configureGooglePlay(file: URL) async throws {
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }
        let response = try await client.configureGooglePlay(file: file, force: true)
        if let error = response.error { throw FRKClientError.apiError(error.message) }
        credentialsStatus = response
        UserDefaults.standard.set(true, forKey: "credentialSetupDecisionMade")
    }

    func configureAppStore(file: URL, keyID: String, issuerID: String) async throws {
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }
        let response = try await client.configureAppStore(
            file: file,
            keyID: keyID,
            issuerID: issuerID,
            force: true
        )
        if let error = response.error { throw FRKClientError.apiError(error.message) }
        credentialsStatus = response
        UserDefaults.standard.set(true, forKey: "credentialSetupDecisionMade")
    }

    func finishCredentialOnboarding(localBuildsOnly: Bool = false) {
        guard credentialsStatus?.hasConfiguredStore == true || localBuildsOnly else { return }
        UserDefaults.standard.set(true, forKey: "credentialSetupDecisionMade")
        showCredentialOnboarding = false
    }

    func loadSetupStatus(for projectID: String) async {
        isLoadingSetup = true
        defer { isLoadingSetup = false }
        do {
            let response = try await client.setupStatus(projectID)
            if let error = response.error {
                setupStatus = nil
                errorMessage = error.message
            } else {
                setupStatus = response
            }
        } catch {
            setupStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func clearSetupStatus() {
        setupStatus = nil
        isLoadingSetup = false
    }

    func openXcode(for project: ProjectSummary) {
        let workspace = project.pathURL.appendingPathComponent("ios/Runner.xcworkspace")
        let xcodeProject = project.pathURL.appendingPathComponent("ios/Runner.xcodeproj")
        if FileManager.default.fileExists(atPath: workspace.path) {
            NSWorkspace.shared.open(workspace)
        } else if FileManager.default.fileExists(atPath: xcodeProject.path) {
            NSWorkspace.shared.open(xcodeProject)
        } else {
            errorMessage = "This project has no iOS Xcode workspace or project."
        }
    }

    func revealProject() {
        guard let selectedProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedProject.pathURL])
    }

    func revealArtifact(_ artifact: ArtifactRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
    }

    func start(_ request: FRKRunRequest) {
        guard !isRunning else { return }
        activity = []
        lastRunOutcome = nil
        errorMessage = nil
        lineRemainder = ""
        cancellationRequested = false
        isRunning = true
        runningTitle = request.action.title
        selectionAfterRunPath = request.action == .onboard && !request.dryRun ? request.project : nil

        let pipe = Pipe()
        do {
            let process = try client.makeStreamingProcess(arguments: request.arguments, pipe: pipe)
            activeProcess = process

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in self?.consume(chunk) }
            }

            process.terminationHandler = { [weak self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                let tailText = String(decoding: tail, as: UTF8.self)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.consume(tailText)
                    self.flushRemainder()
                    self.activeProcess = nil
                    self.isRunning = false
                    self.runningTitle = nil
                    if self.lastRunOutcome == nil {
                        if self.cancellationRequested, process.terminationStatus != 0 {
                            self.lastRunOutcome = .cancelled
                        } else {
                            self.lastRunOutcome = process.terminationStatus == 0 ? .success : .failure
                        }
                    }
                    do {
                        try await self.reloadProjects()
                        if let path = self.selectionAfterRunPath,
                           let project = self.projects.first(where: { $0.path == path }) {
                            self.selectedProjectID = project.id
                        }
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                    self.selectionAfterRunPath = nil
                    self.cancellationRequested = false
                }
            }
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            isRunning = false
            runningTitle = nil
            lastRunOutcome = .failure
            selectionAfterRunPath = nil
            cancellationRequested = false
            errorMessage = error.localizedDescription
            activity.append(ActivityLine(message: error.localizedDescription, kind: .error))
        }
    }

    func cancelCurrentJob() {
        guard let activeProcess, activeProcess.isRunning else { return }
        guard !cancellationRequested else { return }
        cancellationRequested = true
        activity.append(ActivityLine(message: "Cancellation requested…", kind: .info))
        activeProcess.terminate()
    }

    func clearActivity() {
        guard !isRunning else { return }
        activity = []
        lastRunOutcome = nil
    }

    private func consume(_ chunk: String) {
        lineRemainder += chunk
        let lines = lineRemainder.split(separator: "\n", omittingEmptySubsequences: false)
        lineRemainder = String(lines.last ?? "")
        for line in lines.dropLast() {
            consumeLine(String(line))
        }
    }

    private func flushRemainder() {
        guard !lineRemainder.isEmpty else { return }
        consumeLine(lineRemainder)
        lineRemainder = ""
    }

    private func consumeLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(APIEvent.self, from: data) else {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activity.append(ActivityLine(message: line, kind: .info))
            }
            return
        }
        switch event.type {
        case "log":
            if let message = event.message {
                activity.append(ActivityLine(message: message, kind: .info))
            }
        case "error":
            let message = event.message ?? "FRK rejected the request."
            activity.append(ActivityLine(message: message, kind: .error))
            errorMessage = message
        case "finished":
            let duration = event.durationSeconds.map { String(format: "%.1fs", $0) } ?? ""
            if cancellationRequested, event.success != true {
                lastRunOutcome = .cancelled
                activity.append(ActivityLine(message: "Cancelled safely \(duration)", kind: .info))
            } else {
                lastRunOutcome = event.success == true ? .success : .failure
                activity.append(ActivityLine(
                    message: event.success == true ? "Completed successfully \(duration)" : "Failed (exit \(event.exitCode ?? -1)) \(duration)",
                    kind: event.success == true ? .success : .error
                ))
            }
        default:
            break
        }
    }

    private func syncVersionFields() {
        guard let project = selectedProject else {
            buildName = ""
            buildNumber = ""
            return
        }
        buildName = project.buildName ?? ""
        buildNumber = project.buildNumber.map(String.init) ?? ""
    }
}

private extension Int {
    init(_ text: String, default fallback: Int) {
        self = Int(text) ?? fallback
    }
}
