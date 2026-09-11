import Foundation

/// Small, certain corrections applied to every transcript.
///
/// Deliberately rules and not a model. Everything here is something the
/// recogniser reliably does or reliably omits, established by looking at what it
/// actually produced rather than by guessing — so each rule can be stated,
/// tested, and shown to be safe. Anything requiring judgement about what the
/// speaker *meant* is not in this file.
public struct TranscriptPolish: Sendable, Equatable, Codable {

    /// Finish the last sentence.
    ///
    /// The model punctuates *within* an utterance and never terminates it: across
    /// 22 real dictations, every single one ended on a letter while half
    /// contained commas, apostrophes and question marks mid-text. It is not a
    /// gap in the model's vocabulary — it emits a sentence-final mark once it
    /// hears the *next* sentence begin, and a hold that ends with the sentence
    /// never provides one. Feeding it trailing silence does not help; that was
    /// measured at 0, 200, 400, 800 and 1600 ms and the output was identical
    /// every time.
    public var addsTerminalPunctuation: Bool

    /// Capitalise the first letter, for the same reason: the model capitalises
    /// after a terminal mark it never emitted.
    public var capitalisesFirstWord: Bool

    public init(addsTerminalPunctuation: Bool = true, capitalisesFirstWord: Bool = true) {
        self.addsTerminalPunctuation = addsTerminalPunctuation
        self.capitalisesFirstWord = capitalisesFirstWord
    }

    public static let `default` = TranscriptPolish()
    public static let none = TranscriptPolish(
        addsTerminalPunctuation: false, capitalisesFirstWord: false)

    /// Marks that already end a sentence, so nothing is added after them.
    private static let terminals: Set<Character> = [".", "!", "?", "…", ":", ";", "—", "-", ","]

    /// Words that start a question. Checked against the final clause, because
    /// "I asked what he wanted" is not a question and "what did he want" is.
    private static let interrogatives: Set<String> = [
        "who", "what", "where", "when", "why", "how", "which", "whose", "whom",
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
        "will", "would", "should", "shall", "have", "has", "had", "may", "might",
    ]

    public func apply(to text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return text }

        if capitalisesFirstWord, Self.shouldCapitalise(result) {
            let first = result[result.startIndex]
            result.replaceSubrange(
                result.startIndex...result.startIndex, with: first.uppercased())
        }

        if addsTerminalPunctuation, let last = result.last, !Self.terminals.contains(last) {
            result.append(Self.terminalMark(for: result))
        }
        return result
    }

    /// Capitalise only a word that is plainly lowercase throughout.
    ///
    /// A first word carrying a capital anywhere else — "iPhone", "iOS", "eBay",
    /// "macOS" — is spelled that way on purpose, and "IPhone" is worse than a
    /// missing capital. The recogniser produces these correctly, so the only way
    /// to get them wrong is to "fix" them.
    static func shouldCapitalise(_ text: String) -> Bool {
        guard let first = text.first, first.isLowercase else { return false }
        let firstWord = text.prefix { !$0.isWhitespace }
        return !firstWord.dropFirst().contains(where: \.isUppercase)
    }

    /// A question mark when the final clause opens with an interrogative,
    /// otherwise a full stop.
    ///
    /// Only the final clause is considered: the transcript may contain several
    /// sentences and only the unterminated one is being finished. A wrong mark
    /// here is a small cost — the alternative, leaving every dictation without
    /// any terminal punctuation at all, was the actual complaint.
    static func terminalMark(for text: String) -> Character {
        let clause = text.split(whereSeparator: { ".!?…;:".contains($0) }).last ?? Substring(text)
        let words =
            clause
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard let first = words.first else { return "." }
        // "Can you hear me" is a question; "can openers are useful" is not, but a
        // dictation opening with a bare auxiliary is overwhelmingly the former.
        return interrogatives.contains(first) ? "?" : "."
    }
}
