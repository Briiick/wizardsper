import SwiftUI

/// Lays words out left to right and wraps them onto new lines.
///
/// A plain `Text` wraps perfectly well, but it is one view: there is no way to
/// fade in a single word of it, because SwiftUI has nothing to transition. The
/// transcript needs both — words that arrive individually *and* a line that
/// wraps — so the words stay separate views and this supplies the wrapping that
/// an `HStack` cannot.
///
/// `Layout` rather than a hand-rolled `VStack` of rows: the line breaks depend on
/// the measured width of every word, which is only known during layout. Deciding
/// them in the view body would need a measurement pass first, and that pass
/// would run on every partial.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    struct Cache {
        var lines: [[Int]] = []
        var lineHeights: [CGFloat] = []
        var size: CGSize = .zero
        var width: CGFloat = -1
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .infinity
        recomputeIfNeeded(width: width, subviews: subviews, cache: &cache)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        recomputeIfNeeded(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (lineIndex, line) in cache.lines.enumerated() {
            var x = bounds.minX
            let height = cache.lineHeights[lineIndex]
            for index in line {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }

    /// Line breaking is pure in the width, so it is only redone when the width
    /// changes — not on every partial, which would be once or twice a second.
    private func recomputeIfNeeded(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width || cache.lines.count != lineCount(cache) else { return }
        var lines: [[Int]] = []
        var heights: [CGFloat] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var widest: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : currentWidth + spacing + size.width
            // A single word wider than the line still gets its own line rather
            // than being dropped; it will be clipped by the caller.
            if !current.isEmpty && needed > width {
                lines.append(current)
                heights.append(currentHeight)
                widest = max(widest, currentWidth)
                current = [index]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                current.append(index)
                currentWidth = needed
                currentHeight = max(currentHeight, size.height)
            }
        }
        if !current.isEmpty {
            lines.append(current)
            heights.append(currentHeight)
            widest = max(widest, currentWidth)
        }

        let totalHeight =
            heights.reduce(0, +) + max(0, CGFloat(heights.count - 1)) * lineSpacing
        cache.lines = lines
        cache.lineHeights = heights
        cache.width = width
        cache.size = CGSize(
            width: width.isFinite ? min(widest, width) : widest,
            height: totalHeight)
    }

    private func lineCount(_ cache: Cache) -> Int { cache.lines.count }
}
