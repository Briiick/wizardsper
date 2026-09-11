import Foundation
import Testing

@testable import WizardsperKit

/// The guard is the only thing standing between a language model and the user's
/// words, so it is tested against what models actually do wrong rather than
/// against what they are supposed to do.
@Suite("Cleanup guard")
struct CleanupGuardTests {

    private let guardrail = CleanupGuard()

    private func verdict(_ raw: String, _ rewritten: String) -> CleanupGuard.Verdict {
        guardrail.check(raw: raw, rewritten: rewritten)
    }

    // MARK: - What it must let through

    /// Verbatim from the app's own history, with the fillers and the false start
    /// taken out. This is the whole point of the feature.
    @Test("an honest tidy-up is accepted")
    func acceptsRealCleanup() {
        let raw =
            "But like he was gonna no, we always took our like dude wives with us cause that toilet paper it's like one ply"
        let clean =
            "We always took our dude wives with us, because that toilet paper is like one ply."
        #expect(verdict(raw, clean) == .accept(clean))
    }

    @Test("removing fillers and stutters is accepted")
    func acceptsFillerRemoval() {
        let raw = "Been all the way range yeah actually it's funny because the I thought that it was just a northeast thing but then the the one around the farm"
        let clean = "Actually it's funny, because I thought that it was just a northeast thing, but then the one around the farm."
        #expect(verdict(raw, clean) == .accept(clean))
    }

    // MARK: - What it must stop

    /// The worst failure mode: the model answers instead of tidying. The reply
    /// is fluent and plausible and would be pasted straight into a document.
    @Test("an answer to a question is rejected")
    func rejectsAnswers() {
        let raw = "What time is the meeting tomorrow morning"
        #expect(verdict(raw, "The meeting is at three in the afternoon.") == .reject(.looksLikeAnAnswer))
    }

    /// The case retention cannot catch: an answer built almost entirely out of
    /// the question's own words scores high on overlap and still is not a tidy-up.
    @Test("an answer that reuses the question's words is still rejected")
    func rejectsHighOverlapAnswers() {
        let raw = "What time is the meeting tomorrow morning"
        #expect(verdict(raw, "The meeting tomorrow morning is at what time.") == .reject(.looksLikeAnAnswer))
    }

    @Test("a question tidied into a question is still accepted")
    func acceptsTidiedQuestions() {
        let raw = "so um what time is the the meeting tomorrow morning"
        let clean = "What time is the meeting tomorrow morning?"
        #expect(verdict(raw, clean) == .accept(clean))
    }

    /// The transcript ends when the key is released, which is often mid-clause.
    /// A model asked to tidy it is strongly tempted to finish the thought.
    @Test("a hallucinated ending is rejected")
    func rejectsCompletion() {
        let raw = "Like, what is the shower situation? There's no"
        let long = "Like, what is the shower situation? There's no running water at the campsite, so we will have to bring our own supply and heat it over the fire each morning."
        #expect(verdict(raw, long) == .reject(.grew))
    }

    @Test("a fluent paraphrase that keeps too little is rejected")
    func rejectsParaphrase() {
        let raw = "we always took our dude wives with us cause that toilet paper is one ply"
        #expect(verdict(raw, "The camping trip was memorable for everyone.") == .reject(.driftedTooFar))
    }

    @Test("an empty rewrite is rejected")
    func rejectsEmpty() {
        #expect(verdict("some words here that are real", "") == .reject(.empty))
        #expect(verdict("some words here that are real", "   ") == .reject(.empty))
    }

    /// There is nothing to clean in four words, and one substituted word is a
    /// large fraction of the meaning.
    @Test("a very short transcript is left alone")
    func skipsShortText() {
        #expect(verdict("Can you hear me", "Can you hear me?") == .reject(.tooShortToBother))
    }

    @Test("a rewrite identical to the original is reported as unchanged")
    func reportsUnchanged() {
        let raw = "This sentence was already perfectly fine."
        #expect(verdict(raw, raw) == .reject(.unchanged))
    }

    // MARK: - Pieces

    @Test("retention counts repeated words once each")
    func overlapIsAMultiset() {
        #expect(CleanupGuard.overlap(["the", "the", "cat"], ["the", "cat"]) == 2)
        #expect(CleanupGuard.overlap(["the", "the"], ["the", "the", "the"]) == 2)
        #expect(CleanupGuard.overlap([], ["a"]) == 0)
    }

