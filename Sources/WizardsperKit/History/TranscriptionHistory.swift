import Foundation
import Observation

/// One finished dictation, as the history list shows it.
///
/// Everything here is stored rather than derived because the record has to
/// survive a build that changes its mind: `tierMilliseconds` and `outcome` are a
/// plain `Int` and `String`, not `NemotronTier` and `SessionOutcome`, so a file
/// written by a version that shipped a tier or an outcome this one no longer
/// knows about still decodes instead of failing the whole history.
public struct TranscriptionRecord: Codable, Sendable, Identifiable, Equatable {
    /// Persisted, not regenerated per load, so `delete(_:)` and SwiftUI list
    /// diffing keep pointing at the same row across a relaunch.
    public let id: UUID
    public let date: Date
    public let text: String
    /// Wall-clock length of the hold that produced `text`.
    public let durationSeconds: Double
    /// Chunk size of the tier that transcribed it, in milliseconds.
    public let tierMilliseconds: Int
    /// `Outcome.pasted` or `Outcome.copied`.
    public let outcome: String

    /// The only two values `outcome` is written with. `.nothing` and `.failed`
    /// sessions are never recorded — there is no transcript to remember.
    public enum Outcome {
        public static let pasted = "pasted"
        public static let copied = "copied"
    }

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        durationSeconds: Double,
        tierMilliseconds: Int,
        outcome: String
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.durationSeconds = durationSeconds
        self.tierMilliseconds = tierMilliseconds
        self.outcome = outcome
    }

    /// Fails for `.nothing` and `.failed`, which is what lets the coordinator
    /// hand every terminal outcome here and let the record decide.
    public init?(
        outcome: SessionOutcome,
        date: Date = Date(),
        durationSeconds: Double,
        tier: NemotronTier
    ) {
        switch outcome {
        case .pasted(let text):
            self.init(
                date: date, text: text, durationSeconds: durationSeconds,
                tierMilliseconds: tier.chunkMilliseconds, outcome: Outcome.pasted)
        case .copied(let text, _):
            self.init(
                date: date, text: text, durationSeconds: durationSeconds,
                tierMilliseconds: tier.chunkMilliseconds, outcome: Outcome.copied)
        case .nothing, .failed:
            return nil
        }
    }

    /// Runs of non-whitespace. Enough for “how much did I dictate today”; it is
    /// not a linguistic word count.
    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// `nil` when the file names a tier this build no longer ships.
    public var tier: NemotronTier? { NemotronTier(rawValue: tierMilliseconds) }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, durationSeconds, tierMilliseconds, outcome
    }

    /// Hand-written so a missing field costs one record's metadata rather than
    /// the entire file. Only `date` and `text` are load-bearing enough to throw.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        tierMilliseconds =
            try container.decodeIfPresent(Int.self, forKey: .tierMilliseconds)
            ?? NemotronTier.default.chunkMilliseconds
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome) ?? Outcome.copied
    }
}

/// The dictation log: what was said, when, and where it went.
///
/// The array is main-actor owned because the dashboard binds straight to it, but
/// every byte of disk work happens on `HistoryStore`, an actor. Two things make
/// that safe: each save carries an immutable snapshot of the whole array taken on
/// the main actor, and the saves are chained so they land in the order they were
/// requested. Without the chain, two dictations finished a moment apart could
/// have their writes reordered and the older snapshot would win, silently losing
/// the newer transcript.
///
/// Nothing here throws. A history that cannot be written must not take a
/// transcript down with it, so write failures are logged and surfaced on
/// `lastWriteError` for the UI instead of propagating into the dictation path.
@MainActor
@Observable
public final class TranscriptionHistory {
    public static let shared = TranscriptionHistory()

    /// Newest first — the order the list renders, and the order `retained`
    /// relies on when it trims the tail to the cap.
    public private(set) var records: [TranscriptionRecord] = []

