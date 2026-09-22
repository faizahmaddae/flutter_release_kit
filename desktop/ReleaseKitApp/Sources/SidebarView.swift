import SwiftUI

enum ProjectBrowserFilter: String, CaseIterable, Identifiable {
    case all = "All projects"
    case needsSetup = "Needs setup"
    case android = "Android"
    case ios = "iOS"

    var id: String { rawValue }

    func includes(_ project: ProjectSummary, query: String) -> Bool {
        let matchesFilter: Bool
        switch self {
        case .all: matchesFilter = true
        case .needsSetup: matchesFilter = project.needsSetup
        case .android: matchesFilter = project.supports(.android)
        case .ios: matchesFilter = project.supports(.ios)
        }
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        let fields = [project.name, project.path, project.android?.packageId, project.ios?.bundleId].compactMap { $0 }
        return matchesFilter && terms.allSatisfy { term in
            fields.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var filter = ProjectBrowserFilter.all

    private var visibleProjects: [ProjectSummary] {
        model.projects.filter { filter.includes($0, query: query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search projects", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search projects")
                        .help("Search by project name, folder, or application ID.")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(8)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Picker("Filter projects", selection: $filter) {
                        ForEach(ProjectBrowserFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer(minLength: 2)
                    Text("\(visibleProjects.count) / \(model.projects.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(visibleProjects.count) of \(model.projects.count) projects")
                }
            }
            .padding(12)

            List(selection: $model.selectedProjectID) {
                ForEach(visibleProjects) { project in
                    ProjectSidebarRow(project: project)
                        .tag(project.id)
                }
            }
            .overlay {
                if model.isLoading {
                    ProgressView("Loading projects…")
                } else if model.projects.isEmpty, model.isConnected {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "shippingbox",
                        description: Text("Add a project to get started.")
                    )
                } else if visibleProjects.isEmpty, !model.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No matches", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different name or filter.")
                    } actions: {
                        Button("Reset Search") {
                            query = ""
                            filter = .all
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 9) {
                Image(systemName: model.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(model.isConnected ? Color.frkSuccess : Color.orange)
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
                .accessibilityLabel("Connection settings")
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
                Spacer(minLength: 4)
                Image(systemName: project.needsSetup ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(project.needsSetup ? Color.orange : Color.frkSuccess)
                    .accessibilityLabel(project.setupLabel)
            }

            HStack(spacing: 5) {
                ForEach(project.platforms) { platform in
                    Image(systemName: platform.systemImage)
                        .font(.caption2)
                        .accessibilityLabel(platform.title)
                }
                Text(project.version ?? "Version unavailable")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .help("\(project.name)\n\(project.path)\n\(project.setupLabel). Store access is checked separately.")
    }
}
