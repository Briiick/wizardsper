import SwiftUI

/// The live transcript: one line, laid out left to right, each word fading in
/// where it belongs.
///
/// A single `Text` whose string is replaced on every partial changes instantly,
/// which at two or three partials a second reads as flicker. Words are drawn
/// individually so a new one can fade in on its own while the words already on
/// screen stay exactly where they are — nothing slides, nothing reflows.
///
/// Overflow is the part that needs care. Left-aligned with `.truncationMode`
/// tail, the moment speech runs past the pill's width the *new* words are the
/// ones cut off, so the bar freezes on the opening of the sentence and stops
/// reporting what is happening now — the one job a live meter has. So the line
/// is left-aligned while it fits, and only once it would overflow does it scroll
/// to keep the newest word on screen. Short dictations never move at all.
struct TranscriptFlowView: View {

    let text: String
    var color: Color = .primary
    var font: Font = .system(size: 13.5, weight: .medium, design: .rounded)
    /// Placeholders ("Listening…") and outcome summaries are one thing being
    /// said, not speech accumulating, so they cross-fade whole.
    var flowsWordByWord: Bool = true
    var reduceMotion: Bool = false

    @State private var contentWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    /// Index is a stable identity here because greedy RNN-T only ever appends:
    /// an emitted token is never revised, so word *n* stays word *n*. The final
    /// word grows in place as more sub-word pieces arrive, which SwiftUI updates
    /// without a transition — correct, since completing a word is not the same
    /// as starting one.
    private var words: [Word] {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .enumerated()
            .map { Word(id: $0.offset, text: String($0.element)) }
    }

    private struct Word: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Zero until the line is full; negative after that, by exactly the amount
    /// that has run off the end.
    private var scrollOffset: CGFloat {
        min(0, availableWidth - contentWidth)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: text)
    }

    private var flowing: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(words) { word in
                    Text(word.text)
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                        // Opacity only. A word that slides into place draws the
                        // eye to the movement rather than to the word, and with
                        // a partial arriving every few hundred milliseconds that
                        // becomes the most distracting thing on screen.
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                }
            )
            .offset(x: scrollOffset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
        )
        .onPreferenceChange(WidthKey.self) { width in
            contentWidth = width
        }
        // Without this the overflow draws over the level meter and past the
        // capsule's edge.
        .clipped()
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Transcript flow") {
    VStack(alignment: .leading, spacing: 14) {
        TranscriptFlowView(text: "Hello")
        TranscriptFlowView(text: "Hello, can you hear me")
        TranscriptFlowView(
            text: "But like he was gonna no, we always took our dude wives with us because that")
        TranscriptFlowView(text: "Listening…", color: .secondary, flowsWordByWord: false)
    }
    .frame(width: 360)
    .padding(24)
}
#endif
