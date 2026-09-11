import Foundation
import Observation
import WizardsperKit

/// The single source of truth the flow bar renders.
///
/// Everything the pill shows lives here and nowhere else: the coordinator pushes
/// session state in, the audio layer is sampled for level, and SwiftUI observes
/// the result. Without it the view would have to reach into the capture engine
/// and the session coordinator itself, from a body that can be re-evaluated at
/// any moment — which is exactly how a dictation UI ends up holding a reference
/// to a live audio object.
@MainActor
@Observable
final class FlowBarModel {

    var state: SessionState

    /// The live hypothesis. Replaced wholesale on every partial, never appended:
    /// the recogniser re-emits the whole utterance each time, so appending would
    /// duplicate every word already on screen.
    var transcript: String

    /// 0...1 RMS of the microphone. Written by the display timer below, not by
    /// whoever measured it — see `sampleInterval`.
    var level: Float

    /// Set once per session, and the bar does not dismiss until it is non-nil.
    var outcome: SessionOutcome?

    /// Reads the current level from the audio layer. Stored rather than observed
    /// so that polling it never registers a dependency with SwiftUI.
    @ObservationIgnored
    private var levelSource: (@MainActor () -> Float)?

    @ObservationIgnored
    private var displayTimer: Timer?

    /// One redraw per display frame.
    ///
    /// The capture callback updates its level box roughly ninety times a second
    /// — once per audio buffer — and that rate has nothing to do with the screen.
    /// Feeding every update into an `@Observable` property would invalidate the
    /// view far more often than it can possibly be drawn; the extra
    /// invalidations are pure waste, since at best SwiftUI coalesces them after
    /// having already been woken. Polling on a timer inverts the flow: the view
    /// is invalidated at most once per frame, and the audio thread never touches
    /// the main actor at all.
    private static let sampleInterval: TimeInterval = 1.0 / 60.0

    /// `@Observable` notifies on every write, not only on every change, so
    /// republishing an unchanged level would still cost a redraw. Movement
    /// smaller than this is not visible in a 20-point bar anyway.
    private static let levelEpsilon: Float = 0.002

    init(
        state: SessionState = .idle,
        transcript: String = "",
        level: Float = 0,
        outcome: SessionOutcome? = nil
    ) {
        self.state = state
        self.transcript = transcript
        self.level = level
        self.outcome = outcome
    }

    // MARK: - Wiring

    /// Point the meter at whatever is measuring the microphone.
    ///
    /// A closure rather than a reference keeps WizardsperApp out of the audio
    /// internals: the app delegate hands over one read of the capture layer's
    /// level box, and this object never learns what is behind it.
    func attach(levelSource: @escaping @MainActor () -> Float) {
        self.levelSource = levelSource
    }

    /// Adopt a snapshot published by the session coordinator.
    ///
    /// Each field is compared before it is written, because an unchanged write
    /// still invalidates the view. `level` is deliberately not taken from the
    /// snapshot while a level source is attached: snapshots arrive whenever the
    /// coordinator has news, and letting them drive the meter would put the
    /// redraw rate back under the audio layer's control.
    func apply(_ snapshot: SessionSnapshot) {
        if state != snapshot.state { state = snapshot.state }
        if transcript != snapshot.transcript { transcript = snapshot.transcript }
        if outcome != snapshot.outcome { outcome = snapshot.outcome }
        if levelSource == nil, abs(level - snapshot.level) > Self.levelEpsilon {
            level = snapshot.level
        }
    }

    /// Clear the previous session before the bar comes back on screen, so a
    /// stale transcript or outcome can never flash in the new pill.
    func beginSession() {
        state = .listening
        transcript = ""
        outcome = nil
        level = 0
    }

    /// Publish the terminal outcome. The bar keeps showing it until the panel's
    /// delayed dismissal fires.
    func finish(_ outcome: SessionOutcome) {
        self.outcome = outcome
        state = .idle
        level = 0
    }

    // MARK: - Display timer

    /// Started when the bar is shown and stopped when it is gone: an idle bar
    /// has nothing to redraw, and a 60 Hz timer running against a hidden window
    /// would keep the CPU awake for the whole time Wizardsper sits in the menu bar.
    func startSampling() {
        guard displayTimer == nil else { return }

        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] timer in
            guard let self else {
                // The model was released while the timer was still armed. Take
                // it off the run loop rather than leaving it to fire sixty times
                // a second against nothing. Handled out here, not inside
                // `assumeIsolated`: `Timer` is not Sendable, so capturing it in
                // the isolated closure is a data-race error even though this
                // block only ever runs on the main thread.
                timer.invalidate()
                return
            }
            // Scheduled on the main run loop below, so this block runs on the
            // main thread and the model is safe to touch here.
            MainActor.assumeIsolated { self.sample() }
        }

        // `.common`, not the default mode: a tracking run loop — a menu opened,
        // a window being resized — would otherwise freeze the meter mid-session.
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stopSampling() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    var isSampling: Bool { displayTimer != nil }

    private func sample() {
        guard let levelSource else { return }
        let next = min(max(levelSource(), 0), 1)
        if abs(next - level) > Self.levelEpsilon {
            level = next
        }
    }
}
