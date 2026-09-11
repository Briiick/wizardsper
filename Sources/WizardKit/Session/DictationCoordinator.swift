import Foundation
import Observation

/// Owns exactly one dictation session at a time and drives it from key-down to
/// a single terminal outcome.
///
/// Two invariants hold everything else together:
///
/// 1. **Every async continuation re-checks the session id.** Capture, feeding,
///    finishing and pasting all suspend. By the time any of them resumes the
///    user may have released the key, started another hold, or the model may
///    have been swapped. Each hop compares the id it captured against the live
///    one and returns if they differ, so work from an abandoned session can
///    never write into the current one.
///
/// 2. **Every terminal path publishes exactly one outcome.** `finalize` is the
///    only way out, it is idempotent per session, and the flow bar does not
///    dismiss until it has seen an outcome. A path that returned without
///    publishing would leave the bar on screen forever.
@MainActor
@Observable
public final class DictationCoordinator {

    // MARK: - Observable surface

    public private(set) var snapshot: SessionSnapshot = .idle
    public private(set) var isReady = false
    public private(set) var statusText = "Not loaded"
    public private(set) var activeTier: NemotronTier = .default

    /// Published once per session, after `snapshot` already carries the outcome.
    public var onOutcome: (@MainActor (SessionOutcome) -> Void)?
    /// Fired on every state transition, for the menu-bar icon and the flow bar.
    public var onStateChange: (@MainActor (SessionState) -> Void)?

    // MARK: - Collaborators

    private let ring = AudioRingBuffer()
    private let level = LevelBox()
    private let capture: AudioCapture
    private let settings: Settings
    private let history: TranscriptionHistory

    private var asr: StreamingASR?

    // MARK: - Session state

    private var sessionID: SessionID?
    private var sessionStart: Date?
    private var published = false
    private var drain: Task<Void, Never>?

    /// Whether the chord is physically down right now, which is not the same as
    /// whether a session is running: a press that lands while the previous
    /// session is still finishing is honoured when that session completes,
    /// rather than dropped. Without this, releasing and re-pressing inside the
    /// ~200 ms it takes to paste would silently lose the second hold.
    private var chordIsDown = false

    /// How much audio to hand the recogniser at once. Small enough that a
    /// partial appears promptly, large enough that the actor hop is not the
    /// dominant cost.
    private let feedFrames = 4096

    public init(
        settings: Settings = .shared,
        history: TranscriptionHistory = .shared
    ) {
        self.settings = settings
        self.history = history
        self.capture = AudioCapture(ring: ring, level: level)
        self.activeTier = settings.tier
        self.capture.onFailure = { [weak self] error in
            MainActor.assumeIsolated {
                self?.abort(with: error)
            }
        }
    }

    /// The flow bar polls this at 60 Hz rather than being pushed every buffer.
    public func currentLevel() -> Float { level.poll() }

    // MARK: - Model lifecycle

    /// Load a tier's models. Safe to call again to switch tiers; an in-flight
    /// session is torn down first, because its encoder caches belong to the old
    /// model and are meaningless to the new one.
    public func prepare(tier: NemotronTier, directory: URL) async {
        if sessionID != nil { abort(with: .modelsMissing("model reloaded mid-session")) }
        isReady = false
        activeTier = tier
        statusText = "Loading \(tier.displayName)…"
        do {
            let bundle = try await ModelBundle.load(from: directory)
            let recogniser = try StreamingASR(bundle: bundle, framing: settings.framing)
            // Force CoreML to build its plans now and prove the encoder woke up,
            // so the first real hold is not the thing that discovers a problem.
            try await recogniser.warmUp()
            self.asr = recogniser
            self.isReady = true
            self.statusText = "Ready"
            Log.session.info("Loaded \(tier.rawValue, privacy: .public) ms tier")
        } catch let error as WizardError {
            self.asr = nil
            self.statusText = error.errorDescription ?? "Model failed to load"
            Log.session.error("Model load failed: \(self.statusText, privacy: .public)")
        } catch {
            self.asr = nil
            self.statusText = error.localizedDescription
            Log.session.error("Model load failed: \(self.statusText, privacy: .public)")
        }
    }

    // MARK: - Trigger

    /// The chord went down.
    public func begin() {
        chordIsDown = true
        guard snapshot.state == .idle else {
            // A previous session is still finishing. `finalize` restarts for us
            // once it lands, and only if the chord is still down by then.
            Log.session.debug("Press arrived while finishing; deferring")
            return
        }
        startSession()
    }

    /// The chord came up.
    public func end() {
        chordIsDown = false
        guard snapshot.state == .listening, let id = sessionID else { return }
        transition(to: .finishing)
        capture.stop()
        Task { await complete(id) }
    }

    /// Give up on the current session without a transcript, still publishing an
    /// outcome so nothing downstream is left waiting.
    public func cancel() {
        guard let id = sessionID else { return }
        capture.stop()
        drain?.cancel()
        finalize(.nothing, for: id)
    }

    // MARK: - Session

    private func startSession() {
        guard let asr else {
            // Not a session — there is nothing to publish an outcome for — so
            // this surfaces through statusText rather than through an outcome.
            statusText = "Model is still loading"
            Log.session.notice("Press ignored: no model loaded")
            return
        }
        let id = SessionID()
        sessionID = id
        sessionStart = Date()
        published = false
        snapshot = SessionSnapshot(id: id, state: .listening, transcript: "", level: 0, outcome: nil)
        onStateChange?(.listening)

        ring.reset()
        level.reset()

        drain = Task { [weak self] in
            await self?.pump(id, asr: asr)
        }

        do {
            try capture.start()
            Log.session.info("Session \(id.description, privacy: .public) listening")
        } catch let error as WizardError {
            finalize(.failed(error), for: id)
        } catch {
            finalize(.failed(.audioEngineFailed(error.localizedDescription)), for: id)
        }
    }

