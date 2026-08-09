import SwiftUI

extension Color {
    static let frkAccent = Color(red: 0.00, green: 0.48, blue: 0.48)
    static let frkSuccess = Color(red: 0.08, green: 0.55, blue: 0.29)
}

struct SectionCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
    }
}

struct StatusBadge: View {
    let text: String
    let isReady: Bool

    var body: some View {
        Label(text, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isReady ? Color.frkSuccess : Color.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((isReady ? Color.frkSuccess : Color.orange).opacity(0.11), in: Capsule())
    }
}

struct PlatformPill: View {
    let platform: PlatformKind

    var body: some View {
        Label(platform.title, systemImage: platform.systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

// Internal rather than private: the pure state builders on AndroidSetupStatus and
// IOSSetupStatus return it, so the model extensions have to see it too.
enum SetupCheckState {
    case ready
    case warning
    case error
}

struct SetupCheckRow: View {
    let title: String
    let detail: String
    let state: SetupCheckState

    private var icon: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .ready: .frkSuccess
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

struct EmptySelectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("No Project Selected", systemImage: "shippingbox")
        } description: {
            Text("Add a Flutter project or choose one from the sidebar.")
        } actions: {
            Button("Add Project…") {
                model.showAddProject = true
            }
            .buttonStyle(.borderedProminent)
            .help("Choose one Flutter project to add to FRK. No folders are scanned automatically.")
        }
    }
}
