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
    private let gain = GainBox()
    private let capture: AudioCapture
    private let settings: Settings
    private let history: TranscriptionHistory

    private var asr: StreamingASR?

    // MARK: - Session state

    private var sessionID: SessionID?
    /// The recogniser this session was started against.
    ///
    /// `complete()` must finish on the same object `pump()` fed. Reading
    /// `self.asr` instead would, after a model swap mid-hold, drain the audio
    /// into one recogniser and then ask a different one — which has heard
    /// nothing — for the transcript.
    private var sessionRecogniser: StreamingASR?
    private var sessionStart: Date?
    private var published = false
    private var drain: Task<Void, Never>?
    /// Bumped by every `prepare()`. A load that finishes after a newer one
    /// started must not install its result over the winner's.
    private var loadGeneration = 0

    /// Whether the chord is physically down right now, which is not the same as
    /// whether a session is running: a press that lands while the previous
    /// session is still finishing is honoured when that session completes,
    /// rather than dropped. Without this, releasing and re-pressing inside the
    /// ~200 ms it takes to paste would silently lose the second hold.
    private var chordIsDown = false

    /// Capture is running for the dashboard's level meter, with no session
    /// behind it. Tracked because starting and stopping the engine is shared
    /// between two owners that must not stand on each other.
    private var isPreviewing = false

    /// How much audio to hand the recogniser at once. Small enough that a
    /// partial appears promptly, large enough that the actor hop is not the
    /// dominant cost.
    private let feedFrames = 4096

    /// Share of samples at the rails above which clipping, rather than silence,
    /// is the better explanation for an empty transcript. Ordinary speech
    /// touches full scale occasionally; 2% of every sample in a hold does not
    /// happen without too much gain.
    private static let clippingThreshold = 0.02

    public init(
        settings: Settings = .shared,
        history: TranscriptionHistory = .shared
    ) {
        self.settings = settings
        self.history = history
        self.capture = AudioCapture(ring: ring, level: level, gain: gain)
        self.gain.set(Float(settings.inputGain))
        self.activeTier = settings.tier
        self.capture.onFailure = { [weak self] error in
            MainActor.assumeIsolated {
                self?.abort(with: error)
            }
        }
    }

    /// The flow bar polls this at 60 Hz rather than being pushed every buffer.
    public func currentLevel() -> Float { level.poll() }

    /// Linear input gain. Takes effect on the next captured buffer, so it can be
    /// moved while a hold is in progress and heard immediately.
    public func setInputGain(_ value: Double) { gain.set(Float(value)) }
    public var inputGain: Double { Double(gain.current) }

    /// Run capture without a session, so the dashboard can show a live meter
    /// while the user sets the gain. There is no recogniser attached and nothing
    /// is transcribed; the ring is drained and discarded.
    public func startLevelPreview() throws {
        guard snapshot.state == .idle else { return }
        ring.reset()
        level.reset()
        try capture.start()
        isPreviewing = true
        Log.audio.info("Level preview started")
    }

    public func stopLevelPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        // Only stop the engine if no session has taken it over in the meantime;
        // a session owns capture for its whole life and must not have it pulled
        // out from under it by a dashboard toggle.
        if snapshot.state == .idle {
            capture.stop()
            ring.reset()
        }
        Log.audio.info("Level preview stopped")
    }

    // MARK: - Model lifecycle

    /// Load a tier's models. Safe to call again to switch tiers; an in-flight
    /// session is torn down first, because its encoder caches belong to the old
    /// model and are meaningless to the new one.
    public func prepare(tier: NemotronTier, directory: URL) async {
        loadGeneration += 1
        let generation = loadGeneration
        endSessionForModelChange()

        isReady = false
        activeTier = tier
        statusText = "Loading \(tier.displayName)…"
        do {
            let bundle = try await ModelBundle.load(from: directory)
            guard generation == loadGeneration else { return }
            let recogniser = try StreamingASR(bundle: bundle, framing: settings.framing)
            // Force CoreML to build its plans now and prove the encoder woke up,
            // so the first real hold is not the thing that discovers a problem.
            try await recogniser.warmUp()
            guard generation == loadGeneration else { return }
            // A hold may have started during those awaits. It owns the outgoing
            // recogniser, so end it before the swap rather than leaving it to
            // drain into a model that never heard its audio.
            endSessionForModelChange()

            self.asr = recogniser
            self.isReady = true
            self.statusText = "Ready"
            Log.session.info("Loaded \(tier.rawValue, privacy: .public) ms tier")
        } catch let error as WizardError {
            guard generation == loadGeneration else { return }
            self.asr = nil
            self.statusText = error.errorDescription ?? "Model failed to load"
            Log.session.error("Model load failed: \(self.statusText, privacy: .public)")
        } catch {
            guard generation == loadGeneration else { return }
            self.asr = nil
            self.statusText = error.localizedDescription
            Log.session.error("Model load failed: \(self.statusText, privacy: .public)")
        }
    }

    private func endSessionForModelChange() {
        guard let id = sessionID else { return }
        finalize(.failed(.modelsMissing("the model was reloaded mid-session")), for: id)
    }

    // MARK: - Trigger

    /// The chord went down.
    ///
    /// Returns immediately. This is called straight from the `CGEventTap`
    /// callback, which runs on the main run loop: everything that happens before
    /// it returns is time during which no other keystroke on the system is
    /// delivered, and macOS disables a tap that is slow to return. Starting
    /// `AVAudioEngine` takes tens of milliseconds, so it goes on a later turn.
    public func begin() {
        chordIsDown = true
        guard snapshot.state == .idle else {
            // A previous session is still finishing. `finalize` restarts for us
            // once it lands, and only if the chord is still down by then.
            Log.session.debug("Press arrived while finishing; deferring")
            return
        }
        scheduleStart()
    }

    /// The chord came up. Also returns immediately, for the same reason.
    public func end() {
        chordIsDown = false
        guard snapshot.state == .listening, let id = sessionID else { return }
        transition(to: .finishing)
        Task { await complete(id) }
    }

    /// Begin a session on a later turn of the run loop.
    ///
    /// Used both by `begin()` and by `finalize()`'s restart. Going through a
    /// Task is what keeps `finalize → startSession → finalize` from being
    /// unbounded synchronous recursion: a microphone that fails to open while
    /// the chord is held would otherwise loop until the stack overflowed.
    private func scheduleStart() {
        Task { @MainActor in
            guard self.chordIsDown, self.sessionID == nil, self.snapshot.state == .idle
            else { return }
            self.startSession()
        }
    }

    /// Give up on the current session without a transcript, still publishing an
    /// outcome so nothing downstream is left waiting.
    public func cancel() {
        guard let id = sessionID else { return }
        // Clear the latch first: finalize() would otherwise read the chord as
        // still held and start the very session this call is cancelling.
        chordIsDown = false
        finalize(.nothing(why: .noSpeech), for: id)
    }

    // MARK: - Session

    private func startSession() {
        // The dashboard's microphone test leaves capture running with no
        // session attached. Starting a session on top of it would reset the ring
        // buffer while the render thread is still writing into it — the one
        // thing the lock-free handoff cannot survive — and `capture.start()`
        // below would then be a no-op, so the session would run against indices
        // that had been moved under a live producer.
        if isPreviewing {
            isPreviewing = false
            capture.stop()
            Log.audio.info("Level preview ended: a session took the microphone")
        }
        guard let asr else {
            // Not a session — there is nothing to publish an outcome for — so
            // this surfaces through statusText rather than through an outcome.
            statusText = "Model is still loading"
            Log.session.notice("Press ignored: no model loaded")
            return
        }
        let id = SessionID()
        sessionID = id
        sessionRecogniser = asr
        sessionStart = Date()
        published = false
        snapshot = SessionSnapshot(id: id, state: .listening, transcript: "", level: 0, outcome: nil)
        onStateChange?(.listening)

        // Safe here and only here: capture is stopped, so the ring has no live
        // producer racing these index writes.
        ring.reset()
        level.reset()

        drain = Task { [weak self] in
            await self?.pump(id, asr: asr)
        }
        Log.session.info("Session \(id.description, privacy: .public) listening")
    }

    /// Move captured audio into the recogniser for as long as this session owns
    /// the coordinator. Runs on the main actor but never blocks it: every
    /// expensive step is an `await` into the recogniser's own executor.
    private func pump(_ id: SessionID, asr: StreamingASR) async {
        // Clear the previous utterance before a single sample is fed. Without
        // this the encoder caches, the LSTM state and the accumulated token
        // stream all carry over, and every transcript arrives with every earlier
        // transcript glued to the front of it.
        do {
            try await asr.reset()
        } catch let error as WizardError {
            finalize(.failed(error), for: id)
            return
        } catch {
            finalize(.failed(.audioEngineFailed(error.localizedDescription)), for: id)
            return
        }
        guard sessionID == id else { return }

        // Opening the engine here rather than in `startSession()` keeps it off
        // the event-tap callback's turn of the run loop.
        do {
            try capture.start()
        } catch let error as WizardError {
            finalize(.failed(error), for: id)
            return
        } catch {
            finalize(.failed(.audioEngineFailed(error.localizedDescription)), for: id)
            return
        }
        guard sessionID == id else {
            capture.stop()
            return
        }

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
        // The session's own recogniser, not whatever `self.asr` is now: a model
        // swap during the hold must not redirect the transcript to a model that
        // never received the audio. Finalise rather than return if it is gone —
        // returning is the one path that would leave the flow bar waiting on an
        // outcome that never comes.
        guard let asr = sessionRecogniser else {
            finalize(.failed(.modelsMissing("the recogniser went away mid-session")), for: id)
            return
        }
        // Stop the producer before touching the ring: `read` is only safe
        // against a live writer for the SPSC handoff, and the drain below is
        // about to run to empty.
        capture.stop()
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
            finalize(.nothing(why: .tooShort), for: id)
            return
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An empty transcript after a real hold has two very different
            // causes, and the user can only act on one of them. If the gain
            // stage was pulling a meaningful share of samples to the rails, the
            // recogniser heard a square wave rather than a voice, and no amount
            // of speaking louder will help — so say that instead of blaming the
            // microphone.
            let clipped = capture.clippedFraction
            if clipped > Self.clippingThreshold {
                Log.audio.notice(
                    "\(clipped * 100, format: .fixed(precision: 1))% of samples clipped; gain is too high")
                finalize(.nothing(why: .clipping), for: id)
            } else {
                finalize(.nothing(why: .noSpeech), for: id)
            }
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
        guard let id = sessionID else {
            capture.stop()
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

        // The single exit, so the only place guaranteed to run on every terminal
        // path. Stopping capture here is what stops a failure in the pump from
        // leaving the microphone open — and its orange indicator lit — for the
        // rest of the process's life.
        capture.stop()
        drain?.cancel()
        drain = nil

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
        sessionRecogniser = nil
        sessionStart = nil
        transition(to: .idle)

        // The chord was pressed again while this session was finishing and is
        // still down, so honour it rather than dropping the hold — but not after
        // a failure. Restarting on failure would retry a microphone that just
        // refused to open, immediately and for as long as the key is held.
        if chordIsDown, !outcome.isFailure { scheduleStart() }
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
