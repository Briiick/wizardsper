import Foundation
import Testing

@testable import WizardKit

/// `TranscriptionHistory` consults `Settings.shared` for retention and for
/// whether to store at all, so these tests set those two values and put them
/// back. Serialised because they share that global.
@MainActor
private func withSettings<T>(
    keepHistory: Bool = true, retentionDays: Int = 7, _ body: () async throws -> T
) async rethrows -> T {
    let settings = Settings.shared
    let previousKeep = settings.keepHistory
    let previousDays = settings.historyRetentionDays
    settings.keepHistory = keepHistory
    settings.historyRetentionDays = retentionDays
    defer {
        settings.keepHistory = previousKeep
        settings.historyRetentionDays = previousDays
    }
    return try await body()
}

@MainActor
private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wizard-history-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("transcription history.json")
}

private func record(_ text: String, daysAgo: Double = 0, outcome: String = "pasted")
    -> TranscriptionRecord
{
    TranscriptionRecord(
        date: Date().addingTimeInterval(-daysAgo * 86_400),
        text: text, durationSeconds: 1.5, tierMilliseconds: 560, outcome: outcome)
}

@Suite("History", .serialized)
struct TranscriptionHistoryTests {

    @MainActor
    @Test("records survive a round trip to disk")
    func persists() async throws {
        let file = temporaryFile()
        try await withSettings {
            let history = TranscriptionHistory(fileURL: file)
            await history.load()
            history.append(record("hello world"))
            await history.load()  // flushes the pending write, then re-reads

            let reopened = TranscriptionHistory(fileURL: file)
            await reopened.load()
            #expect(reopened.records.count == 1)
            #expect(reopened.records.first?.text == "hello world")
            #expect(reopened.records.first?.tierMilliseconds == 560)
        }
    }

    @MainActor
    @Test("newest first, regardless of the order records arrive in")
    func ordersNewestFirst() async throws {
        try await withSettings(retentionDays: 0) {
            let history = TranscriptionHistory(fileURL: temporaryFile())
            await history.load()
            history.append(record("older", daysAgo: 2))
            history.append(record("newest", daysAgo: 0))
            history.append(record("middle", daysAgo: 1))
            #expect(history.records.map(\.text) == ["newest", "middle", "older"])
        }
    }

    /// The default is seven days. Anything past it must not survive a load, or
    /// the user's "keep for a week" setting quietly means "keep forever".
    @MainActor
    @Test("retention drops records past the window")
    func prunesOld() async throws {
        try await withSettings(retentionDays: 7) {
            let history = TranscriptionHistory(fileURL: temporaryFile())
            await history.load()
            history.append(record("fresh", daysAgo: 1))
            history.append(record("stale", daysAgo: 30))
            #expect(history.records.map(\.text) == ["fresh"])
        }
    }

    @MainActor
    @Test("a retention of zero keeps everything")
    func zeroMeansForever() async throws {
        try await withSettings(retentionDays: 0) {
            let history = TranscriptionHistory(fileURL: temporaryFile())
            await history.load()
            history.append(record("ancient", daysAgo: 4000))
            #expect(history.records.count == 1)
        }
    }

    @MainActor
    @Test("lowering the retention window prunes immediately")
    func pruneOnDemand() async throws {
        try await withSettings(retentionDays: 0) {
            let history = TranscriptionHistory(fileURL: temporaryFile())
            await history.load()
            history.append(record("old", daysAgo: 10))
            history.append(record("new", daysAgo: 0))
            #expect(history.records.count == 2)
            history.prune(retentionDays: 7)
            #expect(history.records.map(\.text) == ["new"])
        }
    }

    /// Switching history off has to mean the transcript never reaches disk, not
    /// merely that the list is hidden.
    @MainActor
    @Test("nothing is stored while history is switched off")
    func respectsTheOffSwitch() async throws {
        let file = temporaryFile()
        try await withSettings(keepHistory: false) {
            let history = TranscriptionHistory(fileURL: file)
            await history.load()
            history.append(record("secret"))
            #expect(history.records.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    @Test("deleting one record leaves the rest")
    func deletesOne() async throws {
        try await withSettings {
            let history = TranscriptionHistory(fileURL: temporaryFile())
            await history.load()
            let doomed = record("delete me")
            history.append(record("keep me"))
            history.append(doomed)
            history.delete(doomed.id)
            #expect(history.records.map(\.text) == ["keep me"])
            history.delete(UUID())  // unknown id is a no-op, not a crash
            #expect(history.records.count == 1)
        }
    }

    @MainActor
    @Test("clearing empties the file too, not just the list")
    func clearReachesDisk() async throws {
        let file = temporaryFile()
        try await withSettings {
            let history = TranscriptionHistory(fileURL: file)
            await history.load()
            history.append(record("transient"))
            await history.load()
            history.clear()
            await history.load()

            let reopened = TranscriptionHistory(fileURL: file)
            await reopened.load()
            #expect(reopened.records.isEmpty)
        }
    }

    /// A corrupt file must be quarantined rather than deleted: it is the user's
    /// data, and an unreadable file is not the same as a worthless one.
    @MainActor
    @Test("a corrupt file is moved aside, not thrown away")
    func quarantinesCorruptFile() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: file)

        try await withSettings {
            let history = TranscriptionHistory(fileURL: file)
            await history.load()
            #expect(history.records.isEmpty, "a corrupt file must not block startup")
        }

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: file.deletingLastPathComponent().path)
        #expect(
            siblings.contains { $0.contains("corrupt") },
            "the unreadable file should have been preserved alongside: \(siblings)")
    }

    @MainActor
    @Test("only deliverable outcomes become records")
    func mapsOutcomes() {
        #expect(
            TranscriptionRecord(outcome: .pasted("x"), durationSeconds: 1, tier: .ms560)?.outcome
                == "pasted")
        #expect(
            TranscriptionRecord(outcome: .copied("x"), durationSeconds: 1, tier: .ms560)?.outcome
                == "copied")
        #expect(TranscriptionRecord(outcome: .nothing, durationSeconds: 1, tier: .ms560) == nil)
        #expect(
            TranscriptionRecord(
                outcome: .failed(.noAudioCaptured), durationSeconds: 1, tier: .ms560) == nil)
    }

    @MainActor
    @Test("word count counts runs of non-whitespace")
    func countsWords() {
        #expect(record("one two three").wordCount == 3)
        #expect(record("  padded   out  ").wordCount == 2)
        #expect(record("").wordCount == 0)
    }
}
