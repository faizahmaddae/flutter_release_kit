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
