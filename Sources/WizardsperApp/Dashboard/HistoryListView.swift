import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WizardsperKit

/// One saved transcript, flattened for display.
///
/// The list renders this rather than `TranscriptionRecord` directly for one
/// reason: a `#Preview` has to be able to show a populated list, and the store
/// is a main-actor singleton backed by a real file. Rows built here can come
/// from either source.
private struct HistoryEntry: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let text: String
    /// `TranscriptionRecord.Outcome.pasted` or `.copied` — a bare string in the
    /// record so an unknown value from a newer build still decodes.
    let outcome: String
    let wordCount: Int
    let durationSeconds: Double

    init(
        id: UUID, date: Date, text: String, outcome: String, wordCount: Int,
        durationSeconds: Double
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.outcome = outcome
        self.wordCount = wordCount
        self.durationSeconds = durationSeconds
    }

    init(_ record: TranscriptionRecord) {
        self.init(
            id: record.id, date: record.date, text: record.text, outcome: record.outcome,
            wordCount: record.wordCount, durationSeconds: record.durationSeconds)
    }
}

private struct HistoryDay: Identifiable {
    /// Midnight of the day these entries fall in.
    let id: Date
    let entries: [HistoryEntry]
}

/// The dashboard's history pane: every transcript Wizardsper has kept, newest first.
///
/// Grouped by day rather than shown as one flat list because the useful question
/// is almost always "what did I dictate this morning", and forty rows carrying
/// only relative timestamps give no way to answer it.
struct HistoryListView: View {

    /// Non-nil only in previews, which cannot populate the on-disk store.
    private let sampleEntries: [HistoryEntry]?

    @State private var query = ""
    @State private var confirmingClear = false
    @State private var errorMessage: String?

    init() {
        self.sampleEntries = nil
    }

