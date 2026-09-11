import Foundation
import Testing

@testable import WizardKit

@MainActor
private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wizard-verify-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("transcription history.json")
}

private func rec(_ text: String) -> TranscriptionRecord {
    TranscriptionRecord(
        date: Date(), text: text, durationSeconds: 1, tierMilliseconds: 560, outcome: "pasted")
}

@Suite("ZZTempVerify", .serialized)
struct ZZTempVerifyHistory {

    /// Fill every name quarantine could pick for the next few seconds so the
    /// move-aside cannot succeed, then prove the next dictation does not
    /// overwrite the file it failed to preserve.
    @MainActor
    @Test("an unpreservable file is not clobbered by the next append")
    func blocksWhenQuarantineFails() async throws {
        let file = tempFile()
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data("this is not json".utf8)
        try original.write(to: file)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        for offset in 0..<4 {
            let prefix = "transcription history.corrupt-"
                + stamp.string(from: Date().addingTimeInterval(Double(offset)))
            try Data().write(to: dir.appendingPathComponent("\(prefix).json"))
            for suffix in 1..<100 {
                try Data().write(to: dir.appendingPathComponent("\(prefix)-\(suffix).json"))
            }
        }

        let settings = Settings.shared
        let keep = settings.keepHistory
        let days = settings.historyRetentionDays
        settings.keepHistory = true
        settings.historyRetentionDays = 0
        defer {
            settings.keepHistory = keep
            settings.historyRetentionDays = days
        }

        let history = TranscriptionHistory(fileURL: file)
        await history.load()
        #expect(history.records.isEmpty)

        history.append(rec("brand new dictation"))
        await history.flush()

        #expect(history.lastWriteError != nil, "the refused write must surface")
        let onDisk = try Data(contentsOf: file)
        #expect(onDisk == original, "the unreadable history must still be on disk untouched")
    }

    /// A file that could not be read blocks the write only until the save can
    /// move it aside; then the dictation lands and the old bytes survive.
    @MainActor
    @Test("an unreadable file is preserved on the next save, then writing resumes")
    func recoversByQuarantiningLater() async throws {
        let file = tempFile()
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data("older history nobody can read".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))

        let settings = Settings.shared
        let keep = settings.keepHistory
        let days = settings.historyRetentionDays
        settings.keepHistory = true
        settings.historyRetentionDays = 0
        defer {
            settings.keepHistory = keep
            settings.historyRetentionDays = days
        }

        let history = TranscriptionHistory(fileURL: file)
        await history.load()
        history.append(rec("brand new dictation"))
        await history.flush()

        #expect(history.lastWriteError == nil, "the move-aside should have unblocked the write")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try #require(siblings.first { $0.contains("corrupt") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == original)

        let reopened = TranscriptionHistory(fileURL: file)
        await reopened.load()
        #expect(reopened.records.map(\.text) == ["brand new dictation"])
    }

    /// flush() is what the app delegate will call at quit; without it the last
    /// dictation is still in flight when the process goes away.
    @MainActor
    @Test("flush makes the last dictation reach disk")
    func flushWaitsForTheWrite() async throws {
        let file = tempFile()
        let settings = Settings.shared
        let keep = settings.keepHistory
        settings.keepHistory = true
        defer { settings.keepHistory = keep }

        let history = TranscriptionHistory(fileURL: file)
        await history.load()
        history.append(rec("last words"))
        await history.flush()

        let reopened = TranscriptionHistory(fileURL: file)
        await reopened.load()
        #expect(reopened.records.map(\.text) == ["last words"])
    }
}
