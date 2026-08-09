import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedProjectID) {
                Section("Managed projects") {
                    ForEach(model.projects) { project in
                        ProjectSidebarRow(project: project)
                            .tag(project.id)
                    }
                }
            }
            .overlay {
                if model.isLoading {
                    ProgressView("Loading projects…")
                } else if model.projects.isEmpty, model.isConnected {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "shippingbox",
                        description: Text("Add only the projects you want FRK to manage.")
                    )
                }
            }

            Divider()

            HStack(spacing: 9) {
                Circle()
                    .fill(model.isConnected ? Color.frkSuccess : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isConnected ? "CLI connected" : "CLI needs attention")
                        .font(.caption.weight(.semibold))
                    Text(model.connectionMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Connection settings")
            }
            .padding(12)
        }
        .navigationTitle("Release Kit")
    }
}

private struct ProjectSidebarRow: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(project.isReady ? Color.frkSuccess : Color.orange)
                    .frame(width: 7, height: 7)
            }

            HStack(spacing: 5) {
                ForEach(project.platforms) { platform in
                    Image(systemName: platform.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(project.version ?? "Version unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .help("\(project.name)\n\(project.path)\nStatus: \(project.isReady ? "ready" : "needs attention")")
    }
}