    /// Move captured audio into the recogniser for as long as this session owns
    /// the coordinator. Runs on the main actor but never blocks it: every
    /// expensive step is an `await` into the recogniser's own executor.
    private func pump(_ id: SessionID, asr: StreamingASR) async {
        var scratch = [Float](repeating: 0, count: feedFrames)
        while !Task.isCancelled {
            guard sessionID == id else { return }
            let frames = scratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            if frames == 0 {
                // Roughly one capture buffer. Polling rather than signalling
                // keeps the render thread free of any wakeup call.
                try? await Task.sleep(for: .milliseconds(12))
                continue
            }
            let chunk = Array(scratch[0..<frames])
            do {
                let partial = try await asr.feed(chunk)
                guard sessionID == id else { return }
                if let partial { snapshot.transcript = partial }
            } catch let error as WizardError {
                guard sessionID == id else { return }
                finalize(.failed(error), for: id)
                return
            } catch {
                guard sessionID == id else { return }
                finalize(.failed(.audioEngineFailed(error.localizedDescription)), for: id)
                return
            }
        }
    }

    /// Key is up: drain the tail, decide an outcome, publish it.
    private func complete(_ id: SessionID) async {
        // A mismatched id means this session was already finalised by someone
        // else — abort(), cancel(), or a failure in the pump — so returning here
        // does not skip an outcome.
        guard sessionID == id else { return }
        // A live session with no recogniser should be unreachable (prepare() and
        // cleanup both abort the session before clearing it). Finalise rather
        // than return anyway: returning would be the one path that leaves the
        // flow bar waiting on an outcome that never comes.
        guard let asr else {
            finalize(.failed(.modelsMissing("the recogniser went away mid-session")), for: id)
            return
        }
        drain?.cancel()
        drain = nil

        // Whatever the tap wrote between the key coming up and the engine
        // stopping is still in the ring, and it is usually the last word.
        var scratch = [Float](repeating: 0, count: feedFrames)
        while ring.availableToRead > 0 {
            let frames = scratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            guard frames > 0 else { break }
            let chunk = Array(scratch[0..<frames])
            do {
                _ = try await asr.feed(chunk)
            } catch {
                // Stop draining but do not fail the session: whatever was
                // already decoded is still worth delivering, and finish() below
                // will return it. Bailing out to .failed here would throw away a
                // good transcript over a bad final buffer.
                Log.session.notice(
                    "Tail drain stopped early: \(error.localizedDescription, privacy: .public)")
                break
            }
            guard sessionID == id else { return }
        }

        let held = Date().timeIntervalSince(sessionStart ?? Date())
        let dropped = ring.droppedFrames
        if dropped > 0 {
            Log.audio.notice("Session \(id.description, privacy: .public) dropped \(dropped) frames")
        }

        let transcript: String
        do {
            transcript = try await asr.finish()
        } catch let error as WizardError {
            guard sessionID == id else { return }
            finalize(.failed(error), for: id)
            return
        } catch {
            guard sessionID == id else { return }
            finalize(.failed(.audioEngineFailed(error.localizedDescription)), for: id)
            return
        }
        guard sessionID == id else { return }

        // A tap rather than a hold. Treated as "nothing" and not as an error:
        // the user brushed the key, and a transcript of the room tone is worse
        // than silence.
        if held < settings.minimumHoldSeconds {
            Log.session.debug("Hold of \(held, format: .fixed(precision: 3)) s below threshold")
            finalize(.nothing, for: id)
            return
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finalize(.nothing, for: id)
            return
        }

        snapshot.transcript = transcript
        let outcome = await Paster.deliver(
            transcript,
            restorePasteboard: settings.restorePasteboard,
            autoPaste: settings.pasteAutomatically)
        guard sessionID == id else { return }
        finalize(outcome, for: id, duration: held)
    }

    /// Capture died in a way the session cannot survive.
    private func abort(with error: WizardError) {
        capture.stop()
        drain?.cancel()
        guard let id = sessionID else {
            statusText = error.errorDescription ?? "Audio failed"
            return
        }
        finalize(.failed(error), for: id)
    }

    // MARK: - The one exit

    /// The single place a session ends. Idempotent per session id, so a race
    /// between the pump failing and completion landing still yields one outcome.
    private func finalize(_ outcome: SessionOutcome, for id: SessionID, duration: Double = 0) {
        guard sessionID == id, !published else { return }
        published = true

        snapshot.outcome = outcome
        snapshot.state = .finishing
        if let text = outcome.transcript { snapshot.transcript = text }

        if settings.keepHistory,
            let record = TranscriptionRecord(
                outcome: outcome, durationSeconds: duration, tier: activeTier)
        {
            history.append(record)
        }

        switch outcome {
        case .failed(let error):
            let reason = error.errorDescription ?? "unknown"
            Log.session.error(
                "Session \(id.description, privacy: .public) failed: \(reason, privacy: .public)")
        default:
            Log.session.info(
                "Session \(id.description, privacy: .public) → \(outcome.summary, privacy: .public)")
        }

        onOutcome?(outcome)

        sessionID = nil
        sessionStart = nil
        drain = nil
        transition(to: .idle)

        // The chord was pressed again while this session was finishing, and it
        // is still down. Honour it now rather than dropping the hold.
        if chordIsDown { startSession() }
    }

    private func transition(to state: SessionState) {
        guard snapshot.state != state else { return }
        snapshot.state = state
        if state == .idle {
            snapshot.id = nil
            snapshot.level = 0
        }
        onStateChange?(state)
    }
}
