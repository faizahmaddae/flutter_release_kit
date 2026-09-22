import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let project: ProjectSummary
    let platform: PlatformKind

    @State private var selectedPropertiesPath: String?
    @State private var selectedKeystorePath: String?
    @State private var pendingAndroidImport = false
    @State private var pendingIOSRepair = false
    @State private var showLostKeyHelp = false
    @State private var showStoreConnections = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                Group {
                    if model.isLoadingSetup && model.setupStatus?.projectId != project.id {
                        ProgressView("Inspecting release setup…")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if let status = model.setupStatus,
                              status.projectId == project.id {
                        VStack(spacing: 16) {
                            if platform == .android, let android = status.android {
                                androidCard(android)
                            } else if platform == .ios, let ios = status.ios {
                                iosCard(ios)
                            } else {
                                setupUnavailable
                            }
                        }
                        .disabled(model.isLoadingSetup || model.isRunning)
                    } else {
                        setupUnavailable
                    }
                }
                .padding(22)
            }

            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 650)
        .task {
            await model.loadSetupStatus(for: project.id)
        }
        .onDisappear {
            model.clearSetupStatus()
        }
        .sheet(isPresented: $showStoreConnections, onDismiss: {
            Task { await model.loadSetupStatus(for: project.id) }
        }) {
            StoreConnectionsView(presentation: .settings)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Import this Android upload key?",
            isPresented: $pendingAndroidImport,
            titleVisibility: .visible
        ) {
            Button("Import to Vault & Link Project") {
                model.start(signingImportRequest)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The source file will be preserved. FRK will validate the key, copy it into the private vault, back up the project's current key.properties, and link the project to the vault copy.")
        }
        .confirmationDialog(
            "Repair iOS signing automatically?",
            isPresented: $pendingIOSRepair,
            titleVisibility: .visible
        ) {
            Button("Create or Refresh Signing") {
                model.start(FRKRunRequest(action: .iosSetupSigning, project: project.id))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FRK will update export settings and Xcode's Release signing configuration, backing up existing files. Your App Store Connect API key will be used to reuse or create an Apple Distribution certificate and refresh this app's provisioning profile. Apple account state may change; no build will be uploaded.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.frkAccent.gradient, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(platform.title) setup")
                    .font(.title2.bold())
                Text("\(project.name) · Review signing and resolve setup issues")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(22)
    }

    private var setupUnavailable: some View {
        ContentUnavailableView(
            "\(platform.title) setup status unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("Check again or verify the CLI connection in Settings.")
        )
    }

    private var footer: some View {
        HStack {
            Button("Close", role: .cancel) {
                dismiss()
            }
            Spacer()
            Button {
                Task { await model.loadSetupStatus(for: project.id) }
            } label: {
                HStack(spacing: 6) {
                    if model.isLoadingSetup {
                        ProgressView().controlSize(.small)
                    }
                    Label(model.isLoadingSetup ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isLoadingSetup || model.isRunning)
            .help("Re-read local project files, Keychain identities, provisioning profiles, Git safety, and vault links. Nothing is repaired or uploaded.")
            Button("Run Full Check") {
                model.start(FRKRunRequest(action: .doctor, project: project.id))
                dismiss()
            }
            .disabled(model.isLoadingSetup || model.isRunning)
            .help("Check both platforms, local tools, and store access, and show the results in Activity. This may contact the stores; it does not repair setup or upload a build.\nCommand: \(FRKRunRequest(action: .doctor, project: project.id).commandPreview)")
        }
        .padding(18)
    }

    @ViewBuilder
    private func androidCard(_ status: AndroidSetupStatus) -> some View {
        let localKeyIsValid = status.projectPropertiesExists
            && status.propertiesComplete
            && status.keystoreExists
            && status.keystoreValidationStatus == "valid"

        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Android release signing", systemImage: "key.horizontal.fill")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    StatusBadge(
                        text: status.signingReady ? "Ready" : "Needs attention",
                        isReady: status.signingReady
                    )
                }

                Divider()

                SetupCheckRow(
                    title: "key.properties",
                    detail: status.propertiesDetail,
                    state: status.projectPropertiesExists && status.propertiesComplete ? .ready : .error
                )

                SetupCheckRow(
                    title: "Upload keystore",
                    detail: status.keystoreDetail,
                    state: status.keystoreState
                )

                if let gradleReady = status.gradleConfigured {
                    SetupCheckRow(
                        title: "Gradle release configuration",
                        detail: status.gradleConfigurationDetail ?? "Release signing configuration could not be inspected",
                        state: gradleReady ? .ready : .error
                    )
                }

                SetupCheckRow(
                    title: "Git safety",
                    detail: status.gitDetail,
                    state: (status.gitSafe ?? !status.gitTracked) ? .ready : .error
                )

                if status.vaultReady && status.projectLinked {
                    SetupCheckRow(title: "Private vault", detail: status.vaultDetail, state: .ready)
                }

                if !localKeyIsValid {
                    if status.vaultReady && !status.projectLinked {
                        linkProtectedCopyButton
                            .buttonStyle(.borderedProminent)
                    } else {
                        signingFileControls(status)
                    }
                }

                if status.gradleConfigured == false,
                   let path = status.gradleConfigurationPath {
                    Button("Open Gradle Configuration") {
                        openPath(path)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Open the Gradle file that FRK inspected so you can wire the release signing configuration manually.\nPath: \(path)")
                }

                if status.gitSafe == false {
                    Text("Add missing ignore rules and remove any tracked signing files from the Git index before continuing. FRK will not change repository history automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if localKeyIsValid && (!status.vaultReady || !status.projectLinked) {
                    DisclosureGroup("Optional: protect a copy in the vault") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(status.vaultDetail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if status.vaultReady {
                                linkProtectedCopyButton
                            } else {
                                Button {
                                    pendingAndroidImport = true
                                } label: {
                                    Label("Protect in Vault & Link…", systemImage: "lock.shield")
                                }
                                .help("Validate the current key.properties and keystore, preserve their source, copy a protected version into the private vault, back up the project pointer, and link it.\nCommand: \(signingImportRequest.commandPreview)")
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                }

                if !localKeyIsValid {
                    DisclosureGroup("I cannot find the original upload key", isExpanded: $showLostKeyHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Do not generate a replacement silently. Existing Play apps require an Upload Key Reset in Google Play Console; the App Signing key remains managed by Google.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Open Google Play Console") {
                                openURL("https://play.google.com/console")
                            }
                            .help("Open Google Play Console in the browser to request an Upload Key Reset. FRK does not generate or submit the reset request automatically.")
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                    .help("Use this only when the original Android upload key is genuinely unavailable. Creating a random replacement will not work for an existing Play app.")
                }
            }
        }
    }

    private var linkProtectedCopyButton: some View {
        Button {
            model.start(FRKRunRequest(action: .signingLink, project: project.id))
            dismiss()
        } label: {
            Label("Link Protected Copy", systemImage: "link")
        }
        .help("Point this project's ignored android/key.properties to the already protected copy in the private vault. The keystore is not copied again.\nCommand: \(FRKRunRequest(action: .signingLink, project: project.id).commandPreview)")
    }

    @ViewBuilder
    private func signingFileControls(_ status: AndroidSetupStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !status.projectPropertiesExists
                    || !status.propertiesComplete
                    || status.keystoreValidationStatus == "invalid" {
                    Button("Choose key.properties…") {
                        if let path = chooseFile(
                            title: "Choose the original key.properties",
                            extensions: ["properties"]
                        ) {
                            if path != selectedPropertiesPath {
                                selectedKeystorePath = nil
                            }
                            selectedPropertiesPath = path
                        }
                    }
                    .help("Choose the original complete Android key.properties containing storeFile, storePassword, keyAlias, and keyPassword. Its secret values are never displayed or passed as command arguments.")
                }
                if status.propertiesComplete || selectedPropertiesPath != nil {
                    Button("Choose Keystore…") {
                        if let path = chooseFile(
                            title: "Choose the original Android upload key",
                            extensions: ["jks", "keystore"]
                        ) {
                            selectedKeystorePath = path
                        }
                    }
                    .help("Choose the original .jks or .keystore referenced by key.properties. FRK validates it together with the properties file and preserves the source.")
                }
            }

            if let selectedPropertiesPath {
                SelectedFileRow(label: "Properties", path: selectedPropertiesPath)
            }
            if let selectedKeystorePath {
                SelectedFileRow(label: "Keystore", path: selectedKeystorePath)
            }

            if selectedPropertiesPath != nil
                || (status.propertiesComplete && selectedKeystorePath != nil) {
                Button {
                    pendingAndroidImport = true
                } label: {
                    Label("Import & Link…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .help("Validate the selected signing pair, copy a private protected version into the vault, back up any current project pointer, and link the project.\nCommand: \(signingImportRequest.commandPreview)")
            }

            Text("FRK validates the selected properties and keystore together. Your source is never deleted, and passwords never appear in logs or process arguments.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func iosCard(_ status: IOSSetupStatus) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("iOS signing", systemImage: "apple.logo")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    StatusBadge(
                        text: status.signingReady ? "Ready" : "Needs attention",
                        isReady: status.signingReady
                    )
                }

                Divider()

                SetupCheckRow(
                    title: "Project identity",
                    detail: status.projectIdentityDetail ?? ("Bundle " + status.bundleId + " · Team " + status.teamId),
                    state: (status.projectIdentityReady ?? status.workspaceExists) ? .ready : .error
                )
                SetupCheckRow(
                    title: "Apple Distribution identity",
                    detail: status.distributionIdentityDetail ?? (status.distributionIdentityReady ? "Certificate and private key are available in Keychain" : "No usable distribution identity is installed"),
                    state: status.distributionIdentityReady ? .ready : .error
                )
                SetupCheckRow(
                    title: "Provisioning profile",
                    detail: status.profileDetail,
                    state: status.profileState
                )
                if let exportReady = status.exportOptionsReady {
                    SetupCheckRow(
                        title: "Export configuration",
                        detail: status.exportOptionsDetail ?? status.exportOptionsPath ?? "Export options could not be inspected",
                        state: exportReady ? .ready : .error
                    )
                }
                SetupCheckRow(
                    title: "App Store Connect access",
                    detail: status.ascCredentialsReady ? "API key is configured in the private vault" : "Required for automatic repair and TestFlight upload; not required for a local archive",
                    state: status.ascCredentialsReady ? .ready : .warning
                )

                if status.signingReady {
                    Text("The local signing chain is valid. App Store Connect access is checked separately because local signing and store automation are different concerns.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if status.projectIdentityReady == false || !status.workspaceExists {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open Xcode and correct Runner's Bundle Identifier and Team first. FRK will not guess or silently rewrite the app's identity.")
                            .font(.callout)
                        if status.workspaceExists {
                            Button("Open in Xcode") {
                                model.openXcode(for: project)
                            }
                            .help("Open Runner.xcworkspace (or Runner.xcodeproj) to correct the Bundle Identifier and Apple Team manually. FRK does not guess app identity.")
                        }
                    }
                } else if status.ascCredentialsReady {
                    HStack(spacing: 10) {
                        Button {
                            pendingIOSRepair = true
                        } label: {
                            Label("Repair Automatically…", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("After confirmation, repair ExportOptions, reuse or create Apple Distribution signing material, refresh this app's provisioning profile, and switch the Xcode project's Release configuration to sign with it. No build is uploaded, but Apple Developer account state and the Xcode project file may change; the previous project file is backed up first.\nCommand: \(FRKRunRequest(action: .iosSetupSigning, project: project.id).commandPreview)")

                        if status.workspaceExists {
                            Button("Open in Xcode") {
                                model.openXcode(for: project)
                            }
                            .help("Open the iOS workspace to inspect or repair signing manually. No project files are changed by opening Xcode.")
                        }
                    }
                    Text("Repair can update export settings, Xcode's Release signing configuration, certificates, and provisioning profiles. Existing project files are backed up. No build is uploaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add an App Store Connect API key with the App Manager role to enable automatic repair.")
                            .font(.callout)
                        HStack(spacing: 10) {
                            Button("Configure Credentials…") {
                                showStoreConnections = true
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Open Store credentials to add your App Store Connect API key. Credentials are shared across the managed projects on this Mac; setup will be checked again when you close it.")
                            Button("Open App Store Connect") {
                                openURL("https://appstoreconnect.apple.com/access/integrations/api")
                            }
                            .help("Open App Store Connect API integrations in the browser to create or inspect a Team API key. FRK cannot download an existing .p8 key again.")
                            if status.workspaceExists {
                                Button("Open in Xcode") {
                                    model.openXcode(for: project)
                                }
                                .help("Open the iOS workspace to inspect Bundle Identifier, Team, certificates, and provisioning manually.")
                            }
                        }
                    }
                }

                if !status.workspaceExists {
                    SetupCheckRow(
                        title: "Xcode project is missing",
                        detail: "Restore the ios directory or run Flutter's platform-generation command before signing.",
                        state: .error
                    )
                }
            }
        }
    }

    private var signingImportRequest: FRKRunRequest {
        FRKRunRequest(
            action: .signingImport,
            project: project.id,
            propertiesPath: selectedPropertiesPath,
            keystorePath: selectedKeystorePath,
            link: true
        )
    }

    private func chooseFile(title: String, extensions: [String]) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPath(_ value: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: value))
    }
}

private struct SelectedFileRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(Color.frkAccent)
            Text("\(label): \(URL(fileURLWithPath: path).lastPathComponent)")
                .font(.caption.weight(.medium))
            Spacer()
        }
        .padding(9)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .help("Selected source file: \(path)\nFRK preserves this source and copies only after validation and confirmation.")
    }
}
