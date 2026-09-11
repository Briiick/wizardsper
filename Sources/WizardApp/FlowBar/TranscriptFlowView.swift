import SwiftUI

/// The live transcript, one line, with new words arriving rather than appearing.
///
/// A single `Text` whose string is replaced on every partial has two problems.
/// The visible one is that it changes instantly — the line simply becomes
/// different, which at the two-or-three-words-per-second a partial arrives reads
/// as flicker. The invisible one is worse: left-aligned with tail truncation,
/// the moment speech runs past the pill's width the *new* words are the ones cut
/// off, so the bar freezes on the opening of the sentence and stops showing the
/// user anything about what is happening now.
///
/// So the line is anchored to its trailing edge instead. It grows leftwards out
/// of view, the way a teleprompter does, and each new word fades and slides in
/// at the right. Older words are still there — they simply scroll off — which
/// keeps the one thing a live meter has to do: show the most recent thing heard.
struct TranscriptFlowView: View {

    let text: String
    var color: Color = .primary
    var font: Font = .system(size: 13.5, weight: .medium, design: .rounded)
    /// Placeholders ("Listening…") and outcome summaries are single units, not
    /// speech, and should cross-fade whole rather than assemble word by word.
    var flowsWordByWord: Bool = true
    var reduceMotion: Bool = false

    /// Split once per render. Index is a stable identity here because greedy
    /// RNN-T only ever appends: a token that has been emitted is never revised,
    /// so word *n* stays word *n*. The final word may grow as more sub-word
    /// pieces arrive, and SwiftUI updates that one in place — which is exactly
    /// the right behaviour, since a word being completed is not a new word.
    private var words: [Word] {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .enumerated()
            .map { Word(id: $0.offset, text: String($0.element)) }
    }

    private struct Word: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var body: some View {
        Group {
            if flowsWordByWord && !words.isEmpty {
                flowing
            } else {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: text)
    }

    private var flowing: some View {
        // `fixedSize` lets the row take its natural width and overflow; the
        // leading `Spacer` pins that overflow to the left, so the trailing edge
        // — the newest word — is the part that always stays on screen.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(words) { word in
                    Text(word.text)
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                        .transition(wordTransition)
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Without this the overflowing words draw over the level meter and past
        // the capsule's edge.
        .clipped()
        .accessibilityHidden(true)
    }

    /// In on the right, out on the left — the direction the line is travelling.
    /// Removal matters even though words are never deleted mid-session: the
    /// whole row is torn down when a session ends, and an unmatched removal
    /// would pop rather than fade.
    private var wordTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .offset(x: 14).combined(with: .opacity),
            removal: .opacity)
    }
}

#if DEBUG
#Preview("Transcript flow") {
    VStack(alignment: .leading, spacing: 14) {
        TranscriptFlowView(text: "Hello")
        TranscriptFlowView(text: "Hello, can you hear me")
        TranscriptFlowView(
            text: "But like he was gonna no, we always took our dude wives with us")
        TranscriptFlowView(text: "Listening…", color: .secondary, flowsWordByWord: false)
    }
    .frame(width: 360)
    .padding(24)
}
#endif
