import AVFoundation
import Accelerate
import Foundation
import Synchronization

/// The microphone end of the pipeline: AVAudioEngine tap → AVAudioConverter →
/// 16 kHz mono Float32 → `AudioRingBuffer`.
///
/// Nemotron wants exactly one input format and the hardware never offers it —
/// built-in mics run at 44.1 or 48 kHz, USB interfaces at whatever they please,
/// and every one of them is multi-channel. Doing that conversion here, once, in
/// the tap, means nothing downstream ever has to ask what the input device was.
///
/// The hard constraint is that the tap is called on CoreAudio's render thread.
/// Missing its deadline does not raise an error; it silently drops the buffer,
/// so a lock or an allocation in this file becomes a dropout in someone's
/// dictation. Everything the tap needs — converter, output buffer, input block —
/// is therefore built up front in `buildEngine()` and merely *used* in the
/// callback.
///
/// `@unchecked Sendable` invariant: the mutable stored properties below are all
/// `@MainActor`-isolated, so they are only ever touched from `start()`,
/// `stop()`, and the configuration-change handler, which the compiler pins to
/// the main actor. The render thread reaches only `ring`, `level`, and
/// `tapContext` — three objects whose entire surface is lock-free atomics or
/// render-thread-exclusive storage. There is no other shared state.
public final class AudioCapture: @unchecked Sendable {

    // MARK: - Tuning

    /// Frames requested per tap callback.
    ///
    /// The engine treats this as a hint and may hand over a different count, so
    /// nothing downstream assumes it; what it buys is a *floor*. 2048 frames is
    /// ~43 ms at 48 kHz — comfortably above the HAL's typical 512-frame I/O
    /// slice, so the render thread is not entered four times as often as it
    /// needs to be, and still fast enough that the level meter updates ~23 times
    /// a second and the ring never absorbs a large burst at once.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    /// One second of 16 kHz mono output per convert call. Far more than any
    /// plausible tap buffer needs, and only 64 KB, so a device that hands over
    /// unusually long buffers cannot silently truncate.
    private static let outputCapacity: AVAudioFrameCount = AVAudioFrameCount(
        NemotronConfig.sampleRate)

    // MARK: - Shared with the render thread

    private let ring: AudioRingBuffer
    private let level: LevelBox

    /// The one piece of state the tap and the converter's input block share.
    /// Lives in its own object so the input block can be built once and capture
    /// *it* rather than `self`: a `weak self` load on the render thread goes
    /// through the runtime's side table and retains, which is exactly the kind
    /// of unbounded work a render thread must not do.
    private let tapContext = TapContext()

    /// Built once, in `init`, because `AVAudioConverter` calls it on every
    /// convert and a freshly-allocated block per callback would be an
    /// allocation per audio buffer.
    private let converterInput: AVAudioConverterInputBlock

    // MARK: - Main-actor state

    @MainActor private var engine: AVAudioEngine?
    @MainActor private var configurationObserver: NSObjectProtocol?
    @MainActor private var running = false

    /// Called when capture dies in a way the session cannot survive — currently
    /// only a failed rebuild after a device change. A normal `stop()` never
    /// calls it.
    @MainActor public var onFailure: (@Sendable (WizardError) -> Void)?

    @MainActor public var isRunning: Bool { running }

