import SwiftUI

/// The live transcript: words laid out left to right, wrapping onto new lines,
/// each fading in where it belongs.
///
/// Three things this has to get right, and each was wrong at some point:
///
/// **Words must not slide.** A word that moves into place draws the eye to the
/// movement rather than to the word, and with a partial arriving every few
/// hundred milliseconds that becomes the most distracting thing on screen. New
/// words fade in; words already placed do not move.
///
/// **The text must not escape its box.** The obvious construction — a stack of
/// `fixedSize()` words with `.frame(maxWidth: .infinity)` and `.clipped()` —
/// fails silently: the stack *grows to fit* its oversized child, so any width
/// measured off it is the content's width, the offset computes to zero, and the
/// clip applies to a frame already wider than the pill. Long sentences then draw
/// straight out through the capsule. Widths here come from `Layout`, which is
/// told the real proposal, never from a container free to grow.
///
/// **It has to hold a long thought.** A single line is fine for "yes" and
/// useless for twenty seconds of speech, which is what people actually dictate.
/// The box grows downwards a line at a time up to `maxLines`, and past that it
/// scrolls so the newest line stays visible — the one thing a live meter has to
/// do.
struct TranscriptFlowView: View {

    let text: String
    var color: Color = .primary
    var font: Font = .system(size: 13.5, weight: .medium, design: .rounded)
    /// The width the text is laid out in. Fixed, not measured.
    ///
    /// It used to hug the content, and that was a feedback loop: once the text
    /// wraps, the layout reports the width of the widest *line*, which is
    /// bounded by the box it was given — so a box derived from that measurement
    /// could never grow past wherever it first settled, and the transcript
    /// wrapped far earlier than it needed to. Height is the only axis that can
    /// safely follow the content, because nothing about the line breaking
    /// depends on it.
    var width: CGFloat = 420
    /// How tall the box may grow before it starts scrolling instead.
    var maxLines: Int = 5
    /// Placeholders ("Listening…") and outcome summaries are one thing being
    /// said, not speech accumulating, so they cross-fade whole.
    var flowsWordByWord: Bool = true
    var reduceMotion: Bool = false
    /// Reports the laid-out height so the pill can grow with it.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @State private var contentHeight: CGFloat = 0

    private static let lineHeight: CGFloat = 18
    private static let lineSpacing: CGFloat = 3
    private static let wordSpacing: CGFloat = 4
    /// Length of the dissolve at an overflowing edge.
    private static let fade: CGFloat = 14

    /// Index is a stable identity because greedy RNN-T only ever appends: an
    /// emitted token is never revised, so word *n* stays word *n*. The final word
    /// grows in place as more sub-word pieces arrive, which SwiftUI updates
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

    private struct SizeKey: PreferenceKey {
        static let defaultValue = CGSize.zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
        }
    }

    /// Room for `maxLines` before scrolling begins.
    private var maxHeight: CGFloat {
        CGFloat(maxLines) * Self.lineHeight + CGFloat(maxLines - 1) * Self.lineSpacing
    }

    /// As tall as the text needs, up to `maxLines`.
    private var boxHeight: CGFloat {
        min(max(contentHeight, Self.lineHeight), maxHeight)
    }

    /// Zero until the text is taller than the box; after that, exactly the
    /// amount that has scrolled off the top.
    private var scroll: CGFloat { min(0, boxHeight - contentHeight) }

    var body: some View {
        content
            // Measured here, outside the branch, so the placeholder and the
            // outcome summary report their height too. Measuring only inside the
            // word-flow branch left the box holding the *previous* session's
            // height: a new press shows "Listening…", which is one line, but
            // nothing reported that until the first word of speech arrived — so
            // the pill stayed as tall as the last thing dictated.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SizeKey.self, value: proxy.size)
                }
            )
            .offset(y: scroll)
            // The hard clamp. `offset` moves pixels without changing layout, so
            // the frame has to be pinned before the mask has anything correct to
            // mask.
            .frame(width: width, height: boxHeight, alignment: .topLeading)
            .mask(topFade)
            .onPreferenceChange(SizeKey.self) { size in
                contentHeight = size.height
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: boxHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: text)
            .onChange(of: boxHeight, initial: true) { _, height in onHeightChange(height) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if flowsWordByWord && !words.isEmpty {
            WordFlowLayout(spacing: Self.wordSpacing, lineSpacing: Self.lineSpacing) {
                ForEach(words) { word in
                    Text(word.text)
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                        // Opacity only, for the reason in the type comment.
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            // The layout is told the real width to break lines against;
            // measuring it afterwards would be measuring the answer, not the
            // question.
            .frame(width: width, alignment: .topLeading)
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, height: Self.lineHeight, alignment: .leading)
                .transition(.opacity)
        }
    }

    /// Dissolve the top edge once lines have scrolled off it, so the oldest line
    /// fades into the capsule instead of being sliced through the middle.
    private var topFade: some View {
        let fading = scroll < -0.5
        let total = max(boxHeight, 1)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(fading ? 0 : 1), location: 0),
                .init(color: .black, location: fading ? Self.fade / total : 0),
                .init(color: .black, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }
}

#if DEBUG
#Preview("Transcript flow") {
    VStack(alignment: .leading, spacing: 14) {
        TranscriptFlowView(text: "Hello")
        TranscriptFlowView(text: "Hello, can you hear me now")
        TranscriptFlowView(
            text:
                "Because also it keeps so if I oh yeah oh maybe I would buy it from you yeah let me know but so the answer your question"
        )
        TranscriptFlowView(text: "Listening…", color: .secondary, flowsWordByWord: false)
            .border(.red.opacity(0.2))
    }
    .padding(24)
    .background(.quaternary)
}
#endif
