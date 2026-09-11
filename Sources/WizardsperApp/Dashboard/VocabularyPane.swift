import SwiftUI
import WizardsperKit

/// Manage the words the recogniser gets wrong.
///
/// The list is small and hand-curated by definition, so this is a plain editable
/// table rather than anything cleverer. The part that needed design is the
/// *preview*: fuzzy correction is the one setting here that can quietly damage
/// transcripts that were already right, and a user has no way to predict what a
/// distance threshold will do to their vocabulary. So the pane carries a live
/// sandbox — type what the recogniser gave you, see what Wizardsper would write —
/// and it runs the real matcher, not an approximation of it.
struct VocabularyPane: View {
    // Qualified: SwiftUI declares its own `Settings` scene type.
    @Bindable var settings: WizardsperKit.Settings

    @State private var selection: VocabularyTerm.ID?
    @State private var trial = "I asked cloud about it"

    var body: some View {
        VSplitView {
            table
            editor
        }
        .navigationTitle("Vocabulary")
    }

    // MARK: - The list

    private var table: some View {
        VStack(spacing: 0) {
            Table(of: VocabularyTerm.self, selection: $selection) {
                TableColumn("Write") { term in
                    Text(term.replacement).fontWeight(.medium)
                }
                TableColumn("Also matches") { term in
                    Text(term.aliases.isEmpty ? "—" : term.aliases.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Sound-alikes") { term in
                    Image(systemName: term.isFuzzy ? "waveform" : "textformat.abc")
                        .foregroundStyle(term.isFuzzy ? FlowBarMetrics.tint : Color.secondary)
                        .help(
                            term.isFuzzy
                                ? "Also corrects words that sound like this one"
                                : "Only corrects the exact spellings listed")
                }
                .width(90)
            } rows: {
                ForEach(settings.vocabulary.terms) { TableRow($0) }
            }
            .frame(minHeight: 150)

            Divider()
            HStack(spacing: 6) {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a word")

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected word")

                Spacer()

                if settings.vocabulary.terms.isEmpty {
                    Text("Add a word the recogniser keeps getting wrong.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: - The selected term, and the sandbox

    @ViewBuilder
    private var editor: some View {
        Form {
            if let index = selectedIndex {
                Section("Word") {
                    TextField("Write", text: binding(index).replacement)
                    TextField(
                        "Also matches",
                        text: Binding(
                            get: { settings.vocabulary.terms[index].aliases.joined(separator: ", ") },
                            set: { raw in
                                settings.vocabulary.terms[index].aliases =
                                    raw.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            })
                    )
                    .help("Exact spellings, separated by commas. These always win.")
                    Toggle("Also correct words that sound like it", isOn: binding(index).isFuzzy)
                }
            }

            Section {
                Slider(
                    value: $settings.vocabulary.strictness, in: 0.2...0.6,
                    minimumValueLabel: Text("Exact").font(.caption),
                    maximumValueLabel: Text("Loose").font(.caption)
                ) {
                    Text("Sound-alike tolerance")
                }
            } header: {
                Text("Matching")
            } footer: {
                Text(
                    "A sound-alike is only corrected when it also has the same consonants, so raising this mostly admits longer mis-hearings rather than unrelated words. Raise it too far and ordinary words start being rewritten."
                )
            }

            Section {
                TextField("What the recogniser gave you", text: $trial, axis: .vertical)
                    .lineLimit(1...3)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                    Text(corrected.isEmpty ? " " : corrected)
                        .textSelection(.enabled)
                        .fontWeight(corrected == trial ? .regular : .semibold)
                        .foregroundStyle(corrected == trial ? Color.secondary : Color.primary)
                }
                if corrected == trial && !trial.isEmpty {
                    Text("No change — nothing here matched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Try it")
            } footer: {
                Text(
                    "This runs the same correction the transcript does, so what you see here is exactly what would be pasted."
                )
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260)
    }

    /// The real thing, not a reimplementation of it — a preview that could
    /// disagree with the pipeline would be worse than no preview.
    private var corrected: String { settings.vocabulary.apply(to: trial) }

    // MARK: - Mutating the list

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return settings.vocabulary.terms.firstIndex { $0.id == selection }
    }

    private func binding(_ index: Int) -> Binding<VocabularyTerm> {
        $settings.vocabulary.terms[index]
    }

    private func add() {
        let term = VocabularyTerm(replacement: "New word")
        settings.vocabulary.terms.append(term)
        selection = term.id
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        settings.vocabulary.terms.remove(at: index)
        selection = nil
    }
}

#if DEBUG
#Preview("Vocabulary") {
    VocabularyPane(settings: WizardsperKit.Settings(defaults: UserDefaults()))
        .frame(width: 640, height: 520)
}
#endif