    public init(ring: AudioRingBuffer, level: LevelBox) {
        self.ring = ring
        self.level = level

        let context = self.tapContext
        // Hand the converter the buffer the tap just parked, exactly once per
        // convert; after that say "no data now" so the converter returns with
        // whatever it managed rather than calling back forever.
        self.converterInput = { _, outStatus in
            guard let buffer = context.takePendingInput() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
    }

    // MARK: - Authorisation

    public static var microphoneAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Make sure Microphone access is granted, prompting once if macOS has never
    /// asked. Call this before `start()` — `start()` itself cannot prompt,
    /// because the prompt is asynchronous and the key is already down.
    public static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                Log.audio.error("Microphone access denied at the system prompt")
                throw WizardError.microphoneDenied
            }
        case .denied, .restricted:
            Log.audio.error("Microphone access is denied or restricted in System Settings")
            throw WizardError.microphoneDenied
        @unknown default:
            Log.audio.error("Unrecognised microphone authorisation status")
            throw WizardError.microphoneDenied
        }
    }

    // MARK: - Lifecycle

    /// Build the engine and start feeding the ring. Idempotent: a second call
    /// while already running is a no-op rather than a second engine.
    @MainActor
    public func start() throws {
        guard !running else { return }

        // `.notDetermined` is deliberately fatal here rather than silently
        // capturing a second of nothing while the system prompt is up: the
        // caller was supposed to have run `ensureMicrophoneAccess()` already,
        // and "grant Microphone access" is a far more actionable message than
        // "no audio was captured".
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            Log.audio.error("Refusing to start capture: microphone status is \(status.rawValue)")
            throw WizardError.microphoneDenied
        }

        tapContext.resetCounters()
        try buildEngine()
        running = true

        // Registered against no particular object: a rebuild replaces the engine
        // instance, and re-registering on every rebuild would be one more thing
        // to get wrong. Wizard creates exactly one engine, so there is nothing
        // else this could match.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            // AVFoundation posts this from an engine-internal dispatch queue and
            // its own header warns that tearing the engine down synchronously
            // from here can deadlock. Hopping to the main actor both dodges that
            // and satisfies the isolation of everything we are about to touch.
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }

        Log.audio.info("Capture started")
    }

    /// Stop capture and release the engine. Safe to call when not running.
    @MainActor
    public func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard running else {
            teardownEngine()
            return
        }
        running = false
        teardownEngine()

        // Both counters are the only evidence that a session lost audio: the ring
        // overruns when the recogniser falls behind, the converter fails when the
        // device hands over something it cannot represent. Neither can be logged
        // from the render thread, so they are reported here.
        let dropped = ring.droppedFrames
        if dropped > 0 {
            Log.audio.error(
                "Ring overran: \(dropped) frames dropped — the drain task fell behind")
        }
        let failures = tapContext.conversionFailureCount
        if failures > 0 {
            Log.audio.error("\(failures) audio buffers failed to convert to 16 kHz mono")
        }
        Log.audio.info("Capture stopped")
    }


    /// Build the render-thread tap block, outside any actor's isolation.
    ///
    /// This must not be a closure literal written inside `buildEngine()`, and the
    /// reason is a crash rather than a preference. `AVAudioNodeTapBlock` is an
    /// imported Objective-C block typedef and is therefore *not* `@Sendable`, so
    /// a closure literal appearing inside a `@MainActor` function silently
    /// **inherits main-actor isolation**. Swift 6 then emits an isolation check
    /// at the top of the block — and that check runs on the audio render thread,
    /// where it calls `dispatch_assert_queue`, fails, and traps the process:
    ///
    ///     EXC_BREAKPOINT in _swift_task_checkIsolatedSwift
    ///       <- swift_task_isCurrentExecutorWithFlags
    ///       <- closure #1 in AudioCapture.buildEngine()
    ///       <- AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
    ///
    /// The crash lands on the very first captured buffer, so it looks like
    /// "the app dies the moment you hold the key". Marking the closure
    /// `@Sendable` would also detach it, but `AVAudioConverter` and
    /// `AVAudioPCMBuffer` are not `Sendable` and could not then be captured.
    /// Forming the block in a nonisolated context is what keeps it genuinely
    /// nonisolated while still allowing those captures.
    ///
    /// Everything the block touches is either owned solely by this tap
    /// generation (`converter`, `output`, `inputBlock`) or lock-free
    /// (`context`, `ring`, `level`).
    nonisolated private static func makeTapBlock(
        converter: AVAudioConverter,
        output: AVAudioPCMBuffer,
        inputBlock: @escaping AVAudioConverterInputBlock,
        context: TapContext,
        ring: AudioRingBuffer,
        level: LevelBox
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            // ---- render thread, real-time deadline ----
            // No allocation, no locks, no ObjC collections, no logging. The one
            // thing outside our control is AVAudioConverter itself, which may
            // allocate internally on its first call or when it reprimes; what we
            // guarantee is that our own code path does not.
            context.parkPendingInput(buffer)

            var conversionError: NSError?
            let status = converter.convert(
                to: output, error: &conversionError, withInputFrom: inputBlock)

            // InputRanDry is the expected outcome, not a failure: we hand the
            // converter one buffer and it converts all of it.
            guard status == .haveData || status == .inputRanDry else {
                context.recordConversionFailure()
                return
            }

            let frames = Int(output.frameLength)
            guard frames > 0, let channel = output.floatChannelData?[0] else { return }

            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames))
            level.store(rms)

            ring.write(UnsafeBufferPointer(start: channel, count: frames))
            // ---- end render thread ----
        }
    }

    // MARK: - Engine construction

    @MainActor
    private func buildEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // A device that has gone away, or one we are not allowed to open, reports
        // a zero format. Installing a tap with it throws an ObjC exception that
        // Swift cannot catch, so this guard is load-bearing, not defensive.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw WizardError.audioEngineFailed(
                "the input device reports no usable format — is one connected?")
        }

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(NemotronConfig.sampleRate),
                channels: 1, interleaved: false)
        else {
            throw WizardError.audioEngineFailed("could not describe 16 kHz mono Float32")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw WizardError.audioEngineFailed(
                "no conversion from \(Int(inputFormat.sampleRate)) Hz / "
                    + "\(inputFormat.channelCount) ch to 16 kHz mono")
        }
        // Downsampling 48 kHz to 16 kHz folds everything above 8 kHz back into the
        // band the recogniser listens to unless the resampler's filter is good.
        // The extra cost on a 43 ms buffer is negligible; the aliasing is not.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        // Multi-channel input is mixed down rather than having channel 0 picked
        // out, so a two-mic array does not lose half its signal.
        converter.downmix = true

        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: Self.outputCapacity)
        else {
            throw WizardError.audioEngineFailed("could not allocate the 16 kHz output buffer")
        }

        // Captured by value so each tap generation owns its own converter and
        // output buffer. A rebuild installs a new tap with new objects; the old
        // block is released with the old tap and can never scribble into the new
        // one's buffer.
        let ring = self.ring
        let level = self.level
        let context = self.tapContext
        let inputBlock = self.converterInput

        // Built by a nonisolated function — see `makeTapBlock` for why that is
        // load-bearing rather than stylistic.
        input.installTap(
            onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat,
            block: Self.makeTapBlock(
                converter: converter, output: output, inputBlock: inputBlock,
                context: context, ring: ring, level: level))

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw WizardError.audioEngineFailed(error.localizedDescription)
        }

        self.engine = engine
        Log.audio.info(
            "Engine running: \(Int(inputFormat.sampleRate)) Hz / \(inputFormat.channelCount) ch → 16 kHz mono"
        )
    }

    /// Unwind whatever `buildEngine` put in place. Deliberately leaves the ring
    /// and the level meter alone — a rebuild runs through here mid-session.
    @MainActor
    private func teardownEngine() {
        guard let engine else { return }
        // Order matters: the tap must come off before the engine stops, or a
        // callback can still be in flight against objects we are about to drop.
        // `removeTap` waits for any in-progress callback to return.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // MARK: - Configuration changes

    /// The default input device changed, or its sample rate did, or headphones
    /// with a mic were plugged in. AVAudioEngine has already stopped itself and
    /// the old converter is now wrong for the new hardware format.
    ///
    /// The session must survive this. The ring is untouched, so the audio
    /// captured before the change stays in the transcript, and the caller is not
    /// told anything ended — from its point of view there is a short gap in the
    /// recording and nothing more.
    @MainActor
    private func handleConfigurationChange() {
        guard running else { return }
        Log.audio.info("Audio configuration changed — rebuilding the engine mid-session")

        teardownEngine()
        do {
            try buildEngine()
        } catch {
            // A rebuild that fails is the one case the session cannot ride out:
            // there is no engine and no way to get more audio.
            let failure =
                (error as? WizardError)
                ?? WizardError.audioEngineFailed(error.localizedDescription)
            Log.audio.error(
                "Rebuild after a configuration change failed: \(failure.errorDescription ?? "unknown", privacy: .public)"
            )
            running = false
            onFailure?(failure)
        }
    }
}

