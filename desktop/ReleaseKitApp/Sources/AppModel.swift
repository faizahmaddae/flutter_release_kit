import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var selectedProjectID: String? {
        didSet { projectSelectionChanged() }
    }
    @Published private(set) var capabilities: CapabilitiesResponse?
    @Published private(set) var connectionMessage = "Connecting…"
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningTitle: String?
    @Published private(set) var activity: [ActivityLine] = []
    @Published private(set) var lastRunOutcome: RunOutcome?
    // fastlane marks the one line in a failure that is meant for a human — the
    // `user_error!`/crash message — with a literal "[!]" prefix; everything else in a
    // crash is Ruby backtrace. Pinning that line separately from the scrolling log means
    // it survives the auto-scroll-to-bottom that would otherwise bury it under twenty
    // lines of gem internals the moment the backtrace streams in.
    @Published private(set) var lastActivityErrorLine: String?
    @Published private(set) var setupStatus: SetupStatusResponse?
    @Published private(set) var isLoadingSetup = false
    @Published private(set) var credentialsStatus: CredentialsResponse?
    @Published private(set) var isLoadingCredentials = false
    // One product release normally ships under one marketing version, so the version
    // name is shared and `splitVersionName` is the explicit opt-out for the rare
    // one-store hotfix. Build numbers are never shared: Google Play and App Store
    // Connect count uploads independently, pubspec's single `+N` cannot describe both,
    // and the app used to find that out twenty minutes into a release when the upload
    // was rejected as a duplicate.
    @Published var sharedBuildName = ""
    @Published var iosBuildName = ""
    @Published var splitVersionName = false {
        didSet {
            // Turning the toggle on seeds the iOS field from the shared name, so a
            // split starts from what the user already typed rather than from empty.
            // Turning it off leaves the override in place but unused, and turning it
            // back on keeps it: a toggle flipped by accident must not destroy the value
            // behind it, which seeding unconditionally would do on the way back.
            if splitVersionName, !oldValue, iosBuildName.isEmpty {
                iosBuildName = sharedBuildName
            }
            // Persisted per project so the choice survives a relaunch. Without this the
            // toggle silently reverted to "shared" every time the app reopened, which is
            // indistinguishable from the setting never having been saved at all.
            if let projectID = selectedProjectID {
                UserDefaults.standard.set(splitVersionName, forKey: "frkSplitVersionName.\(projectID)")
            }
        }
    }
    @Published var androidBuildNumber = ""
    @Published var iosBuildNumber = ""
    @Published private(set) var storeVersions: StoreVersionsResponse?
    @Published private(set) var isCheckingStores = false
    @Published private(set) var storeCheckNote: String?
    @Published private(set) var isStoreCheckCoolingDown = false
    @Published private(set) var releaseLegs: [ReleaseLeg] = []
    // Unlike storeVersions, this is local and instant — a file read, no network, no
    // fastlane — so the view loads it eagerly instead of waiting for a button.
    @Published private(set) var buildArgs: BuildArgsResponse?
    @Published private(set) var isLoadingBuildArgs = false
    @Published private(set) var isSavingBuildArgs = false
    @Published private(set) var isSavingTrack = false
    @Published private(set) var buildArgsError: String?
    @Published var errorMessage: String?
    @Published var showAddProject = false
    @Published var showSettings = false
    @Published var showCredentialOnboarding = false
    @Published var showScreenshotStudio = false
    @Published var showHelp = false
    @Published var cliPath: String

    private var activeProcess: Process?
    private var storeCheckTask: Task<Void, Never>?
    // Identifies the store check whose result is still wanted. Switching project or
    // starting a newer check bumps it, so a cancelled query that settles afterwards
    // cannot write its outcome over the state that replaced it.
    private var storeCheckToken = 0
    // How long "Check stores" stays disabled after a cancellation. `frk api
    // store-versions` starts fastlane in its own session, so killing `frk` returns
    // control immediately but leaves the lane querying the stores; retrying at once
    // would put two lanes on the stores. Settable so tests do not have to wait.
    var storeCheckRetryDelaySeconds: Double = 3
    private var queuedRequests: [FRKRunRequest] = []
    private var lineBuffer = NDJSONLineBuffer()
    // Runs on Foundation's readability queue between taking bytes off the descriptor
    // and handing them to the byte stream. Production leaves it nil. The streaming
    // tests use it to hold a read in flight across process exit, which is the only way
    // to make the readability/termination overlap deterministic: left to chance the
    // window is a handful of instructions wide and 500 consecutive runs never hit it.
    var readabilityStall: (@Sendable () -> Void)?
    private var selectionAfterRunPath: String?
    private var cancellationRequested = false
    private let clientFactory: (String) -> FRKClientProtocol
    private var client: FRKClientProtocol { clientFactory(cliPath) }
    // Streaming is not part of the injectable surface — see FRKClientProtocol — so
    // start() always drives the real executable at the currently configured path.
    private var streamingClient: FRKClient { FRKClient(executableURL: URL(fileURLWithPath: cliPath)) }

    init(clientFactory: @escaping (String) -> FRKClientProtocol = liveClient) {
        self.clientFactory = clientFactory
        let saved = UserDefaults.standard.string(forKey: "frkCLIPath")
        cliPath = saved ?? FRKClient.suggestedExecutable().path
    }

    var selectedProject: ProjectSummary? {
        projects.first { $0.id == selectedProjectID }
    }

    /// The marketing version this platform will be built with. Shared unless the user
    /// asked for two, in which case the shared field stays Android's.
    func buildName(for platform: PlatformKind) -> String {
        switch platform {
        case .android: sharedBuildName
        case .ios: splitVersionName ? iosBuildName : sharedBuildName
        }
    }

    /// The store build number for this platform. Never shared.
    func buildNumber(for platform: PlatformKind) -> String {
        switch platform {
        case .android: androidBuildNumber
        case .ios: iosBuildNumber
        }
    }

    func setBuildNumber(_ value: String, for platform: PlatformKind) {
        switch platform {
        case .android: androidBuildNumber = value
        case .ios: iosBuildNumber = value
        }
    }

    func canRunVersionedAction(for platform: PlatformKind) -> Bool {
        let number = buildNumber(for: platform)
        return !buildName(for: platform).trimmingCharacters(in: .whitespaces).isEmpty
            && Int(number) != nil
            && Int(number, default: 0) > 0
    }

    /// The platforms a project can run a versioned action for right now. A missing or
    /// unusable number on one platform never blocks the other.
    func runnablePlatforms(of project: ProjectSummary) -> [PlatformKind] {
        project.platforms.filter { canRunVersionedAction(for: $0) }
    }

    func versionedRequest(_ action: JobAction, project: String, platform: PlatformKind) -> FRKRunRequest {
        FRKRunRequest(
            action: action,
            project: project,
            platform: platform,
            buildName: buildName(for: platform),
            buildNumber: buildNumber(for: platform)
        )
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

    // MARK: - Store versions

    /// Never called on selection or bootstrap. `api store-versions` reaches two stores
    /// behind fastlane and routinely takes minutes, so it runs only when the user asks
    /// for it and only for as long as they let it.
    var canCheckStoreVersions: Bool {
        selectedProject != nil && !isCheckingStores && !isStoreCheckCoolingDown
    }

    func storeRow(for platform: PlatformKind) -> StoreVersionRow? {
        switch platform {
        case .android: storeVersions?.android.map(StoreVersionRow.init(android:))
        case .ios: storeVersions?.ios.map(StoreVersionRow.init(ios:))
        }
    }

    func checkStoreVersions() {
        guard canCheckStoreVersions, let project = selectedProject else { return }
        storeCheckToken += 1
        let token = storeCheckToken
        isCheckingStores = true
        storeVersions = nil
        storeCheckNote = "Asking Google Play and App Store Connect. Nothing is built or uploaded; this can take a couple of minutes."
        storeCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.client.storeVersions(project.id)
                guard self.storeCheckToken == token else { return }
                if let error = response.error {
                    throw FRKClientError.apiError(error.message)
                }
                self.storeVersions = response
                self.storeCheckNote = nil
                // Cached per project so the last known report survives a relaunch.
                // Restoring it on selection never issues a network call by itself; only
                // this success path, reached solely from the "Check stores" button, does.
                if let data = try? JSONEncoder().encode(response) {
                    UserDefaults.standard.set(data, forKey: "frkStoreVersionsCache.\(project.id)")
                }
            } catch is CancellationError {
                guard self.storeCheckToken == token else { return }
                self.storeCheckNote = "Store check cancelled. The store query keeps running on its own for up to a minute, so give it a moment before checking again."
                self.beginStoreCheckCooldown()
            } catch {
                guard self.storeCheckToken == token else { return }
                self.storeVersions = nil
                self.storeCheckNote = error.localizedDescription
            }
            guard self.storeCheckToken == token else { return }
            self.isCheckingStores = false
            self.storeCheckTask = nil
        }
    }

    func cancelStoreCheck() {
        storeCheckTask?.cancel()
    }

    /// Loads what `fastlane/release_kit.yml` already holds for this project. Safe to
    /// call on every selection: local and instant, and the CLI never writes anything
    /// to answer it.
    func loadBuildArgs(for projectID: String) async {
        isLoadingBuildArgs = true
        buildArgsError = nil
        defer { isLoadingBuildArgs = false }
        do {
            buildArgs = try await client.buildArgs(projectID)
        } catch {
            buildArgs = nil
            buildArgsError = error.localizedDescription
        }
    }

    /// Replaces `platform`'s own extra build flags and refreshes `buildArgs` from the
    /// response, so `own`/`effective` reflect exactly what was just written rather than
    /// what the caller assumed would happen.
    func setBuildArgs(for projectID: String, platform: PlatformKind, args: [String]) async {
        isSavingBuildArgs = true
        buildArgsError = nil
        defer { isSavingBuildArgs = false }
        do {
            buildArgs = try await client.setBuildArgs(projectID, platform: platform, args: args)
        } catch {
            buildArgsError = error.localizedDescription
        }
    }

    /// Replaces the matching project's entry with the one `set-track` just wrote and
    /// read back, so every place reading `project.android?.track` — the button, its
    /// confirmation, its tooltip — updates from one write instead of each needing its
    /// own refresh call. A project not currently in `projects` (removed mid-request) is
    /// left alone rather than appended back.
    func setTrack(for projectID: String, track: String) async {
        isSavingTrack = true
        defer { isSavingTrack = false }
        do {
            let response = try await client.setTrack(projectID, track: track)
            if let index = projects.firstIndex(where: { $0.id == projectID }) {
                projects[index] = response.project
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A human-readable stamp for the report currently shown, so a result restored from
    /// a previous session is never mistaken for one just fetched. `nil` whenever there
    /// is nothing to show yet, or the timestamp cannot be parsed.
    var storeVersionsCheckedAtDisplay: String? {
        guard let raw = storeVersions?.checkedAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return "Checked \(relative.localizedString(for: date, relativeTo: Date()))"
    }

    /// Fills one field with the candidate computed from what the store already holds.
    ///
    /// This is the only path from a store number into a build number, it runs only
    /// from a button, and the field stays editable afterwards. Nothing is ever
    /// pre-filled and no build runs on a number the app chose by itself.
    func applySuggestedBuildNumber(for platform: PlatformKind) {
        guard let suggestion = storeRow(for: platform)?.suggestion else { return }
        setBuildNumber(String(suggestion), for: platform)
    }

    private func beginStoreCheckCooldown() {
        guard storeCheckRetryDelaySeconds > 0 else { return }
        isStoreCheckCoolingDown = true
        let seconds = storeCheckRetryDelaySeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.isStoreCheckCoolingDown = false
        }
    }

    /// Drops a report that belongs to a project the user has moved away from. The token
    /// bump keeps an in-flight query from settling onto the new project's state.
    private func resetStoreCheck() {
        storeCheckToken += 1
        storeCheckTask?.cancel()
        storeCheckTask = nil
        storeVersions = nil
        storeCheckNote = nil
        isCheckingStores = false
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

    /// Uploads every requested platform, one `frk` invocation each.
    ///
    /// `--platform all` sends one version pair to both stores, which is exactly what
    /// divergent build numbers cannot use, so each platform is run on its own with its
    /// own `--build-name`/`--build-number`. Like `frk release all`, the sequence is not
    /// atomic and stops at the first platform that does not succeed: whatever already
    /// landed stays landed, and `releaseLegs` says which half that was.
    func startRelease(project: String, platforms: [PlatformKind]) {
        guard !isRunning, !platforms.isEmpty else { return }
        releaseLegs = platforms.map {
            ReleaseLeg(
                platform: $0,
                buildName: buildName(for: $0),
                buildNumber: buildNumber(for: $0),
                state: .queued
            )
        }
        let requests = platforms.map { versionedRequest(.release, project: project, platform: $0) }
        queuedRequests = Array(requests.dropFirst())
        start(requests[0], position: .first)
    }

    func start(_ request: FRKRunRequest) {
        start(request, position: .standalone)
    }

    /// Where a run sits in a multi-platform release, which decides what the run is
    /// allowed to clear. A standalone run owns the activity log and the leg list; a
    /// continuation inherits both from the release that queued it.
    private enum SequencePosition {
        case standalone
        case first
        case continuation
    }

    private func start(_ request: FRKRunRequest, position: SequencePosition) {
        guard !isRunning else { return }
        if position == .continuation, let platform = request.platform {
            activity.append(ActivityLine(message: "— \(platform.title) —", kind: .info))
        } else {
            activity = []
        }
        if position == .standalone {
            releaseLegs = []
            queuedRequests = []
        }
        if let platform = request.platform,
           let index = releaseLegs.firstIndex(where: { $0.platform == platform }) {
            releaseLegs[index].state = .running
        }
        lastRunOutcome = nil
        errorMessage = nil
        lastActivityErrorLine = nil
        lineBuffer = NDJSONLineBuffer()
        cancellationRequested = false
        isRunning = true
        runningTitle = request.action.title
        selectionAfterRunPath = request.action == .onboard && !request.dryRun ? request.project : nil

        let pipe = Pipe()
        // Every byte of the run travels through one stream and one consumer, so the
        // reads stay ordered and the terminal bookkeeping below can only run after the
        // last byte has been folded into the line buffer. Spawning a Task per chunk let
        // the termination work overtake an in-flight read.
        let (byteStream, continuation) = AsyncStream<Data>.makeStream()
        // Foundation delivers readability callbacks on one queue and the termination
        // callback on another and does not serialise the two, so a callback that has
        // already taken its bytes off the descriptor can still be short of yield() when
        // the terminator runs. AsyncStream silently discards a yield that lands after
        // finish(), and readDataToEndOfFile cannot recover those bytes because the
        // callback already consumed them from the descriptor — the run then settles
        // from terminationStatus and the terminal event never reaches the activity log.
        //
        // One lock closes it. Taking bytes off the descriptor and handing them to the
        // stream happen together inside the critical section, and draining-to-EOF plus
        // finish() happen inside that same critical section, which leaves exactly two
        // possible orders: a reader arrives first and its bytes are yielded before the
        // stream is finished, or the terminator arrives first and drains the descriptor
        // to EOF, so the reader behind it finds nothing left to take. In neither order
        // is a byte consumed without being delivered, and the single critical section
        // also stops the two from reading the same descriptor concurrently and
        // interleaving what they hand over.
        let handoff = NSLock()
        let stall = readabilityStall
        do {
            let process = try streamingClient.makeStreamingProcess(arguments: request.arguments, pipe: pipe)
            activeProcess = process

            pipe.fileHandleForReading.readabilityHandler = { handle in
                handoff.lock()
                defer { handoff.unlock() }
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                stall?()
                continuation.yield(data)
            }

            process.terminationHandler = { _ in
                // Cancelling the source stays outside the lock: an invocation already
                // running holds the lock, so waiting for it while holding the lock
                // ourselves would close a cycle.
                pipe.fileHandleForReading.readabilityHandler = nil
                handoff.lock()
                defer { handoff.unlock() }
                continuation.yield(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.finish()
            }
            try process.run()

            // Started only once the process is actually running, so a launch failure is
            // settled by the catch alone. The stream buffers whatever the handlers
            // yield in the meantime, including a termination that beats this line.
            Task { @MainActor [weak self] in
                for await data in byteStream {
                    self?.consume(data)
                }
                guard let self else { return }
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
                self.advanceSequence(after: request, outcome: self.lastRunOutcome ?? .failure)
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            // No consumer exists on this path, but finishing keeps the stream from
            // outliving the failure and releases anything that ever awaits it.
            continuation.finish()
            activeProcess = nil
            isRunning = false
            runningTitle = nil
            lastRunOutcome = .failure
            selectionAfterRunPath = nil
            cancellationRequested = false
            errorMessage = error.localizedDescription
            activity.append(ActivityLine(message: error.localizedDescription, kind: .error))
            advanceSequence(after: request, outcome: .failure)
        }
    }

    /// Records how one platform finished and starts the next one, if the last one
    /// earned it. Runs that are not part of a release sequence have no leg and no
    /// queue, so this is a no-op for them.
    private func advanceSequence(after request: FRKRunRequest, outcome: RunOutcome) {
        if let platform = request.platform,
           let index = releaseLegs.firstIndex(where: { $0.platform == platform }),
           releaseLegs[index].state == .running {
            releaseLegs[index].state = switch outcome {
            case .success: .succeeded
            case .failure: .failed
            case .cancelled: .cancelled
            }
        }
        guard !queuedRequests.isEmpty else { return }
        guard outcome == .success else {
            queuedRequests = []
            markQueuedLegsSkipped()
            return
        }
        start(queuedRequests.removeFirst(), position: .continuation)
    }

    private func markQueuedLegsSkipped() {
        for index in releaseLegs.indices where releaseLegs[index].state == .queued {
            releaseLegs[index].state = .skipped
        }
    }

    func cancelCurrentJob() {
        guard let activeProcess, activeProcess.isRunning else { return }
        guard !cancellationRequested else { return }
        cancellationRequested = true
        // The rest of a release sequence is abandoned here rather than after the child
        // dies: a cancel means stop, and the platform that has not started must not be
        // uploaded a moment later.
        queuedRequests = []
        markQueuedLegsSkipped()
        activity.append(ActivityLine(message: "Cancellation requested…", kind: .info))
        activeProcess.terminate()
    }

    func clearActivity() {
        guard !isRunning else { return }
        activity = []
        lastRunOutcome = nil
        lastActivityErrorLine = nil
    }

    // Internal rather than private so the stream reader can be driven from tests with
    // the byte splits a real pipe produces.
    func consume(_ data: Data) {
        for line in lineBuffer.feed(data) {
            consumeLine(line)
        }
    }

    func flushRemainder() {
        guard let line = lineBuffer.flush() else { return }
        consumeLine(line)
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
                let isFastlaneErrorLine = message.contains("[!]")
                activity.append(ActivityLine(message: message, kind: isFastlaneErrorLine ? .error : .info))
                if isFastlaneErrorLine {
                    lastActivityErrorLine = message
                }
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

    /// Seeds the version fields for the selected project.
    ///
    /// Both build numbers seed from pubspec's single `+N`, and the version name from
    /// its name half. pubspec is the only local fact FRK has about this release, it is
    /// the user's own file rather than a number this app invented, and it is what the
    /// build would use if no flag were passed at all. Leaving the fields empty would
    /// discard that fact and make every release a typing exercise.
    ///
    /// What deliberately does not seed anything is the store. A store number is a fact
    /// about what is already taken, and writing one into a field would be the app
    /// choosing the next version — the suggestion button exists so a human does. The
    /// two seeded numbers therefore start equal even though the stores have drifted;
    /// the store row sits beside each field and says so once the user checks.
    private func syncVersionFields() {
        guard queuedRequests.isEmpty else {
            // A release sequence is still working through these values. Reverting the
            // fields to pubspec under a running upload would show the wrong numbers
            // for the platform that has not gone out yet.
            return
        }
        guard let project = selectedProject else {
            sharedBuildName = ""
            iosBuildName = ""
            androidBuildNumber = ""
            iosBuildNumber = ""
            return
        }
        sharedBuildName = project.buildName ?? ""
        // Only ever fills a split field that has nothing in it. A reload of the same
        // project happens after every run, and re-seeding here would silently discard
        // an iOS name the user typed deliberately.
        if splitVersionName, iosBuildName.isEmpty {
            iosBuildName = sharedBuildName
        }
        let seeded = project.buildNumber.map(String.init) ?? ""
        androidBuildNumber = seeded
        iosBuildNumber = seeded
    }

    /// A different project means a different release: the queued run and any leg
    /// outcome belong to the project that was selected a moment ago and do not survive
    /// the switch. The store report and the per-platform toggle DO survive — each is
    /// persisted per project, so returning to a project (including across a relaunch)
    /// restores what was last known instead of forcing the user to check again.
    private func projectSelectionChanged() {
        resetStoreCheck()
        releaseLegs = []
        queuedRequests = []
        // Unlike the store report and the toggle below, this is not restored from a
        // per-project cache: it would show one project's build flags labeled as
        // another's for however long the view's own reload takes to land.
        buildArgs = nil
        buildArgsError = nil
        if let projectID = selectedProjectID {
            splitVersionName = UserDefaults.standard.bool(forKey: "frkSplitVersionName.\(projectID)")
            if let data = UserDefaults.standard.data(forKey: "frkStoreVersionsCache.\(projectID)"),
               let cached = try? JSONDecoder().decode(StoreVersionsResponse.self, from: data) {
                storeVersions = cached
            }
        } else {
            splitVersionName = false
        }
        iosBuildName = ""
        syncVersionFields()
    }
}

private func liveClient(path: String) -> FRKClientProtocol {
    FRKClient(executableURL: URL(fileURLWithPath: path))
}

private extension Int {
    init(_ text: String, default fallback: Int) {
        self = Int(text) ?? fallback
    }
}
