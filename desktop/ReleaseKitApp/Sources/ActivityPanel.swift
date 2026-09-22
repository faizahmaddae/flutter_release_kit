import AppKit
import SwiftUI

struct ActivityPanel: View {
    @EnvironmentObject private var model: AppModel
    var onClose: (() -> Void)? = nil
    @State private var followsOutput = true
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()

                if !model.activity.isEmpty {
                    Button {
                        copyActivityToPasteboard()
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                    .help("Copy the full activity log to the clipboard, including any stack trace.")
                }

                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel", role: .destructive) {
                        model.cancelCurrentJob()
                    }
                    .controlSize(.small)
                    .help("Request a safe stop for the running FRK command and its child process. Completed file or store operations cannot be rolled back automatically.")
                } else if !model.activity.isEmpty {
                    Button("Clear") {
                        model.clearActivity()
                    }
                    .controlSize(.small)
                    .help("Clear only the visible activity history. Project files, artifacts, and store releases are not changed.")
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide activity")
                    .help("Hide this panel. Running jobs continue.")
                }
            }
            .padding(14)

            if let context = model.activityContext, !context.isEmpty {
                Text(context)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Divider()

            if let errorLine = model.lastActivityErrorLine {
                errorBanner(errorLine)
                Divider()
            }

            if model.activity.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Ready")
                        .font(.headline)
                    Text("Build and release output appears here in real time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Text("\(model.activity.count) lines")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Follow output", isOn: $followsOutput)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Turn off to read earlier output without jumping to new lines.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                ActivityLog(lines: model.activity, followsOutput: followsOutput)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        .onChange(of: model.activity.last?.id) { didCopy = false }
        .onChange(of: model.activityRunID) { followsOutput = true }
    }

    /// fastlane's own message, pulled out of the scrolling log so the auto-scroll that
    /// follows a live-streaming stack trace cannot carry it out of view. Stays up until
    /// the next run starts or the log is cleared, so there's no race with the log
    /// settling.
    private func errorBanner(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(width: 13)
            Text(Self.displayText(for: line))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
    }

    /// fastlane's "[!] " marker sits at the start of the line for a plain `user_error!`
    /// but mid-line for an unhandled crash, glued onto Ruby's own `path:line:in
    /// 'method': ` prefix — the marker's position is the only reliable signal, so this
    /// keeps everything from the marker onward and drops whatever came before it rather
    /// than guessing at a fixed prefix shape.
    static func displayText(for line: String) -> String {
        guard let marker = line.range(of: "[!] ") else { return line }
        return String(line[marker.upperBound...])
    }

    private func copyActivityToPasteboard() {
        let text = model.activity.map(\.message).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var statusText: String {
        if model.isRunning { return model.runningTitle ?? "Working…" }
        switch model.lastRunOutcome {
        case .success: return "Last job completed"
        case .failure: return "Last job failed"
        case .cancelled: return "Last job cancelled"
        case nil: return "No job running"
        }
    }

    private var statusColor: Color {
        if model.isRunning { return .frkAccent }
        switch model.lastRunOutcome {
        case .success: return .frkSuccess
        case .failure: return .red
        case .cancelled: return .secondary
        case nil: return .secondary
        }
    }
}

private struct ActivityLog: View {
    let lines: [ActivityLine]
    let followsOutput: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: icon(for: line.kind))
                                .foregroundStyle(color(for: line.kind))
                                .frame(width: 13)
                            Text(line.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: lines.last?.id, initial: true) {
                guard followsOutput, let last = lines.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onChange(of: followsOutput) {
                guard followsOutput, let last = lines.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func icon(for kind: ActivityLine.Kind) -> String {
        switch kind {
        case .info: "chevron.right"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for kind: ActivityLine.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .success: .frkSuccess
        case .error: .red
        }
    }
}
