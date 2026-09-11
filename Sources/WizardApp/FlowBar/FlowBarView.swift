import SwiftUI
import WizardKit

/// Geometry shared by the SwiftUI content and the panel that hosts it.
///
/// The panel is sized from these numbers, so they have to live where both sides
/// can see them. The pill's width is fixed rather than fitted to its text: a
/// width that tracked the transcript would re-measure and shuffle the pill
/// sideways on every partial — twenty times a second, under the user's eyes —
/// which is the one thing a dictation HUD must never do.
enum FlowBarMetrics {
    /// Constant. The pill only changes height.
    static let pillWidth: CGFloat = 520
    /// Room the transcript gets, once the meter and the padding are accounted
    /// for. This is the width lines are broken against.
    static var transcriptWidth: CGFloat {
        pillWidth - horizontalPadding * 2 - LevelBarsView.clusterWidth - contentSpacing
    }
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 13
    /// Height of a single line of transcript, for deciding capsule vs rectangle.
    static let singleLineHeight: CGFloat = 18
    static let contentSpacing: CGFloat = 12
    /// One line of transcript. The pill grows from here, a line at a time.
    static let pillMinHeight: CGFloat = 44
    /// Five lines. Past this the transcript scrolls inside the pill rather than
    /// the pill continuing to grow: a panel that kept expanding would eventually
    /// cover the thing the user is dictating into.
    static let pillMaxHeight: CGFloat = 44 + 4 * 21
    static let maxLines = 5
    /// Transparent margin around the pill inside the window. The window clips
    /// its content, so the shadow and the fade need somewhere to live.
    static let margin: CGFloat = 14
    static var panelWidth: CGFloat { pillWidth + margin * 2 }
    /// Sized for the tallest the pill can get. The window cannot resize while
    /// it is on screen without the compositor flickering, so it is allocated at
    /// maximum and the pill grows inside it.
    static var panelHeight: CGFloat { pillMaxHeight + margin * 2 }
    /// Gap between the bottom of the window and the top of the Dock.
    static let bottomInset: CGFloat = 8

    /// Wizard's own colour, rather than `.accentColor`.
    ///
    /// The system accent is whatever the user picked for their desktop, so the
    /// meter changed colour from machine to machine and could land on the same
    /// green the gain meter uses for "signal is healthy" — two different
    /// meanings, one colour. A fixed hue keeps the pill recognisable and leaves
    /// green free to mean only that.
    static let tint = Color(
        light: Color(red: 0.93, green: 0.49, blue: 0.13),
        dark: Color(red: 1.0, green: 0.62, blue: 0.25))
}

/// The pill itself: level on the left, the live transcript on the right.
///
/// It renders `FlowBarModel` and nothing else. Every state the bar can be in —
/// listening, transcribing, finished, failed — is a function of that one object,
/// so there is no way for the window to be showing something the model does not
/// say.
struct FlowBarView: View {

    let model: FlowBarModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transcriptHeight: CGFloat = 0

    /// A capsule while it is one line; a rounded rectangle once it wraps. A
    /// capsule several lines tall has semicircular ends taller than the text and
    /// reads as a lozenge rather than as a panel.
    private var shape: AnyInsettableShape {
        transcriptHeight > FlowBarMetrics.singleLineHeight + 1
            ? AnyInsettableShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            : AnyInsettableShape(Capsule(style: .continuous))
    }

