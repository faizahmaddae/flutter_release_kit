import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    releaseStepsCard
                    checksCard
                    otherFeaturesCard
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Flutter Release Kit Help")
                .font(.title2.bold())
            Text("What each button does, and which one you actually need.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private var releaseStepsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Getting a release to testers")
                    .font(.headline)

                helpRow(
                    icon: "hammer",
                    title: "Build",
                    detail: "Compiles the app and produces the file — a signed .aab for Android, an archive and exported .ipa for iOS — right here on this Mac. Nothing leaves this computer."
                )
                helpRow(
                    icon: "checkmark.shield",
                    title: "Validate (Android only)",
                    detail: "Sends that build to Google Play to check it would be accepted — signing, version number, track — without actually publishing it. Apple has no equivalent check, so there is no Validate button under iOS."
                )
                helpRow(
                    icon: "arrow.up.circle.fill",
                    title: "Upload",
                    detail: "Builds fresh and publishes it to your testers in one step. For Android, that's whichever Play track this project was set up with — internal, closed, or open testing, shown above as \"Play track\"; for iOS it's always TestFlight. A confirmation appears first."
                )

                Text("Upload is the only button you actually need — it builds for you. Build and Validate exist for when you want to check something first without shipping it.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var checksCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Doctor and Verify")
                    .font(.headline)

                helpRow(
                    icon: "stethoscope",
                    title: "Doctor",
                    detail: "Checks configuration, credentials, signing, and store readiness. Nothing is built or uploaded."
                )
                helpRow(
                    icon: "checkmark.circle",
                    title: "Verify",
                    detail: "Runs Flutter's analyzer and the project's tests. Nothing is uploaded."
                )
            }
        }
    }

    private var otherFeaturesCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Everything else, in short")
                    .font(.headline)

                helpBullet("**Signing ready / Needs setup** — whether this Mac can sign a release for that platform right now. \"Fix Setup\" opens a guided repair; nothing is uploaded by it.")
                helpBullet("**Screenshot Studio** — capture or import a screen, add a phone frame, export a PNG. Fully local; nothing is uploaded automatically.")
                helpBullet("**Extra build flags** — `--dart-define` and similar, appended to every build. Shared flags apply to both platforms; each platform can also have its own.")
                helpBullet("**Different per platform** (version) — most releases ship one marketing version everywhere; turn this on only when one store needs a different one, such as a single-store hotfix.")

                Divider()

                Text("Flutter Release Kit never publishes to a production listing — only Google Play's testing track and TestFlight. Promoting a build to the public store is a manual step you take in that store's own console.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func helpRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.frkAccent)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func helpBullet(_ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(.init(markdown))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