    /// Set when a save fails, cleared by the next one that succeeds, so the
    /// settings pane can tell the user their history is not being kept rather
    /// than leaving the failure in the log only.
    public private(set) var lastWriteError: String?

    /// Every append rewrites the whole file atomically and the list view holds
    /// the whole array, so growth is not free even when the user asks for
    /// unlimited retention. 5000 records is years of ordinary use and still a
    /// file small enough to rewrite in a few milliseconds.
    public static let maximumRecords = 5000

    @ObservationIgnored private let store: HistoryStore
    /// Tail of the save chain. Each new save awaits it before starting.
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    public init(fileURL: URL = WizardsperPaths.historyFile) {
        self.store = HistoryStore(fileURL: fileURL)
    }

    /// Reads the file, applies retention, and publishes the result. Safe to call
    /// again later; a reload waits for any in-flight write so it cannot read the
    /// file from behind one.
    public func load() async {
        await flush()
        let stored = await store.load()
        let sorted = stored.sorted { $0.date > $1.date }
        let kept = Self.retained(sorted, retentionDays: Settings.shared.historyRetentionDays)
        records = kept
        // Persist the prune now rather than waiting for the next dictation, so a
        // user who opens the history sees on disk what they see on screen.
        if kept.count != sorted.count {
            Log.history.notice("pruned \(sorted.count - kept.count) expired record(s) on load")
            scheduleSave()
        }
    }

    /// Records one dictation. Does nothing when the user has history switched
    /// off — the transcript must not reach disk in that case.
    public func append(_ record: TranscriptionRecord) {
        guard Settings.shared.keepHistory else {
            Log.history.debug("history disabled; record not stored")
            return
        }
        // Keeps the newest-first invariant even if a caller back-dates a record.
        let index = records.firstIndex { $0.date <= record.date } ?? records.count
        records.insert(record, at: index)
        records = Self.retained(records, retentionDays: Settings.shared.historyRetentionDays)
        scheduleSave()
    }

    public func delete(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        scheduleSave()
    }

    /// Always writes, even when `records` is already empty: the file may hold
    /// transcripts this instance never loaded, and "clear history" has to mean
    /// the disk too.
    public func clear() {
        records.removeAll()
        scheduleSave()
    }

    /// Drops anything older than `retentionDays`. `0` means keep forever — the
    /// 5000-record cap still applies.
    public func prune(retentionDays: Int) {
        let kept = Self.retained(records, retentionDays: retentionDays)
        guard kept.count != records.count else { return }
        Log.history.notice("pruned \(self.records.count - kept.count) record(s)")
        records = kept
        scheduleSave()
    }

    /// Plain text, for the clipboard or a file the user picks.
    public func export() -> String {
        let stamp = DateFormatter()
        stamp.locale = .autoupdatingCurrent
        stamp.dateStyle = .medium
        stamp.timeStyle = .short

        var lines: [String] = ["Wizardsper transcription history"]
        let count = records.count
        lines.append(
            "\(count) transcription\(count == 1 ? "" : "s") · "
                + "exported \(stamp.string(from: Date()))")
        for record in records {
            lines.append("")
            lines.append("----")
            let words = record.wordCount
            lines.append(
                "\(stamp.string(from: record.date)) · "
                    + String(format: "%.1f s", record.durationSeconds)
                    + " · \(record.tierMilliseconds) ms · \(record.outcome) · "
                    + "\(words) word\(words == 1 ? "" : "s")")
            lines.append(record.text)
        }
        return lines.joined(separator: "\n")
    }

    /// Waits for pending writes. Call before the app terminates, or a dictation
    /// finished a moment earlier may never reach disk.
    ///
    /// Awaiting the tail once is not enough: a dictation that resumes on the
    /// main actor while this is suspended chains a *new* save behind the one
    /// being awaited, and returning then would drop exactly the transcript the
    /// caller is flushing for. The loop ends as soon as no further save was
    /// queued behind the one just finished.
    public func flush() async {
        while let pending = writeTask {
            await pending.value
            if writeTask == pending { break }
        }
    }

