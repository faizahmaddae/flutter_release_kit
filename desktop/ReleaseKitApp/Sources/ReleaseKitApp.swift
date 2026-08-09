import SwiftUI

@main
struct ReleaseKitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Flutter Release Kit") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 560)
        }
        .defaultSize(width: 1_260, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Project…") {
                    model.showAddProject = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Open the guided form for adding one explicitly selected Flutter project.")

                Divider()

                Button("Refresh Projects") {
                    Task {
                        do {
                            try await model.reloadProjects()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload project versions, signing readiness, credentials, and artifacts from FRK.")
            }

            CommandMenu("Release") {
                Button("Cancel Current Job") {
                    model.cancelCurrentJob()
                }
                .disabled(!model.isRunning)
                .keyboardShortcut(".", modifiers: .command)
                .help("Request a safe stop for the running FRK command and its child processes.")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 700, height: 590)
        }
    }
}
