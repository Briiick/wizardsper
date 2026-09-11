import Foundation
import Observation

/// User-visible preferences, persisted to `UserDefaults` on every mutation.
///
/// Main-actor isolated because the dashboard binds directly to it, and every
/// reader — the coordinator included — is itself on the main actor.
@MainActor
@Observable
public final class Settings {
    public static let shared = Settings()

    private let defaults: UserDefaults
    private var loaded = false

    /// Writes one key, not all fifteen. `persist()` used to re-encode every
    /// setting on every mutation, so dragging a slider re-serialised the entire
    /// vocabulary list on each frame of the drag.
    private func persist<T>(_ value: T, _ key: String) where T: Encodable {
        guard loaded else { return }
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func persist(_ value: Bool, _ key: String) {
        guard loaded else { return }
        defaults.set(value, forKey: key)
    }

    private func persist(_ value: Int, _ key: String) {
        guard loaded else { return }
        defaults.set(value, forKey: key)
    }

    private func persist(_ value: Double, _ key: String) {
        guard loaded else { return }
        defaults.set(value, forKey: key)
    }

    public var chord: Chord = .fn { didSet { persist(chord, Key.chord) } }
    public var tier: NemotronTier = .default { didSet { if loaded { defaults.set(tier.rawValue, forKey: Key.tier) } } }
    public var framing: FramingPolicy = .default { didSet { persist(framing, Key.framing) } }

    /// Deliver Cmd-V after copying. When off, every session ends as `.copied`.
    public var pasteAutomatically = true { didSet { persist(pasteAutomatically, Key.pasteAutomatically) } }
    /// Pause whatever is playing for the duration of a hold, and put it back.
    public var pausesPlayback = true { didSet { persist(pausesPlayback, Key.pausesPlayback) } }
    /// Put a space after the pasted text, so the next dictation does not weld
    /// itself to the end of this one.
    public var appendTrailingSpace = true { didSet { persist(appendTrailingSpace, Key.appendTrailingSpace) } }
    /// Restore whatever was on the pasteboard before the paste.
    public var restorePasteboard = true { didSet { persist(restorePasteboard, Key.restorePasteboard) } }
    public var showFlowBar = true { didSet { persist(showFlowBar, Key.showFlowBar) } }
    public var keepHistory = true { didSet { persist(keepHistory, Key.keepHistory) } }
    public var historyRetentionDays = 7 { didSet { persist(historyRetentionDays, Key.historyRetentionDays) } }
    /// Rewrite finished transcripts with the on-device language model.
    public var cleanup = CleanupPolicy.default { didSet { persist(cleanup, Key.cleanup) } }

    /// Small certain corrections: finish the sentence, capitalise the start.
    public var polish = TranscriptPolish.default { didSet { persist(polish, Key.polish) } }

    /// Words the recogniser cannot produce, and what to write instead.
    /// See `Vocabulary`.
    public var vocabulary = Vocabulary.starter { didSet { persist(vocabulary, Key.vocabulary) } }

    /// Linear input gain applied to captured audio before recognition.
    ///
    /// Not a preference so much as a calibration: microphones differ by more
    /// than an order of magnitude in the level they deliver for the same voice,
    /// and speech that arrives too quiet decodes to blanks rather than to a bad
    /// transcript. See `GainBox`.
    public var inputGain: Double = 1 { didSet { persist(inputGain, Key.inputGain) } }
    /// Holds shorter than this are treated as an accidental tap and produce
    /// `.nothing` rather than a transcript.
    public var minimumHoldSeconds = 0.25 { didSet { persist(minimumHoldSeconds, Key.minimumHoldSeconds) } }
    public var launchAtLogin = false { didSet { persist(launchAtLogin, Key.launchAtLogin) } }



    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        loaded = true
    }

    private enum Key {
        static let chord = "chord"
        static let tier = "tier"
        static let framing = "framing"
        static let pasteAutomatically = "pasteAutomatically"
        static let restorePasteboard = "restorePasteboard"
        static let appendTrailingSpace = "appendTrailingSpace"
        static let pausesPlayback = "pausesPlayback"
        static let showFlowBar = "showFlowBar"
        static let keepHistory = "keepHistory"
        static let historyRetentionDays = "historyRetentionDays"
        static let minimumHoldSeconds = "minimumHoldSeconds"
        static let launchAtLogin = "launchAtLogin"
        static let inputGain = "inputGain"
        static let vocabulary = "vocabulary"
        static let polish = "polish"
        static let cleanup = "cleanup"
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Key.chord),
            let value = try? decoder.decode(Chord.self, from: data), !value.isEmpty
        {
            chord = value
        }
        if let raw = defaults.object(forKey: Key.tier) as? Int,
            let value = NemotronTier(rawValue: raw)
        {
            tier = value
        }
        if let data = defaults.data(forKey: Key.framing),
            let value = try? decoder.decode(FramingPolicy.self, from: data)
        {
            framing = value
        }
        if defaults.object(forKey: Key.pasteAutomatically) != nil {
            pasteAutomatically = defaults.bool(forKey: Key.pasteAutomatically)
        }
        if defaults.object(forKey: Key.restorePasteboard) != nil {
            restorePasteboard = defaults.bool(forKey: Key.restorePasteboard)
        }
        if defaults.object(forKey: Key.appendTrailingSpace) != nil {
            appendTrailingSpace = defaults.bool(forKey: Key.appendTrailingSpace)
        }
        if defaults.object(forKey: Key.pausesPlayback) != nil {
            pausesPlayback = defaults.bool(forKey: Key.pausesPlayback)
        }
        if defaults.object(forKey: Key.showFlowBar) != nil {
            showFlowBar = defaults.bool(forKey: Key.showFlowBar)
        }
        if defaults.object(forKey: Key.keepHistory) != nil {
            keepHistory = defaults.bool(forKey: Key.keepHistory)
        }
        if let days = defaults.object(forKey: Key.historyRetentionDays) as? Int {
            historyRetentionDays = max(0, days)
        }
        if let seconds = defaults.object(forKey: Key.minimumHoldSeconds) as? Double {
            minimumHoldSeconds = max(0, seconds)
        }
        if defaults.object(forKey: Key.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }
        if let gain = defaults.object(forKey: Key.inputGain) as? Double {
            inputGain = Double(GainBox.clamp(Float(gain)))
        }
        if let data = defaults.data(forKey: Key.vocabulary),
            let value = try? decoder.decode(Vocabulary.self, from: data)
        {
            vocabulary = value
        }
        if let data = defaults.data(forKey: Key.polish),
            let value = try? decoder.decode(TranscriptPolish.self, from: data)
        {
            polish = value
        }
        if let data = defaults.data(forKey: Key.cleanup),
            let value = try? decoder.decode(CleanupPolicy.self, from: data)
        {
            cleanup = value
        }
    }

}

/// Canonical on-disk locations.
public enum WizardsperPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Wizardsper", isDirectory: true)
    }

    public static var models: URL {
        applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    public static func modelDirectory(for tier: NemotronTier) -> URL {
        models.appendingPathComponent(tier.subdirectory, isDirectory: true)
    }

    public static var historyFile: URL {
        applicationSupport.appendingPathComponent("transcription history.json")
    }

    public static func ensureApplicationSupport() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
    }
}
