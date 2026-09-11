import Foundation
import Observation

/// User-visible preferences, persisted to `UserDefaults` on every mutation.
///
/// Main-actor isolated because the dashboard binds directly to it; the
/// coordinator reads a `Snapshot` so nothing off the main actor touches this
/// object.
@MainActor
@Observable
public final class Settings {
    public static let shared = Settings()

    private let defaults: UserDefaults
    private var loaded = false

    public var chord: Chord = .fn { didSet { persist() } }
    public var tier: NemotronTier = .default { didSet { persist() } }
    public var framing: FramingPolicy = .default { didSet { persist() } }

    /// Deliver Cmd-V after copying. When off, every session ends as `.copied`.
    public var pasteAutomatically = true { didSet { persist() } }
    /// Restore whatever was on the pasteboard before the paste.
    public var restorePasteboard = true { didSet { persist() } }
    public var showFlowBar = true { didSet { persist() } }
    public var keepHistory = true { didSet { persist() } }
    public var historyRetentionDays = 7 { didSet { persist() } }
    /// Small certain corrections: finish the sentence, capitalise the start.
    public var polish = TranscriptPolish.default { didSet { persist() } }

    /// Words the recogniser cannot produce, and what to write instead.
    /// See `Vocabulary`.
    public var vocabulary = Vocabulary.starter { didSet { persist() } }

    /// Linear input gain applied to captured audio before recognition.
    ///
    /// Not a preference so much as a calibration: microphones differ by more
    /// than an order of magnitude in the level they deliver for the same voice,
    /// and speech that arrives too quiet decodes to blanks rather than to a bad
    /// transcript. See `GainBox`.
    public var inputGain: Double = 1 { didSet { persist() } }
    /// Holds shorter than this are treated as an accidental tap and produce
    /// `.nothing` rather than a transcript.
    public var minimumHoldSeconds = 0.25 { didSet { persist() } }
    public var launchAtLogin = false { didSet { persist() } }

    /// An immutable copy safe to hand to a background actor.
    public struct Snapshot: Sendable, Equatable {
        public var chord: Chord
        public var tier: NemotronTier
        public var framing: FramingPolicy
        public var pasteAutomatically: Bool
        public var restorePasteboard: Bool
        public var showFlowBar: Bool
        public var keepHistory: Bool
        public var historyRetentionDays: Int
        public var minimumHoldSeconds: Double
        public var inputGain: Double
        public var vocabulary: Vocabulary
        public var polish: TranscriptPolish
    }

    public var snapshot: Snapshot {
        Snapshot(
            chord: chord, tier: tier, framing: framing,
            pasteAutomatically: pasteAutomatically, restorePasteboard: restorePasteboard,
            showFlowBar: showFlowBar, keepHistory: keepHistory,
            historyRetentionDays: historyRetentionDays, minimumHoldSeconds: minimumHoldSeconds,
            inputGain: inputGain, vocabulary: vocabulary, polish: polish)
    }

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
        static let showFlowBar = "showFlowBar"
        static let keepHistory = "keepHistory"
        static let historyRetentionDays = "historyRetentionDays"
        static let minimumHoldSeconds = "minimumHoldSeconds"
        static let launchAtLogin = "launchAtLogin"
        static let inputGain = "inputGain"
        static let vocabulary = "vocabulary"
        static let polish = "polish"
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
    }

    private func persist() {
        guard loaded else { return }
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(chord), forKey: Key.chord)
        defaults.set(tier.rawValue, forKey: Key.tier)
        defaults.set(try? encoder.encode(framing), forKey: Key.framing)
        defaults.set(pasteAutomatically, forKey: Key.pasteAutomatically)
        defaults.set(restorePasteboard, forKey: Key.restorePasteboard)
        defaults.set(showFlowBar, forKey: Key.showFlowBar)
        defaults.set(keepHistory, forKey: Key.keepHistory)
        defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays)
        defaults.set(minimumHoldSeconds, forKey: Key.minimumHoldSeconds)
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(inputGain, forKey: Key.inputGain)
        defaults.set(try? encoder.encode(vocabulary), forKey: Key.vocabulary)
        defaults.set(try? encoder.encode(polish), forKey: Key.polish)
    }
}

/// Canonical on-disk locations.
public enum WizardPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Wizard", isDirectory: true)
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
