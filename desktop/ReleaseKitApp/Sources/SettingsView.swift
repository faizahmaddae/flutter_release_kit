import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showStoreConnections = false
    @State private var cliPathDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.frkAccent.gradient)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.title2.bold())
                    Text("Connections, CLI compatibility, and private storage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                Section("Release stores") {
                    storeRow(
                        title: "Google Play Console",
                        systemImage: "play.rectangle.fill",
                        isConnected: model.credentialsStatus?.googlePlay?.configured == true,
                        detail: model.credentialsStatus?.googlePlay?.clientEmail
                    )
                    storeRow(
                        title: "App Store Connect",
                        systemImage: "apple.logo",
                        isConnected: model.credentialsStatus?.appStoreConnect?.configured == true,
                        detail: model.credentialsStatus?.appStoreConnect?.keyId.map { "Key ID \($0)" }
                    )

                    HStack {
                        Text("Configure only the stores used on this Mac. Per-app access is checked before upload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Manage Credentials…") {
                            showStoreConnections = true
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Add or replace the shared Google Play service-account JSON and App Store Connect .p8 key stored in the private vault. Original source files are preserved.")
                    }
                }

                Section("CLI and private storage") {
                    LabeledContent("FRK executable") {
                        HStack {
                            TextField("/path/to/frk", text: $cliPathDraft)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .help("Executable used after Save & Reconnect. Cancel discards changes to this field.")
                            Button("Choose…") {
                                chooseCLI()
                            }
                            .help("Select an installed frk executable. The new path is used after Save & Reconnect.")
                        }
                    }

                    LabeledContent("Connection") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.isConnected ? Color.frkSuccess : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(model.connectionMessage)
                        }
                    }

                    if let capabilities = model.capabilities {
                        LabeledContent("Compatibility") {
                            Text("CLI \(capabilities.cliVersion) · API protocol \(capabilities.protocolVersion)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Private vault") {
                        Button("Reveal in Finder") {
                            model.revealVault()
                        }
                        .help("Open ~/.flutter-release in Finder. This private folder contains registry metadata, store credentials, and protected signing copies; do not publish it to Git.")
                    }

                    Label(
                        "The app asks FRK to validate and store credentials. It never reads secret contents or stores signing passwords.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cliPathDraft = model.cliPath
                    dismiss()
                }
                Button("Save & Reconnect") {
                    model.cliPath = cliPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.reconnect()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning || cliPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save the selected CLI path, reconnect, and reload capabilities, credentials, and managed projects. No build or upload runs.")
            }
            .padding(18)
        }
        .onAppear { cliPathDraft = model.cliPath }
        .background(SettingsWindowCloseObserver { cliPathDraft = model.cliPath })
        .sheet(isPresented: $showStoreConnections) {
            StoreConnectionsView(presentation: .settings)
                .environmentObject(model)
        }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the frk executable"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            cliPathDraft = url.path
        }
    }

    private func storeRow(
        title: String,
        systemImage: String,
        isConnected: Bool,
        detail: String?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(Color.frkAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(text: isConnected ? "Configured" : "Not configured", isReady: isConnected)
        }
        .help(isConnected
              ? "A credential is configured locally for this store. Per-app permissions are verified later by Doctor, Validate, or Release."
              : "No shared credential is configured for this store. Local builds still work, but its upload actions remain unavailable.")
    }
}

/// macOS retains the Settings scene when its window closes, so onAppear alone
/// cannot discard a draft when that same scene is reopened.
struct SettingsWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onClose: () -> Void = {}
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onClose() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