    /// Chains one save behind the last, so a burst of appends is written in the
    /// order it happened. The snapshot is taken here, on the main actor, while
    /// the encode and the write happen inside the store actor.
    private func scheduleSave() {
        let snapshot = records
        let previous = writeTask
        let store = self.store
        writeTask = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await store.save(snapshot)
                self?.lastWriteError = nil
            } catch {
                // Nothing upstream can act on this — the dictation is already
                // pasted — so it is logged and published rather than thrown.
                let message = error.localizedDescription
                Log.history.error("could not write history: \(message, privacy: .public)")
                self?.lastWriteError = message
            }
        }
    }

    /// Applies retention and the hard cap. `records` must already be newest
    /// first: the cap trims from the end.
    private static func retained(
        _ records: [TranscriptionRecord], retentionDays: Int, now: Date = Date()
    ) -> [TranscriptionRecord] {
        var kept = records
        if retentionDays > 0 {
            // Calendar arithmetic rather than `days * 86_400` so a DST change
            // does not move the cutoff by an hour.
            let cutoff =
                Calendar.current.date(byAdding: .day, value: -retentionDays, to: now)
                ?? now.addingTimeInterval(-Double(retentionDays) * 86_400)
            kept.removeAll { $0.date < cutoff }
        }
        if kept.count > maximumRecords {
            kept.removeLast(kept.count - maximumRecords)
        }
        return kept
    }
}

/// On-disk format version, kept out of `TranscriptionHistory` so the store actor
/// can read it without hopping to the main actor.
///
/// Bumped only when the file's shape changes in a way `TranscriptionRecord`
/// cannot absorb on its own; `HistoryStore.migrate` is where the upgrade goes.
private enum HistoryFormat {
    static let version = 1
}

/// Raised when writing would destroy transcripts that exist nowhere else.
/// `LocalizedError` because the message ends up on `lastWriteError`, in front of
/// the user, and "The operation couldn't be completed" would not tell them their
/// history is sitting in a file the app cannot open.
private enum HistoryStoreError: LocalizedError {
    case unpreservedHistory(URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .unpreservedHistory(let url, let reason):
            "History was not saved: \(url.lastPathComponent) could not be read or moved aside "
                + "(\(reason)), and overwriting it would destroy the transcripts it holds."
        }
    }
}

