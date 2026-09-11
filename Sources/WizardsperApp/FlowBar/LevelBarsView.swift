import Foundation
import SwiftUI

/// The animated level meter on the left of the pill.
///
/// It exists to answer one question the transcript cannot answer fast enough:
/// "is Wizardsper hearing me right now?" Speech recognition has a latency the meter
/// does not, so a user who has muted the wrong device finds out immediately
/// instead of after a silent session. Five bars rather than one, because a
/// single bar reads as a progress indicator — something that is filling up —
/// while a cluster reads as sound.
struct LevelBarsView: View {

    /// Raw RMS from the capture layer, 0...1.
    let level: Float
    var tint: Color = FlowBarMetrics.tint

    /// Reduce Motion turns the spring into a plain value change: the heights
    /// still track the voice, they just stop overshooting on the way.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // `nonisolated` on all of these: `View` carries main-actor isolation, so a
    // computed static on one is main-actor bound — and `FlowBarMetrics`, which is
    // a plain nonisolated enum of numbers, has to read `clusterWidth` to size the
    // pill. The newest Swift infers its way around this and an older one does
    // not, so the isolation is stated rather than left to the compiler's mood.
    // They are all constants; there is nothing here to protect.
    nonisolated static let barCount = 5
    nonisolated static let barWidth: CGFloat = 3.5
    nonisolated static let barSpacing: CGFloat = 3
    nonisolated static let maxBarHeight: CGFloat = 20
    /// A bar is never fully gone: five stubs in silence still read as a meter
    /// that is listening, where an empty row reads as a broken layout.
    nonisolated static let minBarHeight: CGFloat = 3.5

    /// Fixed, so the transcript beside it never shifts as the bars move.
    nonisolated static var clusterWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: Self.barWidth, height: Self.barHeight(index: index, level: level))
                    // Per-bar rather than one animation over the cluster: the
                    // outer bars lag the centre by a few milliseconds, which
                    // reads as a ripple travelling outwards. It is the only
                    // source of independent motion left, and because it is a
                    // fixed delay rather than a level-dependent phase it can
                    // never make the bars disagree about how loud the room is.
                    .animation(Self.motion(index: index, reduceMotion: reduceMotion), value: level)
            }
        }
        .frame(width: Self.clusterWidth, height: Self.maxBarHeight)
        // Flattens the five animating bars into one Metal layer, so a level
        // change costs a single composited redraw instead of five.
        .drawingGroup()
        .accessibilityHidden(true)
    }

    /// A fixed weight per bar: tallest in the middle, tapering outwards.
    ///
    /// This used to be a sine whose *phase* was a function of the level, which
    /// is what made the cluster jitter. Every change in loudness moved each bar
    /// a different direction by a different amount, so the meter shimmered
    /// against itself instead of rising and falling as one thing. The shape a
    /// cluster needs is static; only its size should follow the voice.
    private static let profile: [Double] = [0.52, 0.80, 1.0, 0.80, 0.52]

    /// Height of one bar for a given level.
    static func barHeight(index: Int, level: Float) -> CGFloat {
        let loudness = normalized(level)
        let weight = profile[min(index, profile.count - 1)]
        return max(minBarHeight, CGFloat(loudness * weight) * maxBarHeight)
    }

    /// Critically damped, and a touch slower towards the edges.
    ///
    /// `dampingFraction` is 1 rather than the 0.68 this had before: under-damped
    /// springs overshoot, and five bars overshooting out of step is most of what
    /// made the meter look nervous.
    static func motion(index: Int, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let distanceFromCentre = abs(index - barCount / 2)
        return .spring(response: 0.22, dampingFraction: 1.0)
            .delay(Double(distanceFromCentre) * 0.018)
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
