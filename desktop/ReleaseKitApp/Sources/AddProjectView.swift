import AppKit
import SwiftUI

private enum PlatformChoice: String, CaseIterable, Identifiable {
    case automatic = "Auto-detect"
    case android = "Android only"
    case ios = "iOS only"
    case both = "Android + iOS"

    var id: String { rawValue }

    var cliValue: String? {
        switch self {
        case .automatic: nil
        case .android: "android"
        case .ios: "ios"
        case .both: "android,ios"
        }
    }
}

struct AddProjectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var projectPath = ""
    @State private var projectName = ""
    @State private var platformChoice = PlatformChoice.automatic
    @State private var track = "internal"
    @State private var androidPackage = ""
    @State private var iosBundleID = ""
    @State private var iosTeamID = ""
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Flutter project")
                        .font(.title2.bold())
                    Text("Only this project will be enrolled. Nothing else is scanned.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                LabeledContent("Project folder") {
                    HStack {
                        TextField("/path/to/flutter_app", text: $projectPath)
                            .textFieldStyle(.roundedBorder)
                            .help("The exact Flutter project folder FRK will inspect. No parent or sibling folders are scanned. Current path: \(projectPath.isEmpty ? "not selected" : projectPath)")
                        Button("Choose…", action: chooseProject)
                            .help("Choose one Flutter project directory. The folder is not copied or moved.")
                    }
                }

                LabeledContent("Display name") {
                    TextField("Optional", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .help("Friendly name shown in FRK. It does not rename the project folder, package ID, or bundle ID.")
                }

                Picker("Platforms", selection: $platformChoice) {
                    ForEach(PlatformChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .help("Choose which store platforms FRK should manage. Auto-detect reads the existing Android and iOS project files; it does not create a missing platform.")

                LabeledContent("Google Play track") {
                    Picker("", selection: $track) {
                        Text("Internal testing").tag("internal")
                        Text("Closed testing · alpha").tag("alpha")
                        Text("Open testing · beta").tag("beta")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .help("Default Google Play testing destination for this project. Production publishing is not available. Current choice: \(track)")
                }

                DisclosureGroup("Advanced identifier overrides", isExpanded: $showAdvanced) {
                    VStack(spacing: 10) {
                        LabeledContent("Android application ID") {
                            TextField("Auto-detect", text: $androidPackage)
                                .textFieldStyle(.roundedBorder)
                                .help("Override only when Gradle computes applicationId dynamically and FRK cannot detect it. This must match the existing Google Play app exactly.")
                        }
                        LabeledContent("iOS bundle ID") {
                            TextField("Auto-detect", text: $iosBundleID)
                                .textFieldStyle(.roundedBorder)
                                .help("Override only when Xcode detection is insufficient. This must match the existing App Store Connect record exactly.")
                        }
                        LabeledContent("Apple team ID") {
                            TextField("ABCDE12345", text: $iosTeamID)
                                .textFieldStyle(.roundedBorder)
                                .help("Your 10-character Apple Developer Team ID. This identifies the signing team; it is not an App Store Connect Key ID.")
                        }
                    }
                    .padding(.top, 8)
                }
                .help("Use identifier overrides only when automatic detection fails. Incorrect values can target the wrong store record.")

                Label(
                    "FRK stores project metadata in your local vault. Passwords and signing files stay outside the project.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Spacer()
                Button("Preview") {
                    submit(dryRun: true)
                }
                .disabled(!isValid || model.isRunning)
                .help("Inspect detection and show planned changes without writing project or registry files.\nCommand: \(onboardRequest(dryRun: true).commandPreview)")
                Button("Add Project") {
                    submit(dryRun: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || model.isRunning)
                .help("Register only this project and create the small FRK/Fastlane configuration needed for release management. Existing credentials and source code are preserved.\nCommand: \(onboardRequest(dryRun: false).commandPreview)")
            }
            .padding(18)
        }
        .frame(width: 650, height: 590)
    }

    private var isValid: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Flutter project"
        panel.prompt = "Choose Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
            if projectName.isEmpty {
                projectName = url.lastPathComponent
            }
        }
    }

    private func submit(dryRun: Bool) {
        model.start(onboardRequest(dryRun: dryRun))
        dismiss()
    }

    private func onboardRequest(dryRun: Bool) -> FRKRunRequest {
        FRKRunRequest(
            action: .onboard,
            project: projectPath,
            onboardName: projectName,
            onboardPlatforms: platformChoice.cliValue,
            androidPackage: androidPackage,
            iosBundleID: iosBundleID,
            iosTeamID: iosTeamID,
            track: track,
            dryRun: dryRun
        )
    }
}
