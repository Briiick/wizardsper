import Foundation

/// A word the recogniser will not get right on its own, and what to put in its
/// place.
///
/// The model's vocabulary is 1024 SentencePiece pieces trained on general
/// English. Proper nouns outside that distribution — product names, people,
/// jargon — come back as whatever ordinary words they sound like: "Claude"
/// arrives as "cloud", "clawed" or "Claud", and no amount of speaking clearly
/// changes that, because the model is not choosing between those options. It
/// never considered the right one.
///
/// Correcting it afterwards is the practical fix, and it has to be fuzzy: a list
/// of exact spellings would need every mis-hearing enumerated in advance, and
/// the interesting ones are the ones nobody predicted.
public struct VocabularyTerm: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// What to write. Also matched against, so the correct spelling needs no
    /// separate alias.
    public var replacement: String
    /// Spellings the user has seen come back and wants mapped explicitly. These
    /// match exactly and always win over fuzzy matching.
    public var aliases: [String]
    /// Allow sound-alike matching. Off for terms that are ordinary words, where
    /// fuzziness would rewrite correct transcripts.
    public var isFuzzy: Bool

    public init(
        id: UUID = UUID(), replacement: String, aliases: [String] = [], isFuzzy: Bool = true
    ) {
        self.id = id
        self.replacement = replacement
        self.aliases = aliases
        self.isFuzzy = isFuzzy
    }

    /// How many words the replacement spans; a phrase has to be matched as a
    /// unit or "Claude Code" can never beat "cloud" plus "code" separately.
    public var wordCount: Int {
        max(1, replacement.split(separator: " ").count)
    }
}

/// The user's correction list, and the algorithm that applies it.
///
/// Deliberately a pure value type with a pure `apply`: this is the one piece of
/// the pipeline whose behaviour is entirely decidable from its inputs, so it is
/// the one piece that can be tested exhaustively. Every threshold below was set
/// against the cases in `VocabularyTests`, not by feel.
public struct Vocabulary: Codable, Sendable, Equatable {

    public var terms: [VocabularyTerm]
    /// How far a word may be from a term and still be corrected, as a fraction
    /// of the term's length. Raising it corrects more and rewrites more.
    public var strictness: Double

    /// Default ceiling on edit distance for a *phonetically confirmed* match.
    ///
    /// 0.5 is high for edit distance alone and deliberately so — it is never
    /// used alone. Every word at that range that must be corrected ("clawed",
    /// "clod" for "Claude") and every word that must not ("loud", "code",
    /// "class", "claim") is at exactly 0.5, so distance cannot separate them and
    /// the consonant skeleton does all the work. See `VocabularyTests`, which
    /// pins both halves.
    public static let defaultStrictness = 0.5
    /// Distance below which a match is accepted on edit distance alone. Tight
    /// enough that only a spelling slip qualifies.
    static let confidentDistance = 0.2

    public init(terms: [VocabularyTerm] = [], strictness: Double = Vocabulary.defaultStrictness) {
        self.terms = terms
        self.strictness = strictness
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// What a new install starts with. One entry, chosen because it is the case
    /// that motivated the feature and because it demonstrates the shape of a
    /// useful entry without the user having to guess at one.
    public static let starter = Vocabulary(terms: [VocabularyTerm(replacement: "Claude")])

    // MARK: - Applying

    /// Rewrite `text`, preserving everything that is not a matched word:
    /// spacing, punctuation, and the surrounding sentence.
    public func apply(to text: String) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }

        var tokens = Token.tokenize(text)
        guard !tokens.isEmpty else { return text }

        // Longest terms first: "Claude Code" must get the chance to claim both
        // words before "Claude" claims the first one and leaves "code" behind.
        //
        // Each term's forms are normalised and keyed once here, not once per
        // window. They depend only on the term, and the window loop below visits
        // every word of the transcript — so this used to redo the same
        // normalisation and the same phonetic key for a twenty-term list a
        // hundred and fifty times per partial, twice a second, on the main actor.
        let ordered = terms.sorted { $0.wordCount > $1.wordCount }.map(Prepared.init)

        for term in ordered {
            let span = term.term.wordCount
            guard span > 0 else { continue }
            var index = 0
            while index + span <= tokens.count {
                // A slice, not a copy: this runs once per word of the transcript.
                let window = tokens[index..<(index + span)]
                // A window that already contains a correction is left alone; a
                // second term rewriting the first term's output would make the
                // result depend on list order in a way no user could predict.
                if window.contains(where: \.isCorrected) {
                    index += 1
                    continue
                }
                if matches(window: window, term: term) {
                    tokens[index].core = term.term.replacement
                    tokens[index].isCorrected = true
                    // Trailing punctuation of the *last* token in the window
                    // moves onto the replacement, so "cloud," becomes "Claude,".
                    tokens[index].trailing = window[index + span - 1].trailing
                    if span > 1 {
                        tokens.removeSubrange((index + 1)..<(index + span))
                    }
                    index += 1
                } else {
                    index += 1
                }
            }
        }

