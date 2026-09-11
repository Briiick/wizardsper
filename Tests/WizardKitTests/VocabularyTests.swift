import Foundation
import Testing

@testable import WizardKit

@Suite("Vocabulary")
struct VocabularyTests {

    private func vocabulary(_ terms: VocabularyTerm..., strictness: Double = Vocabulary.defaultStrictness)
        -> Vocabulary
    {
        Vocabulary(terms: terms, strictness: strictness)
    }

    private var claude: VocabularyTerm { VocabularyTerm(replacement: "Claude") }

    // MARK: - The case this exists for

    /// The model has 1024 SentencePiece pieces of general English. "Claude" is
    /// not among the things it can produce, so it produces what the sound
    /// resembles. These are real outputs, not invented ones.
    @Test(
        "sound-alikes of a proper noun are corrected",
        arguments: ["cloud", "clawed", "Claud", "claude", "clode", "clod"])
    func correctsSoundAlikes(heard: String) {
        let result = vocabulary(claude).apply(to: "I asked \(heard) about it")
        #expect(result == "I asked Claude about it")
    }

    /// The other half of the job, and the harder one. A correction list that
    /// rewrites ordinary words is worse than no list: it corrupts transcripts
    /// that were already right, silently.
    @Test(
        "ordinary words that merely resemble the term are left alone",
        arguments: [
            "called", "closed", "cold", "loud", "code", "class", "claim", "crowd",
            "clouds", "cloudy",
        ])
    func leavesOrdinaryWordsAlone(word: String) {
        let sentence = "I \(word) it yesterday"
        #expect(vocabulary(claude).apply(to: sentence) == sentence)
    }

    // MARK: - Structure preserved

    @Test("punctuation and spacing survive a correction")
    func preservesPunctuation() {
        let v = vocabulary(claude)
        #expect(v.apply(to: "cloud, hello") == "Claude, hello")
        #expect(v.apply(to: "Ask cloud.") == "Ask Claude.")
        #expect(v.apply(to: "\"cloud\"") == "\"Claude\"")
        #expect(v.apply(to: "cloud") == "Claude")
        #expect(v.apply(to: "  cloud  ") == "  Claude  ")
    }

