import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum StoreConnectionsPresentation: Equatable {
    case firstRun
    case settings
}

struct StoreConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let presentation: StoreConnectionsPresentation

    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var appStoreKeyURL: URL?
    @State private var activeStore: StoreKind?
    @State private var errorMessage: String?
    @State private var confirmLocalOnly = false

    private enum StoreKind: Equatable {
        case googlePlay
        case appStore
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    googlePlayCard
                    appStoreCard
                    securityNote
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 590, idealHeight: 680)
        .interactiveDismissDisabled(presentation == .firstRun)
        .task {
            do {
                try await model.loadCredentialStatus(presentFirstRunIfNeeded: false)
                hydrateAppStoreFields()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: model.credentialsStatus) { _, _ in
            hydrateAppStoreFields()
        }
        .alert("Store connection", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Continue without a store connection?",
            isPresented: $confirmLocalOnly
        ) {
            Button("Use local builds only") {
                model.finishCredentialOnboarding(localBuildsOnly: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can build locally, but Play and TestFlight uploads remain unavailable until their store is connected in Settings.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.frkAccent.gradient)
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation == .firstRun ? "Configure a release store" : "Store credentials")
                    .font(.title2.bold())
                Text(presentation == .firstRun
                     ? "Configure Google Play, App Store Connect, or explicitly choose local builds for now."
                     : "Credentials are shared safely across your managed projects on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var googlePlayCard: some View {
        connectionCard(
            icon: "play.rectangle.fill",
            title: "Google Play Console",
            subtitle: "Service-account JSON for Play Internal and testing tracks",
            isConnected: model.credentialsStatus?.googlePlay?.configured == true
        ) {
            if let status = model.credentialsStatus?.googlePlay {
                connectionDetail(
                    status.configured ? (status.clientEmail ?? "Service account connected") : status.detail,
                    secondary: status.configured ? status.projectId : nil,
                    isReady: status.configured
                )
            }

            HStack {
                Button {
                    guard let file = chooseFile(
                        title: "Choose a Google Play service-account JSON",
                        contentType: .json
                    ) else { return }
                    activeStore = .googlePlay
                    Task {
                        defer { activeStore = nil }
                        do {
                            try await model.configureGooglePlay(file: file)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label(
                        model.credentialsStatus?.googlePlay?.configured == true ? "Replace JSON…" : "Choose JSON…",
                        systemImage: "doc.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeStore != nil)
                .help("Choose a Google service-account JSON. FRK validates it, preserves the source, copies a private version into the vault, and updates credentials.env. This does not grant Play Console permissions by itself.\nCommand: \(googlePlayConfigurationCommand)")

                if activeStore == .googlePlay {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private var appStoreCard: some View {
        connectionCard(
            icon: "apple.logo",
            title: "App Store Connect",
            subtitle: "Team API key for TestFlight and automatic signing repair",
            isConnected: model.credentialsStatus?.appStoreConnect?.configured == true
        ) {
            if let status = model.credentialsStatus?.appStoreConnect {
                connectionDetail(
                    status.configured ? "API key \(status.keyId ?? "") is connected" : status.detail,
                    secondary: nil,
                    isReady: status.configured
                )
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Key ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("10-character Key ID", text: $keyID)
                        .textFieldStyle(.roundedBorder)
                        .help("The 10-character Key ID shown in App Store Connect for this .p8 API key. This is not your Apple Team ID.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Issuer ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $issuerID)
                        .textFieldStyle(.roundedBorder)
                        .help("The App Store Connect Issuer ID UUID from Users and Access → Integrations. It identifies the API issuer and is stored in credentials.env.")
                }
                .frame(minWidth: 300)
            }

            HStack(spacing: 10) {
                Button {
                    appStoreKeyURL = chooseFile(
                        title: "Choose the App Store Connect API key",
                        contentType: UTType(filenameExtension: "p8") ?? .data
                    )
                } label: {
                    Label(appStoreKeyURL == nil ? "Choose .p8…" : "Change .p8…", systemImage: "key.fill")
                }
                .help("Choose the App Store Connect private API key downloaded from Apple. FRK validates and copies it privately; the original file is preserved.")

                if let appStoreKeyURL {
                    Text(appStoreKeyURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if activeStore == .appStore {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(model.credentialsStatus?.appStoreConnect?.configured == true ? "Update connection" : "Connect") {
                    guard let appStoreKeyURL else { return }
                    activeStore = .appStore
                    Task {
                        defer { activeStore = nil }
                        do {
                            try await model.configureAppStore(
                                file: appStoreKeyURL,
                                keyID: keyID,
                                issuerID: issuerID
                            )
                            self.appStoreKeyURL = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    activeStore != nil
                    || appStoreKeyURL == nil
                    || keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || issuerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Validate the Key ID, Issuer ID, and selected .p8 file, then store a private managed copy for TestFlight automation. No app build is uploaded.\nCommand: \(appStoreConfigurationCommand)")
            }
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.frkSuccess)
            Text("FRK validates the selected file, preserves your original, and stores a private copy in ~/.flutter-release with owner-only permissions. Per-app store access is verified later by Doctor or release checks; secret contents never appear in the interface or logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack {
            if presentation == .firstRun {
                Button("Use local builds for now") {
                    confirmLocalOnly = true
                }
                .foregroundStyle(.secondary)
                .help("Finish first-run setup without store credentials. Local builds stay available; Play and TestFlight actions remain disabled until configured in Settings.")
                Spacer()
                Button("Continue") {
                    model.finishCredentialOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.credentialsStatus?.hasConfiguredStore != true)
                .help("Finish setup after at least one store credential has been configured. The other store can be added later in Settings.")
            } else {
                Spacer()
                Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }

    private func connectionCard<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        isConnected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(Color.frkAccent)
                        .background(Color.frkAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(text: isConnected ? "Configured" : "Not configured", isReady: isConnected)
                        .help(isConnected
                              ? "Credential structure and private storage are valid. Per-app remote permissions are checked during Doctor or release."
                              : "This store has no valid shared credential on this Mac.")
                }
                Divider()
                content()
            }
        }
    }

    private func connectionDetail(_ primary: String, secondary: String?, isReady: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? Color.frkSuccess : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.callout)
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseFile(title: String, contentType: UTType) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [contentType]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func hydrateAppStoreFields() {
        guard let status = model.credentialsStatus?.appStoreConnect else { return }
        if keyID.isEmpty { keyID = status.keyId ?? "" }
        if issuerID.isEmpty { issuerID = status.issuerId ?? "" }
    }

    private var googlePlayConfigurationCommand: String {
        CommandPreview.frk([
            "api", "configure-credentials", "google-play",
            "--file", "/path/to/service-account.json", "--force",
        ])
    }

    private var appStoreConfigurationCommand: String {
        CommandPreview.frk([
            "api", "configure-credentials", "app-store",
            "--file", appStoreKeyURL?.path ?? "/path/to/AuthKey.p8",
            "--key-id", keyID.isEmpty ? "KEY_ID" : keyID,
            "--issuer-id", issuerID.isEmpty ? "ISSUER_ID" : issuerID,
            "--force",
        ])
    }
}