/// The sliver of state the render thread and the converter's input block share.
///
/// `@unchecked Sendable` invariant: `pendingInput` is written and read only
/// inside one tap callback — the tap parks a buffer, then calls `convert`, which
/// synchronously calls the input block on the same thread, which takes it. It is
/// never live across a callback boundary, and `removeTap` drains any in-flight
/// callback before a new tap can be installed, so two threads never see it at
/// once. `conversionFailures` is a plain atomic and is read from the main actor.
private final class TapContext: @unchecked Sendable {
    private var pendingInput: AVAudioPCMBuffer?
    private let conversionFailures = Atomic<Int>(0)

    /// Render thread: hand this buffer to the next `convert` call.
    func parkPendingInput(_ buffer: AVAudioPCMBuffer) {
        pendingInput = buffer
    }

    /// Render thread, from inside `convert`: take the parked buffer, once.
    func takePendingInput() -> AVAudioPCMBuffer? {
        defer { pendingInput = nil }
        return pendingInput
    }

    /// Render thread. One relaxed increment — the exact count does not matter,
    /// only that `stop()` can see it is non-zero and say so.
    func recordConversionFailure() {
        let previous = conversionFailures.load(ordering: .relaxed)
        conversionFailures.store(previous &+ 1, ordering: .relaxed)
    }

    var conversionFailureCount: Int {
        conversionFailures.load(ordering: .relaxed)
    }

    func resetCounters() {
        conversionFailures.store(0, ordering: .relaxed)
    }
}