    var body: some View {
        HStack(alignment: .center, spacing: FlowBarMetrics.contentSpacing) {
            leading
            TranscriptFlowView(
                text: displayText,
                color: textColor,
                width: FlowBarMetrics.transcriptWidth,
                maxLines: FlowBarMetrics.maxLines,
                // Speech flows in word by word; a placeholder or an outcome
                // summary is one thing being said, so it cross-fades whole.
                flowsWordByWord: model.outcome == nil && !model.transcript.isEmpty,
                reduceMotion: reduceMotion,
                onHeightChange: { transcriptHeight = $0 })
        }
        .padding(.horizontal, FlowBarMetrics.horizontalPadding)
        .padding(.vertical, FlowBarMetrics.verticalPadding)
        // Width fixed, height intrinsic: the pill is always the same width and
        // grows downwards a line at a time until `pillMaxHeight`, after which
        // the transcript scrolls inside it.
        .frame(width: FlowBarMetrics.pillWidth, height: nil)
        .frame(minHeight: FlowBarMetrics.pillMinHeight)
        // `background(_:in:)`, not `background { shape.fill(material) }`.
        //
        // They look like the same thing and are not. This form renders the
        // material as a true backdrop, sampling and blurring what is behind the
        // window; filling a shape with it treats the material as an ordinary
        // fill style, which loses the vibrancy and comes out flat grey. The pill
        // went visibly lifeless when this was a fill, and nothing else about it
        // had changed.
        .background(.ultraThinMaterial, in: shape)
        .overlay { shape.strokeBorder(borderStyle, lineWidth: 1) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.outcome)
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: transcriptHeight)
        // Bottom-aligned in a window sized for the tallest pill, so growing a
        // line pushes the top edge up and leaves the bottom where the user's eye
        // already is.
        .frame(
            width: FlowBarMetrics.panelWidth, height: FlowBarMetrics.panelHeight,
            alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(displayText))
    }

    /// The meter while a session is running; its result once there is one. Both
    /// occupy the same width so the transcript does not jump sideways when the
    /// outcome lands.
    @ViewBuilder
    private var leading: some View {
        if let outcome = model.outcome {
            Image(systemName: symbolName(for: outcome))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: LevelBarsView.clusterWidth, height: LevelBarsView.maxBarHeight)
        } else {
            LevelBarsView(level: model.level, tint: accentColor)
        }
    }

    /// The outcome wins over the transcript: once a session has ended, what
    /// happened to the text matters more than the text.
    private var displayText: String {
        if let outcome = model.outcome { return outcome.summary }
        if !model.transcript.isEmpty { return model.transcript }
        switch model.state {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .finishing: return "Transcribing…"
        }
    }

    /// Red is reserved for failure. A session that simply heard nothing is not
    /// an error, and colouring it like one trains the user to ignore the colour.
    private var isFailure: Bool { model.outcome?.isFailure == true }

    private var accentColor: Color { isFailure ? .red : FlowBarMetrics.tint }

    private var textColor: Color {
        if isFailure { return .red }
        // Placeholders are quieter than speech the user actually said.
        return model.transcript.isEmpty && model.outcome == nil ? .secondary : .primary
    }

    /// A hairline that catches the light at the top, as system HUDs do.
    /// Built from `.primary` so it inverts with the appearance instead of being
    /// a white line that disappears on a light desktop.
    private var borderStyle: LinearGradient {
        let top = isFailure ? Color.red.opacity(0.45) : Color.primary.opacity(0.22)
        let bottom = isFailure ? Color.red.opacity(0.15) : Color.primary.opacity(0.06)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func symbolName(for outcome: SessionOutcome) -> String {
        switch outcome {
        case .pasted: return "checkmark"
        case .copied: return "doc.on.clipboard"
        case .nothing: return "mic.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

#if DEBUG
#Preview("Listening") {
    FlowBarView(
        model: FlowBarModel(
            state: .listening,
            transcript: "the quick brown fox jumps over the lazy dog and keeps on running",
            level: 0.18)
    )
    .padding(24)
}

#Preview("Waiting for speech") {
    FlowBarView(model: FlowBarModel(state: .listening, level: 0.004))
        .padding(24)
}

#Preview("Pasted") {
    FlowBarView(model: FlowBarModel(state: .idle, outcome: .pasted("hello")))
        .padding(24)
}

#Preview("Failed") {
    FlowBarView(model: FlowBarModel(state: .idle, outcome: .failed(.microphoneDenied)))
        .padding(24)
}
#endif
