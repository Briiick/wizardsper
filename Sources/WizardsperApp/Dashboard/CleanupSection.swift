import SwiftUI
import WizardsperKit

/// The cleanup control, and the honesty that has to come with it.
///
/// This is the only setting in Wizardsper that changes what the user said, so it is
/// the only one whose copy has to say so plainly rather than selling the
/// feature. It is off by default, the availability of the engine is reported
/// rather than assumed, and the last outcome is shown — a rewrite that quietly
/// declined to run is indistinguishable from one that is broken, and the user
/// deserves to know which they have.
struct CleanupSection: View {
    // Qualified: SwiftUI declares its own `Settings` scene type.
    @Bindable var settings: WizardsperKit.Settings
    let model: DashboardModel

    @State private var availability: TranscriptCleaner.Availability = .other("Checking…")
    /// Whether a key is in the keychain. The key itself is never held in view
    /// state once saved — only what the user is typing before they save it.
    @State private var hasAPIKey = false
    @State private var draftKey = ""
    @State private var keyError: String?

    private var engineIsReady: Bool {
        switch settings.cleanup.engine {
        case .onDevice: return availability.isReady
        case .claude: return hasAPIKey
        }
    }

    var body: some View {
        Section {
            // These two were a persisted, tested, `Codable` preference with no
            // way to reach them — the recogniser never terminates its last
            // sentence, so they are on for everyone, and until now nobody could
            // turn them off.
            Toggle("Finish the sentence", isOn: $settings.polish.addsTerminalPunctuation)
                .help(
                    "The recogniser punctuates mid-sentence but never ends one, because it only emits a final mark when it hears the next sentence begin."
                )
            Toggle("Capitalise the first word", isOn: $settings.polish.capitalisesFirstWord)
                .help("Left alone for words that are deliberately lowercase, like iPhone.")
        } header: {
            Text("Tidying")
        } footer: {
            Text("Two fixed corrections, applied to every transcript. No model involved.")
        }

        Section {
            Picker("Model", selection: $settings.cleanup.engine) {
                Text("Apple on-device").tag(CleanupEngine.onDevice)
                Text("Claude Haiku 5.5 (your API key)").tag(CleanupEngine.claude)
            }

            Toggle("Rewrite transcripts into written English", isOn: $settings.cleanup.enabled)
                .disabled(!engineIsReady && !settings.cleanup.enabled)

            switch settings.cleanup.engine {
            case .onDevice:
                LabeledContent("On-device model") {
                    status(ready: availability.isReady, text: availability.isReady ? "Ready" : availability.explanation)
                }
            case .claude:
                apiKeyControls
            }

            if settings.cleanup.engine == .onDevice, availability == .appleIntelligenceOff {
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

                // Replaced rather than greyed out while the rewrite always
                // finishes: a disabled slider reads as broken, when the truth is
                // that there is no deadline to set.
                LabeledContent("Give up after") {
                    if settings.cleanup.waitsForCompletion {
                        Text("Never — waits for the rewrite (\(CleanupPolicy.safetyCeiling.components.seconds) s limit)")
                            .foregroundStyle(.secondary)
                    } else {
                        Slider(value: $settings.cleanup.deadlineSeconds, in: 0.5...8, step: 0.25) {
                            Text("Give up after")
                        }
                        .frame(width: 180)
                        Text(String(format: "%.2fs", settings.cleanup.deadlineSeconds))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if let note = model.lastCleanupNote {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Clean-up")
        } footer: {
            Text(footer)
        }
        .task {
            availability = TranscriptCleaner.availability()
            hasAPIKey = AnthropicKeychain.hasKey
        }
    }

    private var footer: String {
        let guardrail =
            "It rewrites what you said, so it is checked against the original and discarded if it strays, answers you, or finishes a sentence you did not — and it never runs in Terminal, Xcode or a code editor, where text has to be verbatim."
        switch settings.cleanup.engine {
        case .onDevice:
            return
                "One pass over the finished transcript, using Apple's on-device model, after you release the key. Nothing leaves your Mac, and sampling is greedy, so the same words always produce the same result. "
                + guardrail
        case .claude:
            return
                "One pass over the finished transcript, using Claude Haiku 5.5, after you release the key and before it pastes. Your transcript is sent to Anthropic and billed to your API key — a fraction of a cent per dictation. Allow a couple of seconds before giving up: this is a network round trip. "
                + guardrail
        }
    }

    @ViewBuilder
    private var apiKeyControls: some View {
        if hasAPIKey {
            LabeledContent("Anthropic API key") {
                HStack(spacing: 8) {
                    status(ready: true, text: "Saved in your keychain")
                    Button("Remove") {
                        AnthropicKeychain.delete()
                        hasAPIKey = false
                        // A rewrite that can no longer run should not look switched on.
                        settings.cleanup.enabled = false
                    }
                }
            }
        } else {
            LabeledContent("Anthropic API key") {
                HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let keyError {
                Label(keyError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func saveKey() {
        guard AnthropicKeychain.save(draftKey) else {
            keyError = "Could not save the key to your keychain."
            return
        }
        draftKey = ""
        keyError = nil
        hasAPIKey = true
    }

    private func status(ready: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? Color.green : Color.orange)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