    @Test("every occurrence is corrected, not just the first")
    func correctsEveryOccurrence() {
        #expect(
            vocabulary(claude).apply(to: "cloud and cloud and clawed")
                == "Claude and Claude and Claude")
    }

    @Test("an empty vocabulary and empty text are no-ops")
    func handlesEmpty() {
        #expect(Vocabulary().apply(to: "anything at all") == "anything at all")
        #expect(vocabulary(claude).apply(to: "") == "")
    }

    // MARK: - Phrases

    /// Without longest-first ordering, "Claude" claims the first word and the
    /// phrase can never match.
    @Test("a multi-word term is matched as a unit")
    func matchesPhrases() {
        let v = vocabulary(
            VocabularyTerm(replacement: "Claude Code"),
            claude)
        #expect(v.apply(to: "I use cloud code daily") == "I use Claude Code daily")
        #expect(v.apply(to: "I use cloud daily") == "I use Claude daily")
    }

    @Test("a phrase correction carries the trailing punctuation of its last word")
    func phrasePunctuation() {
        let v = vocabulary(VocabularyTerm(replacement: "Claude Code"))
        #expect(v.apply(to: "in cloud code, yes") == "in Claude Code, yes")
    }

    // MARK: - Explicit aliases

    /// An alias is an instruction, so it applies even to a term the user has
    /// marked as not fuzzy, and even when it sounds nothing like the target.
    @Test("aliases match exactly, regardless of the fuzzy setting")
    func aliasesAreExact() {
        let term = VocabularyTerm(
            replacement: "Kubernetes", aliases: ["cooper netties", "kubernets"], isFuzzy: false)
        let v = vocabulary(term)
        #expect(v.apply(to: "deploy to kubernets now") == "deploy to Kubernetes now")
        // Not an alias, and fuzzy is off, so it stays.
        #expect(v.apply(to: "deploy to koobernetties now") == "deploy to koobernetties now")
    }

    @Test("a non-fuzzy term still corrects its own casing")
    func nonFuzzyFixesCase() {
        let v = vocabulary(VocabularyTerm(replacement: "iPhone", isFuzzy: false))
        #expect(v.apply(to: "my iphone rang") == "my iPhone rang")
    }

    // MARK: - Stability

    /// Applying twice must equal applying once, or a partial and the final
    /// transcript would drift apart as the same text is corrected repeatedly.
    @Test("correction is idempotent")
    func isIdempotent() {
        let v = vocabulary(claude, VocabularyTerm(replacement: "Claude Code"))
        let once = v.apply(to: "ask cloud code about cloud")
        #expect(v.apply(to: once) == once)
    }

    /// A word already replaced by one term must not be re-read by the next, or
    /// the result would depend on the order the user happened to add them in.
    @Test("one correction cannot be rewritten by another term")
    func correctionsDoNotCascade() {
        let v = vocabulary(
            VocabularyTerm(replacement: "Claude"),
            VocabularyTerm(replacement: "Clyde"))
        #expect(v.apply(to: "cloud") == "Claude")
    }

    @Test("strictness widens and narrows what is accepted")
    func strictnessMatters() {
        let tight = vocabulary(claude, strictness: 0.01)
        #expect(tight.apply(to: "clawed it") == "clawed it")
        // Still corrected below the fuzzy gate, because a one-character slip is
        // accepted on distance alone.
        #expect(tight.apply(to: "claud it") == "Claude it")

        let loose = vocabulary(claude, strictness: Vocabulary.defaultStrictness)
        #expect(loose.apply(to: "clawed it") == "Claude it")
    }

    /// "clod" is a rare word, and a user who has typed "Claude" into their
    /// dictionary is far more likely to have said Claude than to have said clod.
    /// Correcting it is the intent; "cloudy" and "clouds" are the nearby words
    /// that must survive, and they do because their final letters change the
    /// consonant skeleton.
    @Test("a rare homophone is corrected but its inflections are not")
    func rareHomophoneVersusInflections() {
        let v = vocabulary(claude)
        #expect(v.apply(to: "a clod of earth") == "a Claude of earth")
        #expect(v.apply(to: "it looks cloudy") == "it looks cloudy")
        #expect(v.apply(to: "the clouds moved") == "the clouds moved")
    }

    // MARK: - The pieces

    @Test("the phonetic key folds spellings of the same sound together")
    func phoneticKeyFolds() {
        #expect(Vocabulary.phoneticKey("claude") == Vocabulary.phoneticKey("cloud"))
        #expect(Vocabulary.phoneticKey("claude") == Vocabulary.phoneticKey("clawed"))
        #expect(Vocabulary.phoneticKey("phone") == Vocabulary.phoneticKey("fone"))
        #expect(Vocabulary.phoneticKey("night") == Vocabulary.phoneticKey("nite"))
        #expect(Vocabulary.phoneticKey("claude") != Vocabulary.phoneticKey("grape"))
        // The collisions that would cause silent false corrections.
        #expect(Vocabulary.phoneticKey("claude") != Vocabulary.phoneticKey("cloudy"))
        #expect(Vocabulary.phoneticKey("claude") != Vocabulary.phoneticKey("clouds"))
        #expect(Vocabulary.phoneticKey("claude") != Vocabulary.phoneticKey("closed"))
    }

    @Test("normalised distance is a fraction of the longer string")
    func distanceIsNormalised() {
        #expect(Vocabulary.normalisedDistance("abc", "abc") == 0)
        #expect(Vocabulary.normalisedDistance("", "abc") == 1)
        #expect(abs(Vocabulary.normalisedDistance("abc", "abd") - 1.0 / 3.0) < 1e-9)
    }

    @Test("tokenizing and rendering round-trips any text unchanged")
    func tokenizerRoundTrips() {
        for text in [
            "Hello, world!", "  leading and trailing  ", "a", "", "...",
            "don't — really, \"quoted\" (parenthesised) 42",
        ] {
            #expect(Token.tokenize(text).map(\.rendered).joined() == text, "failed on: \(text)")
        }
    }

    @Test("Codable round-trips so the list survives a relaunch")
    func codableRoundTrip() throws {
        let v = vocabulary(
            VocabularyTerm(replacement: "Claude", aliases: ["cloud"], isFuzzy: true),
            strictness: 0.4)
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(Vocabulary.self, from: data) == v)
    }
}