    @Test("questions are recognised by mark or by opening word")
    func detectsQuestions() {
        #expect(CleanupGuard.startsInterrogatively("what time is it"))
        #expect(CleanupGuard.startsInterrogatively("Can you hear me"))
        #expect(!CleanupGuard.startsInterrogatively("the meeting is at three"))
        // A statement never triggers the answer check, whatever it is rewritten to.
        #expect(!CleanupGuard.readsAsAnAnswer(raw: "we went home", rewritten: "We went home."))
    }

    /// Growth is bounded relative to length, so a long transcript may gain a few
    /// words of punctuation and a short one may not gain a paragraph.
    @Test("the growth ceiling scales with the input")
    func growthScales() {
        let short = "one two three four five six"
        #expect(verdict(short, "One two three four five six seven eight nine ten.") == .reject(.grew))
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let slightlyLonger = long + " word word"
        #expect(verdict(long, slightlyLonger) != .reject(.grew))
    }
}

@Suite("Cleanup policy")
struct CleanupPolicyTests {

    /// The guard that matters most: text going into a terminal or an editor is a
    /// command, a path or a snippet, and its value is in being exactly what was
    /// said. This is not a preference — it is why the list exists.
    @Test(
        "cleanup never runs where text must be verbatim",
        arguments: [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
            "com.microsoft.VSCode", "com.1password.1password",
        ])
    func excludesVerbatimApps(bundleID: String) {
        var policy = CleanupPolicy.default
        policy.enabled = true
        #expect(!policy.allows(bundleID: bundleID))
    }

    @Test("bundle identifiers match regardless of case")
    func matchingIsCaseInsensitive() {
        var policy = CleanupPolicy.default
        policy.enabled = true
        #expect(!policy.allows(bundleID: "COM.APPLE.TERMINAL"))
        #expect(!policy.allows(bundleID: "com.apple.terminal"))
    }

    @Test("ordinary apps are allowed")
    func allowsOrdinaryApps() {
        var policy = CleanupPolicy.default
        policy.enabled = true
        for bundleID in ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.Notes", nil] {
            #expect(policy.allows(bundleID: bundleID), "blocked \(bundleID ?? "nil")")
        }
    }

    /// Off unless asked for. This feature changes what the user said, which is
    /// not something to opt someone into silently.
    @Test("it is off by default, and the switch beats the list")
    func disabledByDefault() {
        #expect(!CleanupPolicy.default.enabled)
        #expect(!CleanupPolicy.default.allows(bundleID: "com.apple.mail"))
    }

    @Test("the deadline converts to a Duration")
    func deadlineConverts() {
        var policy = CleanupPolicy.default
        policy.deadlineSeconds = 2.5
        #expect(policy.deadline == .milliseconds(2500))
    }

    @Test("the policy round-trips through Codable")
    func codableRoundTrip() throws {
        var policy = CleanupPolicy.default
        policy.enabled = true
        policy.deadlineSeconds = 3
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(CleanupPolicy.self, from: data) == policy)
    }
}

/// Exercises the real engine. Written so it is correct on a machine where Apple
/// Intelligence is off (the raw transcript must survive) *and* on one where it
/// is on (the guard must have been applied).
@Suite("Cleanup engine", .serialized)
struct TranscriptCleanerTests {

    private let messy =
        "But like he was gonna no, we always took our like dude wives with us cause that toilet paper it's like one ply"

    /// The property that matters most, and the one that holds on every machine:
    /// if anything at all prevents a rewrite, the user still gets their words.
    @Test("the raw transcript survives whatever happens")
    func neverLosesTheTranscript() async {
        let cleaner = TranscriptCleaner()
        let outcome = await cleaner.clean(messy, deadline: .milliseconds(1500))

        if outcome.changed {
            // A rewrite only counts as accepted if it passed the guard, so it
            // must still be recognisably the same utterance.
            let verdict = CleanupGuard().check(raw: messy, rewritten: outcome.text)
            #expect(verdict == .accept(outcome.text))
            #expect(outcome.note == nil)
        } else {
            #expect(outcome.text == messy, "an unchanged outcome must return the original")
        }
    }

    @Test("an unavailable model is reported, not hidden")
    func reportsUnavailability() async {
        let availability = TranscriptCleaner.availability()
        if !availability.isReady {
            let outcome = await TranscriptCleaner().clean(messy)
            #expect(!outcome.changed)
            #expect(outcome.text == messy)
            #expect(outcome.note != nil, "a silent no-op is indistinguishable from a broken feature")
            #expect(outcome.note == availability.explanation)
        }
        // Every availability case must have something to show a user.
        #expect(!availability.explanation.isEmpty)
    }

