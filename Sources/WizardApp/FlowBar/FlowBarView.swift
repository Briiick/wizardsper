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
    static let pillWidth: CGFloat = 520
    static let pillHeight: CGFloat = 44
    /// Transparent margin around the pill inside the window. The window clips
    /// its content, so the shadow and the fade need somewhere to live.
    static let margin: CGFloat = 14
    static var panelWidth: CGFloat { pillWidth + margin * 2 }
    static var panelHeight: CGFloat { pillHeight + margin * 2 }
    /// Gap between the bottom of the window and the top of the Dock.
    static let bottomInset: CGFloat = 8
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

    var body: some View {
        HStack(spacing: 12) {
            leading
            Text(displayText)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(textColor)
                // One line, truncated: the pill is a glance, not a document. A
                // second line would change the pill's height mid-sentence.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(width: FlowBarMetrics.pillWidth, height: FlowBarMetrics.pillHeight)
        // Material rather than a colour, so the pill reads as macOS chrome in
        // both appearances without naming a single light or dark value.
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(borderStyle, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.outcome)
        // Centres the pill in the window, leaving the margin transparent.
        .frame(width: FlowBarMetrics.panelWidth, height: FlowBarMetrics.panelHeight)
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

    private var accentColor: Color { isFailure ? .red : .accentColor }

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