        return tokens.map(\.rendered).joined()
    }

    // MARK: - Matching

    /// A term with its forms already normalised and keyed.
    private struct Prepared {
        let term: VocabularyTerm
        /// Each form as `(normalised, phoneticKey)`, in match order.
        let forms: [(normalised: String, phonetic: String)]

        init(_ term: VocabularyTerm) {
            self.term = term
            self.forms = ([term.replacement] + term.aliases)
                .map(Vocabulary.normalise)
                .filter { !$0.isEmpty }
                .map { ($0, Vocabulary.phoneticKey($0)) }
        }
    }

    private func matches(window: ArraySlice<Token>, term: Prepared) -> Bool {
        let candidate = window.map(\.core).joined(separator: " ")
        let normalisedCandidate = Self.normalise(candidate)
        guard !normalisedCandidate.isEmpty else { return false }

        // Exact forms first, and they do not depend on `isFuzzy`: an alias the
        // user typed in is an instruction, not a guess.
        for form in term.forms where form.normalised == normalisedCandidate { return true }
        guard term.term.isFuzzy else { return false }

        let candidateKey = Self.phoneticKey(normalisedCandidate)
        for (normalisedForm, formKey) in term.forms {
            // Levenshtein cannot come in under the threshold when the lengths
            // already differ by more than it, so this skips most of the work
            // without changing any answer.
            let longer = max(normalisedCandidate.count, normalisedForm.count)
            let lengthGap = abs(normalisedCandidate.count - normalisedForm.count)
            guard Double(lengthGap) <= Double(longer) * max(strictness, Self.confidentDistance)
            else { continue }

            let distance = Self.normalisedDistance(normalisedCandidate, normalisedForm)
            if distance <= Self.confidentDistance { return true }
            // Beyond that, sounding alike is required as well. Edit distance on
            // its own at this range rewrites real words: "called" is close
            // enough to "Claude" to be tempting and is obviously not it, while
            // "cloud" is both close and homophonic.
            if distance <= strictness, candidateKey == formKey { return true }
        }
        return false
    }

    /// Lowercased letters and digits only. Punctuation and case carry no
    /// information about which word was said.
    static func normalise(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Levenshtein distance as a fraction of the longer string.
    static func normalisedDistance(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }
        let left = Array(a), right = Array(b)
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[right.count]) / Double(max(left.count, right.count))
    }

    /// A crude consonant skeleton, in the spirit of Metaphone.
    ///
    /// Vowels are dropped after the first letter and the common English
    /// spellings of the same sound are folded together, so "Claude", "cloud" and
    /// "clawed" all reduce to the same key. It is not a pronunciation
    /// dictionary and does not need to be: it is only ever used to *confirm* a
    /// match that edit distance already thinks is plausible, so its job is to
    /// reject coincidences, not to find matches on its own.
    static func phoneticKey(_ text: String) -> String {
        let letters = Array(text.lowercased().filter { $0.isLetter })
        guard !letters.isEmpty else { return "" }

        var key = ""
        var index = 0
        while index < letters.count {
            let character = letters[index]
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            var mapped: String?

            switch character {
            case "a", "e", "i", "o", "u":
                // Only a leading vowel survives; inside a word the vowel is the
                // part speakers and recognisers disagree about.
                mapped = index == 0 ? String(character) : nil
            case "h", "w":
                mapped = index == 0 ? String(character) : nil
            case "y":
                // Kept at either end. A leading "y" is a consonant, and a
                // trailing one is a vowel that carries the word: dropping it
                // collapsed "cloudy" onto "claude", which then sat inside the
                // distance gate and would have been silently rewritten.
                mapped = (index == 0 || index == letters.count - 1) ? "y" : nil
            case "c":
                if next == "h" {
                    mapped = "x"
                    index += 1
                } else if next == "e" || next == "i" || next == "y" {
                    mapped = "s"
                } else {
                    mapped = "k"
                }
            case "q":
                mapped = "k"
            case "x":
                mapped = "ks"
            case "z":
                mapped = "s"
            case "p":
                if next == "h" {
                    mapped = "f"
                    index += 1
                } else {
                    mapped = "p"
                }
            case "g":
                if next == "h" {
                    mapped = nil  // "night", "though"
                    index += 1
                } else {
                    mapped = "k"
                }
            case "d":
                if next == "g" {
                    mapped = "j"
                    index += 1
                } else {
                    mapped = "t"
                }
            case "t":
                if next == "h" {
                    mapped = "0"
                    index += 1
                } else {
                    mapped = "t"
                }
            case "s":
                if next == "h" {
                    mapped = "x"
                    index += 1
                } else {
                    mapped = "s"
                }
            case "b", "v":
                mapped = "f"
            case "k":
                mapped = "k"
            default:
                mapped = String(character)
            }

            if let mapped, key.last.map(String.init) != mapped {
                key += mapped
            }
            index += 1
        }
        return key
    }
}

/// One word plus whatever punctuation and whitespace sat around it, so a
/// rewrite can replace the word and put the rest back exactly as it was.
struct Token {
    var leading: String
    var core: String
    var trailing: String
    var isCorrected = false

    var rendered: String { leading + core + trailing }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var leading = ""
        var core = ""
        var trailing = ""

        func flush() {
            if !core.isEmpty || !leading.isEmpty || !trailing.isEmpty {
                tokens.append(Token(leading: leading, core: core, trailing: trailing))
            }
            leading = ""
            core = ""
            trailing = ""
        }

        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "'"
            if isWord {
                // A word character after trailing punctuation means the previous
                // token has ended.
                if !trailing.isEmpty { flush() }
                core.append(character)
            } else {
                if core.isEmpty {
                    leading.append(character)
                } else {
                    trailing.append(character)
                }
            }
        }
        flush()
        return tokens
    }
}