    @Test("empty input is returned untouched without calling the model")
    func skipsEmptyInput() async {
        let outcome = await TranscriptCleaner().clean("   ")
        #expect(outcome.text == "   ")
        #expect(!outcome.changed)
    }

    /// An impossible deadline must fail to the raw text rather than hanging the
    /// paste, on a machine where the model would otherwise have answered.
    @Test("an expired deadline yields the raw transcript")
    func deadlineIsHonoured() async {
        let outcome = await TranscriptCleaner().clean(messy, deadline: .milliseconds(1))
        #expect(outcome.text == messy)
        #expect(!outcome.changed)
    }
}

@Suite("Deterministic pass")
struct CleanupDeterminismTests {

    /// With a deadline, whether the transcript gets cleaned depends on how busy
    /// the machine was — the same sentence comes back polished once and raw the
    /// next time. This switch is what removes wall-clock time from the result.
    @Test("waiting for completion ignores the deadline slider")
    func waitingOverridesTheDeadline() {
        var policy = CleanupPolicy.default
        policy.deadlineSeconds = 0.5
        #expect(policy.deadline == .milliseconds(500))

        policy.waitsForCompletion = true
        #expect(policy.deadline == CleanupPolicy.safetyCeiling)
        // Still bounded: "wait forever" is not a behaviour a paste can have.
        #expect(CleanupPolicy.safetyCeiling < .seconds(120))
    }

    /// A policy written by an earlier build has no `waitsForCompletion` key.
    /// Decoding must fill it in rather than fail, or upgrading would silently
    /// reset every other cleanup setting the user had chosen.
    @Test("a policy stored before this option still decodes")
    func decodesOlderPolicies() throws {
        let old = #"{"enabled":true,"deadlineSeconds":2.5,"excludedBundleIDs":["com.apple.Terminal"]}"#
        let policy = try JSONDecoder().decode(CleanupPolicy.self, from: Data(old.utf8))
        #expect(policy.enabled)
        #expect(policy.deadlineSeconds == 2.5)
        #expect(!policy.waitsForCompletion)
        #expect(policy.excludedBundleIDs == ["com.apple.Terminal"])
    }

    @Test("an empty object decodes to the safe defaults")
    func decodesEmptyObject() throws {
        let policy = try JSONDecoder().decode(CleanupPolicy.self, from: Data("{}".utf8))
        #expect(policy == CleanupPolicy.default)
        #expect(!policy.enabled)
    }
}

@Suite("Interrogatives")
struct InterrogativeTests {

    /// The reason this table was extracted: the two private copies it replaced
    /// had drifted, one listing "am" and the other not — so "am I late" was
    /// punctuated as a question by `TranscriptPolish` and not recognised as one
    /// by `CleanupGuard`. Both stages now answer the same way.
    @Test("both stages agree on what opens a question")
    func stagesAgree() {
        for clause in ["am I late", "can you hear me", "what time is it", "did he go"] {
            #expect(Interrogative.opens(clause), "not a question: \(clause)")
            #expect(CleanupGuard.startsInterrogatively(clause))
            #expect(TranscriptPolish.default.apply(to: clause).hasSuffix("?"))
        }
    }

    @Test("statements are not questions")
    func statementsAreNot() {
        for clause in ["the meeting is at three", "we went home", "I asked what he wanted"] {
            #expect(!Interrogative.opens(clause))
            #expect(TranscriptPolish.default.apply(to: clause).hasSuffix("."))
        }
    }

    @Test("leading punctuation and case do not matter")
    func toleratesNoise() {
        #expect(Interrogative.opens("  \"What time is it"))
        #expect(Interrogative.opens("WHAT"))
        #expect(!Interrogative.opens(""))
        #expect(!Interrogative.opens("   "))
    }

    /// One predicate for what counts as part of a word, because three private
    /// copies disagreed about digits.
    @Test("digits and apostrophes are word characters")
    func wordCharacters() {
        #expect(Character("a").isWordCharacter)
        #expect(Character("7").isWordCharacter)
        #expect(Character("'").isWordCharacter)
        #expect(!Character(" ").isWordCharacter)
        #expect(!Character(",").isWordCharacter)
    }
}