/// All disk access for the history, isolated so the main actor never encodes or
/// writes, and so writes cannot run concurrently with each other or with a load.
private actor HistoryStore {
    /// The file is a versioned envelope rather than a bare array precisely so a
    /// future format change has somewhere to say which format it is, and can
    /// migrate the user's history instead of discarding it.
    private struct Envelope: Codable {
        var version: Int
        var records: [TranscriptionRecord]
    }

    private let fileURL: URL

    /// Why the file on disk is both unreadable and still sitting there, or `nil`
    /// when writing is safe. Every save rewrites the whole file, so while this is
    /// set the next dictation would replace transcripts nothing else has a copy
    /// of with a one-record history. `save` refuses instead.
    private var unpreservedReason: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Never throws: a history that cannot be read is recovered from, not
    /// reported. An undecodable file is moved aside first, so the user's
    /// transcripts still exist on disk even though this build cannot read them.
    /// When it cannot be moved either, `save` is blocked instead — recovering
    /// from an unreadable file must never mean writing over it.
    func load() -> [TranscriptionRecord] {
        // Whatever was blocking writes, this read decides it afresh: a file that
        // opens now is a file whose contents are back in memory and therefore
        // safe to rewrite.
        unpreservedReason = nil

        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // The file exists but will not open — a permissions or hardware
            // problem, not a format one, so it is left exactly where it is
            // rather than quarantined over what may be a passing failure. It is
            // also the only copy of those transcripts, so writing is blocked
            // until a save can move it aside.
            Log.history.error(
                "could not read history file: \(error.localizedDescription, privacy: .public)")
            unpreservedReason = error.localizedDescription
            return []
        }

        let decoder = Self.makeDecoder()
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            return migrate(envelope)
        } catch {
            // A file written before the envelope existed, or hand-edited down to
            // a bare array. Worth one more attempt before quarantining it.
            if let records = try? decoder.decode([TranscriptionRecord].self, from: data) {
                Log.history.notice(
                    "history file has no version envelope; adopting \(records.count) record(s)")
                return records
            }
            Log.history.error(
                "history file could not be decoded: \(error.localizedDescription, privacy: .public)")
            do {
                try quarantine()
            } catch {
                // The undecodable file is still on disk. Letting the next
                // dictation write over it would turn "this build cannot read
                // your history" into "your history is gone".
                Log.history.error(
                    "could not move unreadable history aside: \(error.localizedDescription, privacy: .public)"
                )
                unpreservedReason = error.localizedDescription
            }
            return []
        }
    }

    func save(_ records: [TranscriptionRecord]) throws {
        if unpreservedReason != nil {
            // One more attempt before giving up on the write: the collision or
            // the permission problem that defeated the move may have cleared,
            // and preserving the old file is what makes this write safe.
            do {
                try quarantine()
                unpreservedReason = nil
            } catch {
                unpreservedReason = error.localizedDescription
                throw HistoryStoreError.unpreservedHistory(
                    fileURL, reason: error.localizedDescription)
            }
        }

        try WizardsperPaths.ensureApplicationSupport()
        // The default file lives in Application Support/Wizardsper, but a test may
        // hand this actor a URL somewhere else entirely.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let envelope = Envelope(version: HistoryFormat.version, records: records)
        let data = try Self.makeEncoder().encode(envelope)
        // Atomic: a crash mid-write leaves the previous history intact rather
        // than a truncated file that the next launch would quarantine.
        try data.write(to: fileURL, options: .atomic)
    }

    /// Where an older on-disk format would be upgraded. Version 1 is the first,
    /// so there is nothing to do yet.
    private func migrate(_ envelope: Envelope) -> [TranscriptionRecord] {
        if envelope.version > HistoryFormat.version {
            // A newer build wrote this. The records decoded, so they are usable,
            // but saving will rewrite the file in this build's older shape and
            // drop anything the newer one added.
            Log.history.error(
                "history file is version \(envelope.version), newer than \(HistoryFormat.version); fields this build does not know will be lost on the next save"
            )
        }
        return envelope.records
    }

    /// Moves an unreadable file out of the way so the app can start fresh
    /// without destroying whatever the user actually said. Throws when the file
    /// is still sitting at `fileURL` afterwards, which is the caller's signal
    /// that writing there would destroy it.
    private func quarantine() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return  // Already gone — nothing left to preserve, nothing to lose.
        }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"

        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let prefix = "\(base).corrupt-\(stamp.string(from: Date()))"

        // Two quarantines in the same second must not collide, or the second
        // move fails and the file it was protecting gets overwritten.
        var destination = directory.appendingPathComponent("\(prefix).\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)),
            suffix < 100
        {
            destination = directory.appendingPathComponent("\(prefix)-\(suffix).\(ext)")
            suffix += 1
        }

        try FileManager.default.moveItem(at: fileURL, to: destination)
        Log.history.notice(
            "moved unreadable history aside to \(destination.lastPathComponent, privacy: .public)"
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Pretty and key-sorted because this file is plain text in the user's
        // own Application Support folder and they may well open it.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // `Date.ISO8601FormatStyle` is a Sendable value, unlike a formatter, so
        // it can be captured by the @Sendable strategy closure. Fractional
        // seconds are kept so two dictations in the same second still sort.
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(style.format(date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { source in
            let text = try source.singleValueContainer().decode(String.self)
            if let date = try? fractional.parse(text) { return date }
            // Whole-second ISO-8601, as JSONEncoder's own `.iso8601` strategy
            // and most hand-written timestamps produce.
            return try whole.parse(text)
        }
        return decoder
    }
}
