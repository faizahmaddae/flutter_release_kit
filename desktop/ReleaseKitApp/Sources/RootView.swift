import AppKit
import SwiftUI

enum WorkspaceLayoutMode: Equatable {
    case focused
    case standard
    case expanded

    init(width: CGFloat) {
        if width < 900 {
            self = .focused
        } else if width < 1180 {
            self = .standard
        } else {
            self = .expanded
        }
    }
}

/// One visibility choice survives moving activity beside or below the project.
struct ActivityPresentationState {
    var layoutMode = WorkspaceLayoutMode.expanded
    var isVisible = false

    var showsSidebar: Bool { layoutMode == .expanded && isVisible }

    var showsCompactPanel: Bool { layoutMode != .expanded && isVisible }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var activityPresentation = ActivityPresentationState()

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 270)
        } detail: {
            GeometryReader { geometry in
                HSplitView {
                    VStack(spacing: 0) {
                        projectContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if activityPresentation.showsCompactPanel {
                            Divider()
                            ActivityPanel(onClose: { activityPresentation.isVisible = false })
                                .frame(height: min(300, geometry.size.height * 0.45))
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                    if activityPresentation.showsSidebar {
                        ActivityPanel(onClose: { activityPresentation.isVisible = false })
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(WindowWidthReader(onChange: updateLayout))
        .tint(.frkAccent)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.showAddProject = true
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Choose one Flutter project and add it to FRK's managed list. No other folders are scanned.")

                Button {
                    Task {
                        do {
                            try await model.reloadProjects()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isConnected || model.isLoading)
                .help("Reload managed projects, versions, signing readiness, credentials, and artifacts from the FRK CLI.")

                Button {
                    activityPresentation.isVisible.toggle()
                } label: {
                    Label("Activity", systemImage: model.isRunning ? "waveform.circle.fill" : "terminal")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Show or hide activity (⇧⌘L). Opens automatically when a job starts.")

                Button {
                    model.showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Manage store credentials, the FRK executable, compatibility, and the private vault.")
            }
        }
        .sheet(isPresented: $model.showAddProject) {
            AddProjectView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
                .frame(width: 700, height: 590)
        }
        .sheet(isPresented: $model.showCredentialOnboarding) {
            StoreConnectionsView(presentation: .firstRun)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showScreenshotStudio) {
            if let project = model.selectedProject {
                ScreenshotStudioView(project: project)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.showHelp) {
            HelpView()
        }
        .alert("Flutter Release Kit", isPresented: errorPresented) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .task {
            await model.bootstrap()
        }
        .onChange(of: model.activityRunID) {
            // A launch failure can set isRunning to true and back to false within
            // one UI update. The run ID remains observable even for that failure.
            activityPresentation.isVisible = true
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if let project = model.selectedProject {
            ProjectDetailView()
                .id(project.id)
        } else {
            EmptySelectionView()
        }
    }

    private func updateLayout(for width: CGFloat) {
        let nextMode = WorkspaceLayoutMode(width: width)
        guard nextMode != activityPresentation.layoutMode else { return }
        activityPresentation.layoutMode = nextMode
        if nextMode == .focused {
            columnVisibility = .detailOnly
        } else {
            columnVisibility = .all
        }
    }
}

private struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        context.coordinator.onChange = onChange
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.attach(to: view.window)
    }

    final class WindowTrackingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    final class Coordinator {
        var onChange: (CGFloat) -> Void
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            self.window = window
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.publishWidth()
            }
            publishWidth()
        }

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        private func publishWidth() {
            guard let window else { return }
            onChange(window.contentLayoutRect.width)
        }
    }
}
