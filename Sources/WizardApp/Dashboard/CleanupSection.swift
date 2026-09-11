import SwiftUI
import WizardKit

/// The cleanup control, and the honesty that has to come with it.
///
/// This is the only setting in Wizard that changes what the user said, so it is
/// the only one whose copy has to say so plainly rather than selling the
/// feature. It is off by default, the availability of the engine is reported
/// rather than assumed, and the last outcome is shown — a rewrite that quietly
/// declined to run is indistinguishable from one that is broken, and the user
/// deserves to know which they have.
struct CleanupSection: View {
    // Qualified: SwiftUI declares its own `Settings` scene type.
    @Bindable var settings: WizardKit.Settings
    let model: DashboardModel

    @State private var availability: TranscriptCleaner.Availability = .other("Checking…")

    var body: some View {
        Section {
            Toggle("Rewrite transcripts into written English", isOn: $settings.cleanup.enabled)
                .disabled(!availability.isReady)

            LabeledContent("On-device model") {
                HStack(spacing: 6) {
                    Image(systemName: availability.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(availability.isReady ? Color.green : Color.orange)
                    Text(availability.isReady ? "Ready" : availability.explanation)
                        .foregroundStyle(.secondary)
                }
            }

            if availability == .appleIntelligenceOff {
                Button("Open Apple Intelligence settings…") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?AppleIntelligence")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            if settings.cleanup.enabled {
                Toggle(
                    "Always finish the rewrite", isOn: $settings.cleanup.waitsForCompletion
                )
                .help(
                    "One pass, run to completion, after you release the key. The same dictation always produces the same result — but the paste waits for it."
                )

                LabeledContent("Give up after") {
                    Slider(value: $settings.cleanup.deadlineSeconds, in: 0.5...4, step: 0.25) {
                        Text("Give up after")
                    }
                    .frame(width: 180)
                    Text(String(format: "%.2fs", settings.cleanup.deadlineSeconds))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .disabled(settings.cleanup.waitsForCompletion)

                if let note = model.lastCleanupNote {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Clean-up")
        } footer: {
            Text(
                "One pass over the finished transcript, using Apple's on-device model, after you release the key. Nothing leaves your Mac, and sampling is greedy, so the same words always produce the same result. It rewrites what you said, so it is checked against the original and discarded if it strays, answers you, or finishes a sentence you did not — and it never runs in Terminal, Xcode or a code editor, where text has to be verbatim."
            )
        }
        .task {
            availability = TranscriptCleaner.availability()
        }
    }
}