    fileprivate init(sampleEntries: [HistoryEntry]) {
        self.sampleEntries = sampleEntries
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let banner = bannerMessage {
                bannerRow(banner)
                Divider()
            }
            if days.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .confirmationDialog(
            "Delete every saved transcript?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the history file on disk too. It cannot be undone.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField
            Spacer(minLength: 8)
            Button {
                export()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help("Save the whole history as plain text — the search filter does not narrow it.")
            .disabled(allEntries.isEmpty)

            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(allEntries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// A hand-built field rather than `.searchable`, which would try to install
    /// itself in a window toolbar this window does not have.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.11))
        )
        .frame(maxWidth: 300)
    }

    /// A failed export is this view's own problem; a failed *save* is the
    /// store's, and it has nowhere else to say so — a history that has silently
    /// stopped being written is exactly the failure the user must be told about.
    private var bannerMessage: String? {
        if let errorMessage { return errorMessage }
        guard sampleEntries == nil else { return nil }
        return TranscriptionHistory.shared.lastWriteError.map {
            "History is not being saved: \($0)"
        }
    }

    private func bannerRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if errorMessage != nil {
                Button("Dismiss") { errorMessage = nil }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(days) { day in
                Section {
                    ForEach(day.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text(dayTitle(day.id))
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        // Named `mark`, not `badge`: a local called `badge` would shadow the
        // `badge(for:)` it is initialised from.
        let mark = badge(for: entry.outcome)
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: mark.symbol)
                .font(.system(size: 12))
                .foregroundStyle(mark.color)
                .frame(width: 15)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(relative(entry.date))
                    Text("·")
                    Text(entry.wordCount == 1 ? "1 word" : "\(entry.wordCount) words")
                    if entry.durationSeconds > 0 {
                        Text("·")
                        Text(String(format: "%.1f s", entry.durationSeconds))
                    }
                    Text("·")
                    Text(mark.label)
                        .foregroundStyle(mark.color)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button {
                    copy(entry)
                } label: {
                    Image(systemName: "document.on.document")
                }
                .help("Copy this transcript")

                Button {
                    delete(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this transcript")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: query.isEmpty ? "text.bubble" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No transcripts yet" : "No matches")
                .font(.system(size: 14, weight: .medium))
            Text(
                query.isEmpty
                    ? "Everything you dictate shows up here, newest first."
                    : "Nothing in the history contains “\(query)”."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Derived data

    private var allEntries: [HistoryEntry] {
        sampleEntries ?? TranscriptionHistory.shared.records.map { HistoryEntry($0) }
    }

    private var filtered: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allEntries }
        return allEntries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Newest day first, and newest entry first inside each day. The store
    /// already publishes newest-first; the sort here keeps the grouping honest
    /// if a back-dated record ever lands out of order.
    private var days: [HistoryDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return
            grouped
            .map { HistoryDay(id: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.id > $1.id }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric))
    }

    /// Matched on a prefix rather than switched exhaustively: `outcome` is a
    /// stored string precisely so a file written by another build still loads,
    /// and a value this build does not recognise is shown as-is instead of being
    /// mislabelled "pasted".
    private func badge(for outcome: String) -> (label: String, symbol: String, color: Color) {
        let value = outcome.lowercased()
        if value.hasPrefix("pasted") { return ("Pasted", "checkmark.circle.fill", .green) }
        if value.hasPrefix("copied") { return ("Copied", "document.on.document", .accentColor) }
        if value.hasPrefix("failed") { return ("Failed", "exclamationmark.circle.fill", .orange) }
        if value.isEmpty { return ("Saved", "circle", .secondary) }
        return (outcome, "circle", .secondary)
    }

    // MARK: - Actions

    private func copy(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(entry.text, forType: .string) else {
            // Another process can own the pasteboard. Saying nothing here would
            // leave the user believing they had copied something.
            Log.history.error("Pasteboard refused a transcript copied from the history list.")
            errorMessage = "Could not copy that transcript to the clipboard."
            return
        }
        errorMessage = nil
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Wizardsper Transcripts.txt"
        panel.message = "Save the transcription history as plain text."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The store owns the export format — it is the only thing that knows the
        // duration and tier that this view's rows do not carry.
        let text = TranscriptionHistory.shared.export()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            // The user picked this path, so a failure has to be visible;
            // quietly producing no file is the one outcome that must not happen.
            Log.history.error(
                "History export to \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "Could not write the export: \(error.localizedDescription)"
        }
    }

    private func delete(_ entry: HistoryEntry) {
        TranscriptionHistory.shared.delete(entry.id)
    }

    private func clearAll() {
        TranscriptionHistory.shared.clear()
    }
}

// MARK: - Previews

private func previewEntries() -> [HistoryEntry] {
    let now = Date()
    return [
        HistoryEntry(
            id: UUID(), date: now.addingTimeInterval(-240),
            text:
                "The encoder runs on the Neural Engine, so the first hold of a session is slower than every one after it.",
            outcome: "pasted", wordCount: 21, durationSeconds: 6.4),
        HistoryEntry(
            id: UUID(), date: now.addingTimeInterval(-3_400),
            text: "Remember to check whether the 160 ms tier still exists on the hub.",
            outcome: "copied", wordCount: 13, durationSeconds: 3.1),
        HistoryEntry(
            id: UUID(), date: now.addingTimeInterval(-92_000),
            text: "Draft the release notes before Thursday.",
            outcome: "pasted", wordCount: 6, durationSeconds: 1.8),
        HistoryEntry(
            id: UUID(), date: now.addingTimeInterval(-96_000),
            text: "Ask about the 2240 ms tier's word error rate regression.",
            outcome: "copied", wordCount: 10, durationSeconds: 2.6),
    ]
}

#Preview("Populated") {
    HistoryListView(sampleEntries: previewEntries())
        .frame(width: 640, height: 460)
}

#Preview("Empty") {
    HistoryListView(sampleEntries: [])
        .frame(width: 640, height: 460)
}
