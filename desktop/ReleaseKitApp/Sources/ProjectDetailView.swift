import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    /// The platforms the pending confirmation would upload, in the order they run.
    /// Empty means no dialog.
    @State private var pendingRelease: [PlatformKind] = []
    @State private var pendingValidation = false
    @State private var showSetupAssistant = false
    @State private var pendingRemoval = false
    @State private var newAndroidBuildArg = ""
    @State private var newIOSBuildArg = ""
    @State private var isBuildArgsExpanded = false

    private var project: ProjectSummary? { model.selectedProject }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let project {
                    VStack(alignment: .leading, spacing: 18) {
                        projectHeader(project)
                        releaseVersionCard(project)
                        buildArgsCard(project)
                        screenshotStudioCard(project)

                        ForEach(project.platforms) { platform in
                            platformCard(project, platform: platform)
                        }

                        artifactsCard(project)
                    }
                    .padding(geometry.size.width < 720 ? 16 : 24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            pendingRelease.count > 1 ? "Upload these builds?" : "Upload this build?",
            isPresented: Binding(
                get: { !pendingRelease.isEmpty },
                set: { if !$0 { pendingRelease = [] } }
            ),
            titleVisibility: .visible
        ) {
            if !pendingRelease.isEmpty {
                Button(confirmationButtonTitle(pendingRelease)) {
                    startRelease(pendingRelease)
                    pendingRelease = []
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRelease = []
            }
        } message: {
            if !pendingRelease.isEmpty {
                Text(releaseConfirmation(pendingRelease))
            }
        }
        .confirmationDialog(
            "Validate this build on Google Play?",
            isPresented: $pendingValidation,
            titleVisibility: .visible
        ) {
            Button("Send for Validation") {
                if let project {
                    model.start(versionedRequest(.validate, project: project.id, platform: .android))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The AAB will be built and sent to Google Play's validation API. No release will be created on any track.")
        }
        .confirmationDialog(
            project.map { "Remove \($0.name) from Flutter Release Kit?" } ?? "Remove this project?",
            isPresented: $pendingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from managed projects", role: .destructive) {
                if let project {
                    model.start(FRKRunRequest(action: .forget, project: project.id))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the entry in Flutter Release Kit will be removed. The project folder, source code, release configuration, signing files, and build artifacts will not be deleted or changed.")
        }
        .sheet(isPresented: $showSetupAssistant) {
            if let project {
                SetupAssistantView(project: project)
                    .environmentObject(model)
            }
        }
    }

    @ViewBuilder
    private func projectHeader(_ project: ProjectSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.frkAccent.gradient)
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        projectName(project)
                        onboardingBadge(project)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        projectName(project)
                        onboardingBadge(project)
                    }
                }
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Project folder: \(project.path)")
                HStack(spacing: 6) {
                    ForEach(project.platforms) { platform in
                        PlatformPill(platform: platform)
                    }
                }
            }
            Spacer()
            Menu {
                Button("Reveal Project in Finder") {
                    model.revealProject()
                }
                .help("Open the project folder in Finder. No files are changed.")
                Divider()
                Button("Run Doctor") {
                    model.start(FRKRunRequest(action: .doctor, project: project.id))
                }
                .help(doctorHelp(project))
                Button("Verify Analysis & Tests") {
                    model.start(FRKRunRequest(action: .verify, project: project.id))
                }
                .help(verifyHelp(project))
                Button("Screenshot Studio…") {
                    model.showScreenshotStudio = true
                }
                .help("Capture or import an app screen, add an Android or iPhone frame, and export a PNG. Nothing is uploaded.")
                Divider()
                Button("Remove from Flutter Release Kit…", role: .destructive) {
                    pendingRemoval = true
                }
                .help("Remove only this project from FRK's managed list. Project files, credentials, signing material, and artifacts remain untouched.")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isRunning)
            .help("Project actions: reveal, inspect, verify, or remove this project from the managed list.")
        }
    }

    @ViewBuilder
    private func projectName(_ project: ProjectSummary) -> some View {
        Text(project.name)
            .font(.largeTitle.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func onboardingBadge(_ project: ProjectSummary) -> some View {
        StatusBadge(text: project.isReady ? "Onboarded" : "Needs attention", isReady: project.isReady)
    }

    @ViewBuilder
    private func releaseVersionCard(_ project: ProjectSummary) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        versionCardTitle
                        Spacer()
                        currentVersion(project)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        versionCardTitle
                        currentVersion(project)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) {
                        versionNameFields
                        Spacer(minLength: 16)
                        storeCheckControls
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        versionNameFields
                        storeCheckControls
                    }
                }

                if let note = model.storeCheckNote {
                    Label(note, systemImage: model.isCheckingStores ? "clock" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(project.platforms) { platform in
                        buildNumberRow(platform)
                    }
                }

                ForEach(project.platforms) { platform in
                    if !model.canRunVersionedAction(for: platform) {
                        Label(
                            "\(platform.title) needs a version name and a positive numeric \(platform.buildNumberLabel).",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) {
                        versionChecks(project)
                        Spacer(minLength: 16)
                        releaseBothButton(project)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        versionChecks(project)
                        releaseBothButton(project)
                    }
                }

                releaseOutcomeSummary
            }
        }
    }

    // MARK: - Extra build flags

    /// Local and instant — a `fastlane/release_kit.yml` read, no network — so this
    /// loads eagerly on every selection rather than waiting for a button the way the
    /// store report does.
    private func buildArgsCard(_ project: ProjectSummary) -> some View {
        SectionCard {
            DisclosureGroup(isExpanded: $isBuildArgsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Appended to every `flutter build` for this project, after this tool's own flags and before the version numbers. For --dart-define and anything else the release pipeline has no opinion about.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = model.buildArgsError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let record = model.buildArgs {
                        if !record.shared.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Shared with every platform").font(.caption.weight(.medium))
                                Text(record.shared.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .help("Set by hand in fastlane/release_kit.yml's top-level extra_build_args. Not editable here.")
                        }

                        ForEach(project.platforms) { platform in
                            buildArgsPlatformSection(platform, projectID: project.id, record: record)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Extra build flags").font(.headline)
                    if model.isLoadingBuildArgs || model.isSavingBuildArgs {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        // Loads in the background regardless of whether the section is expanded, so
        // the data is already there the moment a user opens it instead of popping in.
        .task(id: project.id) {
            await model.loadBuildArgs(for: project.id)
        }
    }

    @ViewBuilder
    private func buildArgsPlatformSection(_ platform: PlatformKind, projectID: String, record: BuildArgsResponse) -> some View {
        let own = platform == .android ? record.android.own : record.ios.own
        VStack(alignment: .leading, spacing: 6) {
            Text("\(platform.title) only").font(.caption.weight(.medium))

            ForEach(Array(own.enumerated()), id: \.offset) { index, arg in
                HStack(spacing: 6) {
                    Text(arg).font(.caption.monospaced())
                    Spacer()
                    Button {
                        var updated = own
                        updated.remove(at: index)
                        Task { await model.setBuildArgs(for: projectID, platform: platform, args: updated) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isSavingBuildArgs)
                    .help("Remove this flag from \(platform.title)")
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "--dart-define=KEY=value",
                    text: platform == .android ? $newAndroidBuildArg : $newIOSBuildArg
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .onSubmit { addBuildArg(platform, projectID: projectID, own: own) }
                Button("Add") { addBuildArg(platform, projectID: projectID, own: own) }
                    .disabled(model.isSavingBuildArgs || currentBuildArgDraft(platform).trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func currentBuildArgDraft(_ platform: PlatformKind) -> String {
        platform == .android ? newAndroidBuildArg : newIOSBuildArg
    }

    private func addBuildArg(_ platform: PlatformKind, projectID: String, own: [String]) {
        let value = currentBuildArgDraft(platform).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if platform == .android { newAndroidBuildArg = "" } else { newIOSBuildArg = "" }
        Task { await model.setBuildArgs(for: projectID, platform: platform, args: own + [value]) }
    }

    @ViewBuilder
    private var storeCheckControls: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                if model.isCheckingStores {
                    ProgressView()
                        .controlSize(.small)
                    Button("Stop") {
                        model.cancelStoreCheck()
                    }
                    .help("Stop waiting for the stores. Nothing was changed in either store; the query itself keeps running on its own for a short while.")
                } else {
                    Button("Check stores") {
                        model.checkStoreVersions()
                    }
                    .disabled(!model.canCheckStoreVersions)
                    .help(
                        "Ask Google Play and App Store Connect which versions they already hold. "
                            + "Read-only: nothing is built, uploaded, or changed. It reaches the network and can take a couple of minutes.\n"
                            + "Command: \(CommandPreview.frk(["api", "store-versions", project?.id ?? "<project>"]))"
                    )
                }
            }
            // The report shown may be restored from a previous session rather than just
            // fetched, so its age is always visible next to the button that refreshes it.
            if !model.isCheckingStores, let checkedAt = model.storeVersionsCheckedAtDisplay {
                Text(checkedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func buildNumberRow(_ platform: PlatformKind) -> some View {
        let row = model.storeRow(for: platform)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                buildNumberField(platform)
                storeStatus(platform, row: row)
                Spacer(minLength: 12)
                suggestionButton(platform, row: row)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 12) {
                    buildNumberField(platform)
                    suggestionButton(platform, row: row)
                }
                storeStatus(platform, row: row)
            }
        }
    }

    @ViewBuilder
    private func buildNumberField(_ platform: PlatformKind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(platform.title)  \(platform.buildNumberLabel)")
                .font(.caption.weight(.medium))
            TextField(
                platform == .android ? "39" : "42",
                text: Binding(
                    get: { model.buildNumber(for: platform) },
                    set: { model.setBuildNumber($0, for: platform) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 90, idealWidth: 110, maxWidth: 130)
            .help(
                "\(platform.storeName) build number for the next command, passed as --build-number. "
                    + "\(platform.storeName) counts uploads separately from the other store, so this number is not shared and is never increased automatically. "
                    + "Current input: \(model.buildNumber(for: platform).isEmpty ? "not set" : model.buildNumber(for: platform))"
            )
        }
    }

    /// Renders all four statuses distinctly. A store that failed to answer is never
    /// drawn as a store that answered and holds nothing.
    @ViewBuilder
    private func storeStatus(_ platform: PlatformKind, row: StoreVersionRow?) -> some View {
        if let row {
            VStack(alignment: .leading, spacing: 2) {
                Label(row.headline, systemImage: storeStatusIcon(row.kind))
                    .font(.caption)
                    .foregroundStyle(storeStatusColor(row.kind))
                if let supplement = row.supplement {
                    Text(supplement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if row.conflicts(with: model.buildNumber(for: platform)) {
                    Text("\(platform.storeName) already holds this number; the upload would be rejected.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .help(row.detail)
        } else {
            Text("Store not checked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func storeStatusIcon(_ kind: StoreVersionRow.Kind) -> String {
        switch kind {
        case .known: "checkmark.circle"
        case .empty: "circle.dashed"
        case .notConfigured: "minus.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func storeStatusColor(_ kind: StoreVersionRow.Kind) -> Color {
        switch kind {
        case .known: Color.primary
        case .empty: Color.secondary
        case .notConfigured: Color.secondary
        case .failed: Color.orange
        }
    }

    /// Shown only when a real latest value came back, and it only ever fills the field
    /// on a click. FRK never chooses a version number on its own.
    @ViewBuilder
    private func suggestionButton(_ platform: PlatformKind, row: StoreVersionRow?) -> some View {
        if let suggestion = row?.suggestion {
            Button("Use \(suggestion)") {
                model.applySuggestedBuildNumber(for: platform)
            }
            .help("Fill the \(platform.buildNumberLabel) field with \(suggestion), one above the \(row?.latest ?? suggestion - 1) \(platform.storeName) already holds. The field stays editable and nothing is built until you start a build.")
        }
    }

    @ViewBuilder
    private func releaseBothButton(_ project: ProjectSummary) -> some View {
        if project.platforms.count > 1 {
            let runnable = model.runnablePlatforms(of: project)
            let ready = project.platforms.allSatisfy { project.readiness(for: $0).ready && storeCredentialsConfigured(for: $0) }
            Button {
                pendingRelease = project.platforms
            } label: {
                Label("Upload to Both Stores", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.isRunning || !ready || runnable.count != project.platforms.count)
            .help(
                "Runs one upload per platform, each with its own version numbers. The two uploads are not atomic: the first can succeed and the second fail, and the result is reported per platform.\n"
                    + project.platforms.map { platform in
                        model.versionedRequest(.release, project: project.id, platform: platform).commandPreview
                    }.joined(separator: "\n")
            )
        }
    }

    @ViewBuilder
    private var releaseOutcomeSummary: some View {
        if !model.releaseLegs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Upload result")
                    .font(.caption.weight(.semibold))
                ForEach(model.releaseLegs) { leg in
                    HStack(spacing: 8) {
                        Image(systemName: legIcon(leg.state))
                            .foregroundStyle(legColor(leg.state))
                        Text("\(leg.platform.title) \(leg.buildName) (\(leg.buildNumber))")
                            .font(.caption.weight(.medium))
                        Text(leg.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func legIcon(_ state: ReleaseLeg.State) -> String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .skipped: "minus.circle"
        }
    }

    private func legColor(_ state: ReleaseLeg.State) -> Color {
        switch state {
        case .succeeded: .green
        case .failed: .red
        case .cancelled, .skipped: .orange
        case .queued, .running: .secondary
        }
    }

    @ViewBuilder
    private var versionCardTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Release version")
                .font(.headline)
            Text("Used for the next build; your pubspec is not edited automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func screenshotStudioCard(_ project: ProjectSummary) -> some View {
        SectionCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    screenshotStudioDescription(project)
                    Spacer(minLength: 16)
                    screenshotStudioButton
                }
                VStack(alignment: .leading, spacing: 14) {
                    screenshotStudioDescription(project)
                    screenshotStudioButton
                }
            }
        }
    }

    private func screenshotStudioDescription(_ project: ProjectSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(Color.frkAccent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Screenshot Studio")
                    .font(.headline)
                Text("Capture \(project.platforms.map(\.title).joined(separator: " and ")) screens, add a clean phone frame, and export store-ready PNG files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var screenshotStudioButton: some View {
        Button {
            model.showScreenshotStudio = true
        } label: {
            Label("Create Screenshots", systemImage: "camera.fill")
        }
        .buttonStyle(.borderedProminent)
        .help("Capture a running Android emulator or iOS Simulator, or import an image, then add a phone frame and export a PNG. Nothing is uploaded.")
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private func currentVersion(_ project: ProjectSummary) -> some View {
        if let version = project.version {
            Text("Current: \(version)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var versionNameFields: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.splitVersionName ? "Android version name" : "Version name")
                    .font(.caption.weight(.medium))
                TextField("2.1.0", text: $model.sharedBuildName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 110, idealWidth: 150, maxWidth: 170)
                    .help("Marketing version for the next command, passed as --build-name. FRK does not edit pubspec.yaml automatically. Current input: \(model.sharedBuildName.isEmpty ? "not set" : model.sharedBuildName)")
            }
            if model.splitVersionName {
                VStack(alignment: .leading, spacing: 5) {
                    Text("iOS version name")
                        .font(.caption.weight(.medium))
                    TextField("2.1.0", text: $model.iosBuildName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110, idealWidth: 150, maxWidth: 170)
                        .help("Marketing version sent to App Store Connect, passed as --build-name on the iOS invocation. Current input: \(model.iosBuildName.isEmpty ? "not set" : model.iosBuildName)")
                }
            }
            Toggle("Different per platform", isOn: $model.splitVersionName)
                .toggleStyle(.checkbox)
                .help("Usually one release ships under one version name. Turn this on for the rare case where one store gets a different marketing version, such as a hotfix shipped to a single store.")
        }
    }

    @ViewBuilder
    private func versionChecks(_ project: ProjectSummary) -> some View {
        HStack(spacing: 10) {
            Button("Doctor") {
                model.start(FRKRunRequest(action: .doctor, project: project.id))
            }
            .help(doctorHelp(project))
            Button("Verify") {
                model.start(FRKRunRequest(action: .verify, project: project.id))
            }
            .help(verifyHelp(project))
        }
    }

    @ViewBuilder
    private func platformCard(_ project: ProjectSummary, platform: PlatformKind) -> some View {
        let readiness = project.readiness(for: platform)
        SectionCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label(platform.title, systemImage: platform.systemImage)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    StatusBadge(text: readiness.label, isReady: readiness.ready)
                }

                Divider()

                platformDetails(project, platform: platform)

                if !readiness.ready {
                    HStack(spacing: 10) {
                        Label("Release setup is incomplete", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button {
                            showSetupAssistant = true
                        } label: {
                            Label("Fix Setup", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                        .help("Inspect the missing signing or release requirements and open the guided repair assistant. Nothing is uploaded.")
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                if readiness.ready && !storeCredentialsConfigured(for: platform) {
                    HStack(spacing: 10) {
                        Label(
                            platform == .android
                                ? "Google Play credentials are not configured"
                                : "App Store Connect credentials are not configured",
                            systemImage: "key.horizontal.fill"
                        )
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            model.showSettings = true
                        }
                        .help("Open Store Credentials settings for this Mac. Local builds remain available without store credentials.")
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                Text(releaseStepsCaption(platform))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        localPlatformActions(project, platform: platform)
                        Spacer(minLength: 16)
                        uploadButton(project, platform: platform, readiness: readiness.ready)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            localPlatformActions(project, platform: platform)
                        }
                        HStack {
                            Spacer()
                            uploadButton(project, platform: platform, readiness: readiness.ready)
                        }
                    }
                }
                .disabled(model.isRunning || !model.canRunVersionedAction(for: platform) || !readiness.ready)
            }
        }
    }

    @ViewBuilder
    private func localPlatformActions(_ project: ProjectSummary, platform: PlatformKind) -> some View {
        let buildRequest = versionedRequest(.build, project: project.id, platform: platform)
        Button {
            model.start(buildRequest)
        } label: {
            Label("Build", systemImage: "hammer")
        }
        .buttonStyle(.bordered)
        .help(buildHelp(buildRequest, platform: platform))

        if platform == .android {
            let validationRequest = versionedRequest(.validate, project: project.id, platform: .android)
            Button {
                pendingValidation = true
            } label: {
                Label("Validate", systemImage: "checkmark.shield")
            }
            .buttonStyle(.bordered)
            .disabled(!storeCredentialsConfigured(for: .android))
            .help(validationHelp(validationRequest))
        }
    }

    @ViewBuilder
    private func uploadButton(_ project: ProjectSummary, platform: PlatformKind, readiness: Bool) -> some View {
        let releaseRequest = versionedRequest(.release, project: project.id, platform: platform)
        Button {
            pendingRelease = [platform]
        } label: {
            Label(releaseButtonTitle(platform), systemImage: "arrow.up.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!readiness || !storeCredentialsConfigured(for: platform))
        .help(releaseHelp(releaseRequest, platform: platform))
    }

    private func storeCredentialsConfigured(for platform: PlatformKind) -> Bool {
        switch platform {
        case .android:
            model.credentialsStatus?.googlePlay?.configured == true
        case .ios:
            model.credentialsStatus?.appStoreConnect?.configured == true
        }
    }

    @ViewBuilder
    private func platformDetails(_ project: ProjectSummary, platform: PlatformKind) -> some View {
        switch platform {
        case .android:
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                detailRow("Application ID", project.android?.packageId ?? "Not detected")
                detailRow("Play track", project.android?.track ?? "internal")
                detailRow("Upload key", project.android?.signingReady == true ? "Validated and ready" : "Needs setup")
            }
        case .ios:
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                detailRow("Bundle ID", project.ios?.bundleId ?? "Not detected")
                detailRow("Apple team", project.ios?.teamId ?? "Not configured")
                detailRow("Provisioning", project.ios?.profileReady == true ? "Profile ready" : "Needs setup")
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 105, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func artifactsCard(_ project: ProjectSummary) -> some View {
        let available = [project.artifacts.androidAab, project.artifacts.iosIpa].compactMap { $0 }
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Latest artifacts")
                    .font(.headline)
                if available.isEmpty {
                    Text("No release artifact has been found yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(available, id: \.path) { artifact in
                        HStack {
                            Image(systemName: artifact.path.hasSuffix(".aab") ? "shippingbox" : "archivebox")
                                .foregroundStyle(Color.frkAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: artifact.path).lastPathComponent)
                                    .font(.callout.weight(.medium))
                                Text("\(artifact.formattedSize) · \(artifact.modifiedAt)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal") {
                                model.revealArtifact(artifact)
                            }
                            .help("Show this existing artifact in Finder. Nothing is rebuilt or uploaded.\nPath: \(artifact.path)")
                        }
                    }
                }
            }
        }
    }

    private func versionedRequest(_ action: JobAction, project: String, platform: PlatformKind) -> FRKRunRequest {
        model.versionedRequest(action, project: project, platform: platform)
    }

    private func startRelease(_ platforms: [PlatformKind]) {
        guard let project else { return }
        model.startRelease(project: project.id, platforms: platforms)
    }

    private func releaseButtonTitle(_ platform: PlatformKind) -> String {
        platform == .android ? "Upload to Play Internal" : "Upload to TestFlight"
    }

    private func confirmationButtonTitle(_ platforms: [PlatformKind]) -> String {
        platforms.count == 1 ? releaseButtonTitle(platforms[0]) : "Upload to Both Stores"
    }

    /// Names every version that is about to go out, one line per platform, because the
    /// two platforms no longer share a build number and can differ in name too.
    private func releaseConfirmation(_ platforms: [PlatformKind]) -> String {
        let lines = platforms.map { platform -> String in
            let destination = platform == .android ? "Google Play's internal testing track" : "Apple TestFlight"
            return "\(platform.title) \(model.buildName(for: platform)) (build \(model.buildNumber(for: platform))) will be built and uploaded to \(destination)."
        }
        let notAtomic = platforms.count > 1
            ? " These run as two separate uploads and are not atomic: the first can succeed and the second fail. The result is reported per platform."
            : ""
        return lines.joined(separator: " ") + notAtomic
            + " Public production release is not available in Release Kit."
    }

    private func doctorHelp(_ project: ProjectSummary) -> String {
        let request = FRKRunRequest(action: .doctor, project: project.id)
        return "Checks configuration, credentials, signing, and store readiness without building or uploading.\nCommand: \(request.commandPreview)"
    }

    private func verifyHelp(_ project: ProjectSummary) -> String {
        let request = FRKRunRequest(action: .verify, project: project.id)
        return "Runs Flutter analysis and the project's tests. No release artifact is uploaded.\nCommand: \(request.commandPreview)"
    }

    /// The three buttons below read as three peers, but only one of them ships anything —
    /// Upload builds for you. This is the one-line version of that; the Help window (⌘?)
    /// has the long version.
    private func releaseStepsCaption(_ platform: PlatformKind) -> String {
        let upload = releaseButtonTitle(platform)
        if platform == .android {
            return "\(upload) is the only button you need — it builds and publishes in one step. Build only compiles; Validate checks Google Play without publishing."
        }
        return "\(upload) is the only button you need — it builds and publishes in one step. Build only compiles, nothing more. (Apple has no publish-free check, so there's no Validate here.)"
    }

    private func buildHelp(_ request: FRKRunRequest, platform: PlatformKind) -> String {
        let artifact = platform == .android
            ? "a signed Android App Bundle (.aab)"
            : "an App Store archive and exported IPA"
        return "Builds version \(displayVersion(platform)) for \(platform.title) and creates \(artifact). Nothing is uploaded.\nCommand: \(request.commandPreview)"
    }

    private func validationHelp(_ request: FRKRunRequest) -> String {
        let availability = storeCredentialsConfigured(for: .android)
            ? ""
            : "Unavailable until Google Play credentials are configured.\n"
        return "\(availability)Builds version \(displayVersion(.android)) and sends the AAB to Google Play for validation only. No track release is created.\nCommand: \(request.commandPreview)"
    }

    private func releaseHelp(_ request: FRKRunRequest, platform: PlatformKind) -> String {
        let destination = platform == .android
            ? "Google Play internal testing"
            : "Apple TestFlight"
        let availability = storeCredentialsConfigured(for: platform)
            ? ""
            : "Unavailable until the \(platform == .android ? "Google Play" : "App Store Connect") credential is configured.\n"
        return "\(availability)Builds and uploads version \(displayVersion(platform)) to \(destination). A confirmation appears before execution.\nCommand: \(request.commandPreview)"
    }

    private func displayVersion(_ platform: PlatformKind) -> String {
        let name = model.buildName(for: platform)
        let number = model.buildNumber(for: platform)
        return "\(name.isEmpty ? "<version>" : name) (build \(number.isEmpty ? "<build number>" : number))"
    }
}
