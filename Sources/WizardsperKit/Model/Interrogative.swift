import Foundation

/// Which words open a question in English.
///
/// One fact, needed in two unrelated places: `TranscriptPolish` uses it to
/// decide whether to finish a sentence with "?" or ".", and `CleanupGuard` uses
/// it to catch a language model that answered the user instead of tidying what
/// they said.
///
/// Two callers is not normally enough to justify extracting anything. It is here
/// because what is shared is a fact about English rather than a convenience, and
/// the two private copies this replaces had **already drifted**: one listed "am"
/// and the other did not, so "am I late" was punctuated as a question by one
/// stage and not recognised as one by the other.
public enum Interrogative {

    public static let words: Set<String> = [
        "who", "what", "where", "when", "why", "how", "which", "whose", "whom",
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
        "will", "would", "should", "shall", "have", "has", "had", "may", "might",
    ]

    /// True when the first word of `clause` opens a question.
    public static func opens(_ clause: some StringProtocol) -> Bool {
        let first = clause.lowercased().split(whereSeparator: { !$0.isWordCharacter }).first
        guard let first else { return false }
        return words.contains(String(first))
    }
}

extension Character {
    /// Part of a word for the purpose of splitting transcribed speech.
    ///
    /// Apostrophes count, so "don't" is one word rather than two. Digits count,
    /// because a dictated "route 66" is two words and not three. Three separate
    /// predicates in this codebase used to disagree about the digit case.
    public var isWordCharacter: Bool {
        isLetter || isNumber || self == "'"
    }
}
