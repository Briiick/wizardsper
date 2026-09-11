import SwiftUI

/// The live transcript: one line, laid out left to right, each word fading in
/// where it belongs, in a box that is only as wide as it needs to be.
///
/// Three things this has to get right, and each of them was wrong at some point:
///
/// **Words must not slide.** A word that moves into place draws the eye to the
/// movement rather than to the word, and with a partial arriving every few
/// hundred milliseconds that becomes the most distracting thing on screen. New
/// words fade in; words already on screen do not move.
///
/// **The line must not escape its box.** The obvious construction — an `HStack`
/// holding a `fixedSize()` row, with `.frame(maxWidth: .infinity)` and
/// `.clipped()` — fails silently: the stack *grows to fit* its oversized child,
/// so any width measured off it is the content's width, the scroll offset
/// computes to zero, and the clip is applied to a frame already wider than the
/// pill. Long sentences then draw straight out through the capsule. The width
/// here is therefore derived from the measured content and an explicit maximum,
/// never from a container that is free to grow.
///
/// **Overflow must look deliberate.** Once the line is longer than the box it
/// has to scroll, and a hard clip slices glyphs down the middle at both ends.
/// The edges are masked with a short gradient instead, so text dissolves into
/// the capsule rather than hitting a wall — and only on the side that is
/// actually overflowing.
struct TranscriptFlowView: View {

    let text: String
    var color: Color = .primary
    var font: Font = .system(size: 13.5, weight: .medium, design: .rounded)
    /// The widest the line may become. Past this it scrolls.
    var maxWidth: CGFloat = 420
    /// Keeps the pill from collapsing to nothing on "Hi" and snapping wider on
    /// the next word.
    var minWidth: CGFloat = 120
    /// Placeholders ("Listening…") and outcome summaries are one thing being
    /// said, not speech accumulating, so they cross-fade whole.
    var flowsWordByWord: Bool = true
    var reduceMotion: Bool = false

    @State private var contentWidth: CGFloat = 0

    /// Length of the dissolve at an overflowing edge.
    private static let fade: CGFloat = 18
    private static let lineHeight: CGFloat = 20

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

    /// What the box actually measures: the content, clamped both ways.
    private var boxWidth: CGFloat {
        min(max(contentWidth, minWidth), maxWidth)
    }

    /// Zero until the line fills the box; after that, exactly the amount that
    /// has run off the end.
    private var offset: CGFloat {
        min(0, boxWidth - contentWidth)
    }

    private var overflowsLeading: Bool { offset < -0.5 }
    private var overflowsTrailing: Bool { contentWidth > boxWidth + 0.5 }

    var body: some View {
        content
            .frame(width: boxWidth, height: Self.lineHeight, alignment: .leading)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: boxWidth)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: text)
    }

    @ViewBuilder
    private var content: some View {
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

    private var flowing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(words) { word in
                Text(word.text)
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize()
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
            }
        )
        .offset(x: offset)
        // The hard clamp. `offset` moves pixels without changing layout, so the
        // frame has to be pinned explicitly before the mask has anything correct
        // to mask.
        .frame(width: boxWidth, height: Self.lineHeight, alignment: .leading)
        .mask(edgeMask)
        .onPreferenceChange(WidthKey.self) { width in
            contentWidth = width
        }
        .accessibilityHidden(true)
    }

    /// Opaque across the middle, dissolving only at an edge that is actually
    /// cut. Fading an edge with nothing beyond it would make a short line look
    /// like it was trailing off when it had simply finished.
    private var edgeMask: some View {
        let leadingFade = overflowsLeading ? Self.fade : 0
        let trailingFade = overflowsTrailing ? Self.fade : 0
        let total = max(boxWidth, 1)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(leadingFade > 0 ? 0 : 1), location: 0),
                .init(color: .black, location: leadingFade / total),
                .init(color: .black, location: 1 - trailingFade / total),
                .init(color: .black.opacity(trailingFade > 0 ? 0 : 1), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

#if DEBUG
#Preview("Transcript flow") {
    VStack(alignment: .leading, spacing: 14) {
        TranscriptFlowView(text: "Hello")
        TranscriptFlowView(text: "Hello, can you hear me now")
        TranscriptFlowView(
            text: "But like he was gonna no, we always took our dude wives with us because that")
        TranscriptFlowView(text: "Listening…", color: .secondary, flowsWordByWord: false)
    }
    .padding(24)
    .background(.quaternary)
}
#endif
