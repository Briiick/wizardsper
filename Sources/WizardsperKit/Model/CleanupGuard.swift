import Foundation

/// Decides whether a rewrite may replace what the user actually said.
///
/// This is the part of LLM cleanup that has to be right. Everything else is a
/// convenience; this is the difference between a dictation tool and a tool that
/// quietly puts words in your mouth. A language model asked to tidy a transcript
/// will sometimes answer it instead, finish a sentence that was cut off, or
/// produce something fluent and unrelated — and all three read *well*, which is
/// exactly why the user will not catch them.
///
/// So the rewrite is treated as a proposal, not a result. It is accepted only if
/// it still looks like the same utterance: mostly the same words, in roughly the
/// same quantity. When in doubt the raw transcript wins, because a transcript
/// with "um" in it is a far smaller failure than a confident paraphrase of
/// something the user did not say.
///
/// Deliberately pure and model-free, so every rule here is testable without
/// Apple Intelligence, a network, or a GPU.
public struct CleanupGuard: Sendable, Equatable {

    /// A rewrite may not grow much. Cleanup removes words — fillers, repetition,
    /// false starts — so a longer result means the model added something, and
    /// the thing it most often adds is an ending the user never spoke. Slightly
    /// above 1 rather than exactly 1 because punctuation and expanded
    /// contractions legitimately add a little.
    public var maximumGrowth = 1.15
    /// How much of the original must survive. Below this it is a paraphrase, or
    /// an answer, rather than the same sentence tidied.
    public var minimumRetention = 0.55
    /// Rewrites of very short transcripts are not worth the risk: there is
    /// almost nothing to clean in four words, and a single substituted word is a
    /// large fraction of the meaning.
    public var minimumWords = 5

    public init() {}

    public enum Verdict: Sendable, Equatable {
        case accept(String)
        case reject(Reason)

        public enum Reason: String, Sendable, Equatable {
            case empty = "the rewrite came back empty"
            case tooShortToBother = "too few words to be worth rewriting"
            case grew = "the rewrite is longer than what was said"
            case driftedTooFar = "the rewrite kept too little of what was said"
            case looksLikeAnAnswer = "the rewrite answers the text instead of tidying it"
            case unchanged = "nothing to change"
        }
    }

    public func check(raw: String, rewritten: String) -> Verdict {
        let rawWords = Self.words(raw)
        let newWords = Self.words(rewritten)

        guard !newWords.isEmpty else { return .reject(.empty) }
        guard rawWords.count >= minimumWords else { return .reject(.tooShortToBother) }

        let trimmed = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .reject(.unchanged)
        }

        guard Double(newWords.count) <= Double(rawWords.count) * maximumGrowth + 1 else {
            return .reject(.grew)
        }

        // Checked before retention, because it is the more specific diagnosis.
        // Retention would catch most answers anyway — but "it answered you"
        // tells a reader what went wrong, where "it kept too little" leaves them
        // guessing, and the two are reported in logs and in the flow bar.
        if Self.readsAsAnAnswer(raw: raw, rewritten: trimmed) {
            return .reject(.looksLikeAnAnswer)
        }

        // Retention is measured as a multiset intersection, so repeated words
        // count once each rather than a single "the" vouching for the whole
        // sentence.
        let retained = Self.overlap(rawWords, newWords)
        guard Double(retained) / Double(rawWords.count) >= minimumRetention else {
            return .reject(.driftedTooFar)
        }
        return .accept(trimmed)
    }

    // MARK: - Pieces

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isWordCharacter }).map(String.init)
    }

    /// Size of the multiset intersection.
    static func overlap(_ a: [String], _ b: [String]) -> Int {
        var counts: [String: Int] = [:]
        for word in b { counts[word, default: 0] += 1 }
        var shared = 0
        for word in a where (counts[word] ?? 0) > 0 {
            counts[word]! -= 1
            shared += 1
        }
        return shared
    }

    /// A question that comes back as a statement has almost certainly been
    /// answered rather than tidied.
    ///
    /// This is the failure mode with the worst consequences: the user dictates
    /// "what time is the meeting", and a helpful model replies. The reply is
    /// fluent, plausible, and pasted into their document. Retention usually
    /// catches it, but not when the answer reuses the question's words — "what
    /// time is the meeting" -> "The meeting is at three" keeps most of them.
    static func readsAsAnAnswer(raw: String, rewritten: String) -> Bool {
        let rawIsQuestion = raw.contains("?") || startsInterrogatively(raw)
        guard rawIsQuestion else { return false }
        return !rewritten.contains("?")
    }


    static func startsInterrogatively(_ text: String) -> Bool {
        Interrogative.opens(text)
    }
}
