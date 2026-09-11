import AppKit
import SwiftUI
import WizardKit

/// The compact panel behind the menu bar icon: what the trigger is, whether the
/// model is ready, which permissions are still missing, and what was said last.
///
/// It reads an `AppStatusModel` and nothing else. In particular it never touches
/// the model installer or the permission probes directly — a popover that did
/// its own I/O would start work every time the user glanced at it, and would
/// disagree with the dashboard about what is true.
struct PopoverView: View {

    let status: AppStatusModel

    @State private var didCopy = false

    private let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hairline
            modelSection
            hairline
            permissionsSection
            if let transcript = status.lastTranscript, !transcript.isEmpty {
                hairline
                transcriptSection(transcript)
            }
            hairline
            footer
        }
        // Width is pinned so text wraps predictably; height is never constrained
        // — the hosting controller measures it and the popover follows.
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicator.color)
                    .frame(width: 7, height: 7)
                Text("Wizard")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(indicator.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Text("Hold")
                    .foregroundStyle(.secondary)
                ChordKeyCap(text: status.chord.display)
                Text("to dictate")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 13)
    }

    /// The dot and the word beside it. Listening outranks everything: it is the
    /// only state where the user is actively waiting on Wizard.
    private var indicator: (color: Color, label: String) {
        if status.isListening { return (.accentColor, "Listening") }
        if status.installProgress != nil { return (.orange, "Installing") }
        if status.isReady { return (.green, "Ready") }
        return (.orange, "Not ready")
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("Model")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.activeTier.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text("WER \(status.activeTier.reportedWER)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(status.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = status.installProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption("Permissions")

            ForEach(PermissionKind.allCases) { kind in
                permissionRow(kind)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// `PermissionKind` already carries the title and the one-line reason, so
    /// this row only decides how a shut gate looks and where "Grant" goes.
    private func permissionRow(_ kind: PermissionKind) -> some View {
        let granted = status.permissions[kind]
        return HStack(spacing: 9) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(granted ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 12))
                if !granted {
                    Text(kind.reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            if !granted {
                Button("Grant") { status.onRetryPermission(kind.rawValue) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Last transcript

    private func transcriptSection(_ transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption("Last transcript")
                Spacer(minLength: 8)
                Button {
                    copy(transcript)
                } label: {
                    Label(
                        didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "document.on.document"
                    )
                    .font(.system(size: 10.5))
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(didCopy ? Color.green : Color.accentColor)
            }

            Text(transcript)
                .font(.system(size: 12))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // Another process can own the pasteboard; saying "Copied" when
            // nothing was copied is worse than saying nothing.
            Log.ui.error("Pasteboard refused the transcript copied from the popover.")
            return
        }
        didCopy = true
        Task {
            // Cancellation only means the popover closed; nothing to undo.
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                status.onOpenDashboard()
            } label: {
                Label("Dashboard", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 8)

            Button {
                status.onQuit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var hairline: some View {
        Divider().opacity(0.7)
    }
}

/// A small upper-case caption. Repeated rather than shared with the dashboard so
/// each file in the app target can be read on its own.
private struct SectionCaption: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(.tertiary)
    }
}

/// The chord drawn as a key cap, so "⌥ ⌘" reads as something you hold rather
/// than as punctuation in a sentence.
struct ChordKeyCap: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}

/// Preview fixtures. `#Preview` bodies are `@ViewBuilder` closures, so the
/// several statements it takes to stage a model have to live in a function.
extension AppStatusModel {
    fileprivate static func previewReady() -> AppStatusModel {
        let status = AppStatusModel()
        status.isReady = true
        status.statusText = "Loaded and listening for the dictation key."
        status.activeTier = .ms560
        status.lastTranscript =
            "The encoder warms up on the first hold and stays resident after that."
        status.permissions = PermissionStatus(
            microphone: true, inputMonitoring: true, accessibility: true)
        return status
    }

    fileprivate static func previewInstalling() -> AppStatusModel {
        let status = AppStatusModel()
        status.statusText = "Downloading the 1120 ms model…"
        status.installProgress = 0.42
        status.activeTier = .ms1120
        status.chord = Chord([.option, .command])
        status.permissions = PermissionStatus(microphone: true)
        return status
    }
}

#Preview("Ready") {
    PopoverView(status: .previewReady())
}

#Preview("Installing, permissions missing") {
    PopoverView(status: .previewInstalling())
}
