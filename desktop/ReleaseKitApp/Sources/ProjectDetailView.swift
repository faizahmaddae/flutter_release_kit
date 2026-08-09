import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingRelease: PlatformKind?
    @State private var pendingValidation = false
    @State private var showSetupAssistant = false
    @State private var pendingRemoval = false

    private var project: ProjectSummary? { model.selectedProject }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let project {
                    VStack(alignment: .leading, spacing: 18) {
                        projectHeader(project)
                        releaseVersionCard(project)

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
            "Upload this build?",
            isPresented: Binding(
                get: { pendingRelease != nil },
                set: { if !$0 { pendingRelease = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingRelease {
                Button(releaseButtonTitle(pendingRelease)) {
                    startRelease(pendingRelease)
                    self.pendingRelease = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRelease = nil
            }
        } message: {
            if let pendingRelease {
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
                        versionFields
                        Spacer(minLength: 16)
                        versionChecks(project)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .bottom, spacing: 12) {
                            versionFields
                        }
                        versionChecks(project)
                    }
                }

                if !model.canRunVersionedAction {
                    Label("Enter a version name and a positive numeric build number.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
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
    private func currentVersion(_ project: ProjectSummary) -> some View {
        if let version = project.version {
            Text("Current: \(version)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var versionFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Version name")
                .font(.caption.weight(.medium))
            TextField("2.1.0", text: $model.buildName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, idealWidth: 150, maxWidth: 170)
                .help("Marketing version for the next command, passed as --build-name. FRK does not edit pubspec.yaml automatically. Current input: \(model.buildName.isEmpty ? "not set" : model.buildName)")
        }
        VStack(alignment: .leading, spacing: 5) {
            Text("Build number")
                .font(.caption.weight(.medium))
            TextField("39", text: $model.buildNumber)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 120, maxWidth: 140)
                .help("Store build number / Android versionCode for the next command, passed as --build-number. It is not increased automatically. Current input: \(model.buildNumber.isEmpty ? "not set" : model.buildNumber)")
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
        let readiness = readiness(for: project, platform: platform)
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
                .disabled(model.isRunning || !model.canRunVersionedAction || !readiness.ready)
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
            pendingRelease = platform
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

    private func readiness(for project: ProjectSummary, platform: PlatformKind) -> (ready: Bool, label: String) {
        switch platform {
        case .android:
            let ready = project.android?.signingReady == true
            return (ready, ready ? "Signing ready" : "Signing required")
        case .ios:
            let ready = project.ios?.signingReady ?? (project.ios?.profileReady == true)
            let missing = project.ios?.profileReady == false ? "Profile required" : "Signing required"
            return (ready, ready ? "Signing ready" : missing)
        }
    }

    private func versionedRequest(_ action: JobAction, project: String, platform: PlatformKind) -> FRKRunRequest {
        FRKRunRequest(
            action: action,
            project: project,
            platform: platform,
            buildName: model.buildName,
            buildNumber: model.buildNumber
        )
    }

    private func startRelease(_ platform: PlatformKind) {
        guard let project else { return }
        model.start(versionedRequest(.release, project: project.id, platform: platform))
    }

    private func releaseButtonTitle(_ platform: PlatformKind) -> String {
        platform == .android ? "Upload to Play Internal" : "Upload to TestFlight"
    }

    private func releaseConfirmation(_ platform: PlatformKind) -> String {
        let destination = platform == .android ? "Google Play's internal testing track" : "Apple TestFlight"
        return "Version \(model.buildName) (\(model.buildNumber)) will be built and uploaded to \(destination). Public production release is not available in Release Kit."
    }

    private func doctorHelp(_ project: ProjectSummary) -> String {
        let request = FRKRunRequest(action: .doctor, project: project.id)
        return "Checks configuration, credentials, signing, and store readiness without building or uploading.\nCommand: \(request.commandPreview)"
    }

    private func verifyHelp(_ project: ProjectSummary) -> String {
        let request = FRKRunRequest(action: .verify, project: project.id)
        return "Runs Flutter analysis and the project's tests. No release artifact is uploaded.\nCommand: \(request.commandPreview)"
    }

    private func buildHelp(_ request: FRKRunRequest, platform: PlatformKind) -> String {
        let artifact = platform == .android
            ? "a signed Android App Bundle (.aab)"
            : "an App Store archive and exported IPA"
        return "Builds version \(displayVersion) for \(platform.title) and creates \(artifact). Nothing is uploaded.\nCommand: \(request.commandPreview)"
    }

    private func validationHelp(_ request: FRKRunRequest) -> String {
        let availability = storeCredentialsConfigured(for: .android)
            ? ""
            : "Unavailable until Google Play credentials are configured.\n"
        return "\(availability)Builds version \(displayVersion) and sends the AAB to Google Play for validation only. No track release is created.\nCommand: \(request.commandPreview)"
    }

    private func releaseHelp(_ request: FRKRunRequest, platform: PlatformKind) -> String {
        let destination = platform == .android
            ? "Google Play internal testing"
            : "Apple TestFlight"
        let availability = storeCredentialsConfigured(for: platform)
            ? ""
            : "Unavailable until the \(platform == .android ? "Google Play" : "App Store Connect") credential is configured.\n"
        return "\(availability)Builds and uploads version \(displayVersion) to \(destination). A confirmation appears before execution.\nCommand: \(request.commandPreview)"
    }

    private var displayVersion: String {
        let name = model.buildName.isEmpty ? "<version>" : model.buildName
        let number = model.buildNumber.isEmpty ? "<build number>" : model.buildNumber
        return "\(name) (build \(number))"
    }
}
