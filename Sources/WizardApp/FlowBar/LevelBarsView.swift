import Foundation
import SwiftUI

/// The animated level meter on the left of the pill.
///
/// It exists to answer one question the transcript cannot answer fast enough:
/// "is Wizard hearing me right now?" Speech recognition has a latency the meter
/// does not, so a user who has muted the wrong device finds out immediately
/// instead of after a silent session. Five bars rather than one, because a
/// single bar reads as a progress indicator — something that is filling up —
/// while a cluster reads as sound.
struct LevelBarsView: View {

    /// Raw RMS from the capture layer, 0...1.
    let level: Float
    var tint: Color = .accentColor

    /// Reduce Motion turns the spring into a plain value change: the heights
    /// still track the voice, they just stop overshooting on the way.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barCount = 5
    static let barWidth: CGFloat = 3.5
    static let barSpacing: CGFloat = 3
    static let maxBarHeight: CGFloat = 20
    /// A bar is never fully gone: five stubs in silence still read as a meter
    /// that is listening, where an empty row reads as a broken layout.
    static let minBarHeight: CGFloat = 3.5

    /// Fixed, so the transcript beside it never shifts as the bars move.
    static var clusterWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: Self.barWidth, height: Self.barHeight(index: index, level: level))
            }
        }
        .frame(width: Self.clusterWidth, height: Self.maxBarHeight)
        .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.68), value: level)
        // Flattens the five animating bars into one Metal layer, so a level
        // change costs a single composited redraw instead of five.
        .drawingGroup()
        .accessibilityHidden(true)
    }

    /// Height of one bar for a given level.
    ///
    /// Each bar samples the same level a little further along a sine, so the
    /// cluster reads as a wave passing through it rather than five copies of one
    /// meter. The offset is deliberately small: large offsets make the bars look
    /// like they are measuring different things.
    static func barHeight(index: Int, level: Float) -> CGFloat {
        let loudness = normalized(level)
        let phase = Double(index) * 0.7
        let wobble = 0.78 + 0.22 * sin(loudness * 6.0 + phase)
        return max(minBarHeight, CGFloat(loudness * wobble) * maxBarHeight)
    }

    /// Maps RMS onto 0...1 the way an ear would.
    ///
    /// Linear RMS for ordinary speech sits around 0.01–0.3, so drawing it
    /// directly leaves the bars twitching along the floor and pinned only by
    /// shouting. Decibels spread that same range across the whole meter.
    static func normalized(_ level: Float) -> Double {
        let floorDB = -55.0
        let ceilingDB = -8.0
        // The epsilon keeps log10 away from negative infinity on digital silence.
        let decibels = 20.0 * log10(Double(max(level, 0)) + 1e-6)
        return min(max((decibels - floorDB) / (ceilingDB - floorDB), 0), 1)
    }
}

#if DEBUG
#Preview("Level bars") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach([0.0, 0.01, 0.05, 0.15, 0.4, 1.0], id: \.self) { level in
            LevelBarsView(level: Float(level))
        }
    }
    .padding(24)
}
#endif
