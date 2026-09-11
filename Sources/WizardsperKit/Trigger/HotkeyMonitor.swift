import AppKit
import CoreGraphics
import Foundation

/// Watches the system-wide modifier stream and reports the dictation chord
/// being pressed and released.
///
/// A `CGEventTap` on `.flagsChanged` is the only mechanism that gives *both*
/// edges of a modifier-only hold while another app is frontmost:
/// `RegisterEventHotKey` fires once on press and never reports the release, and
/// `NSEvent.addGlobalMonitorForEvents` is delivered too late and stops entirely
/// while a menu is tracking. Without both edges there is no hold-to-talk.
///
/// The tap is created `.listenOnly` and the callback always hands the event
/// back untouched. This is not a preference — a `.defaultTap` that returned
/// `nil` would *consume* the chord, and consuming Fn disables the entire
/// function-key row in every app on the machine for as long as Wizardsper runs.
///
/// ## Callback contract
/// `onPress` and `onRelease` strictly alternate, always starting with
/// `onPress`. Every path that can invalidate a hold — `stop()`,
/// `updateChord(_:)`, recovery from a disabled tap — closes an open hold with
/// `onRelease` rather than dropping it, so a coordinator can treat the pair as
/// a balanced session bracket and never has to defend against a stray release.
@MainActor
public final class HotkeyMonitor {

    /// The chord currently being watched for. Changed through `updateChord(_:)`
    /// so the hold bookkeeping is reset with it.
    public private(set) var chord: Chord

    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void

    // `nonisolated(unsafe)` because `deinit` has to invalidate the tap, and a
    // nonisolated deinit cannot touch main-actor state. The unsafety is
    // contained: these are written only by `start()` and `stop()`, both
    // main-actor, and deinit runs only once no other reference survives.
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var source: CFRunLoopSource?

    /// Whether the chord was down as of the last event we saw.
    ///
    /// One physical key held down produces a stream of `.flagsChanged` events
    /// (any other modifier moving re-reports the whole flag set), so the raw
    /// events are a level, not an edge. Without this latch a single hold would
    /// start several overlapping sessions.
    private var isHeld = false

    public init(
        chord: Chord = .fn,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        self.chord = chord
        self.onPress = onPress
        self.onRelease = onRelease
    }

    deinit {
        // The C callback reaches this object through an *unretained* pointer,
        // so the tap must never outlive it. `stop()` is the supported teardown;
        // this is the backstop for an owner that simply drops the monitor.
        // Invalidating the port stops delivery before the storage goes away.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }

    public var isRunning: Bool { tap != nil }

    /// Installs the tap. Idempotent — a second call while running is a no-op.
    ///
    /// - Throws: `WizardsperError.inputMonitoringDenied` when the tap cannot be
    ///   created, which in practice means TCC has not granted Input Monitoring.
    public func start() throws {
        guard tap == nil else { return }

        if chord.isEmpty {
            // Not fatal: `Chord.isHeld` is false for an empty set, so the tap
            // runs but never fires until `updateChord(_:)` supplies a real one.
            Log.trigger.warning("Starting hotkey monitor with an empty chord — it will never fire.")
        }

        // Only `.flagsChanged` is requested. The two `tapDisabledBy…`
        // notifications are delivered to the callback regardless of the mask
        // (their raw values are outside the 64-bit mask range), which is why
        // they are handled in `handle(type:flags:)` but not listed here.
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

        // Unretained on purpose: a retain here would be unbalanced — nothing
        // releases it, and the monitor could then never deallocate. The safety
        // of the raw pointer rests on `stop()`/`deinit` invalidating the port
        // before this object's storage is freed.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyMonitorTapCallback,
                userInfo: context)
        else {
            Log.trigger.error(
                "CGEvent.tapCreate returned nil (Input Monitoring preflight: \(CGPreflightListenEventAccess(), privacy: .public))"
            )
            throw WizardsperError.inputMonitoringDenied
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // The port is live but unusable; tear it down rather than leaving a
            // tap installed that nothing will ever service.
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            Log.trigger.error("CFMachPortCreateRunLoopSource returned nil for the event tap.")
            throw WizardsperError.inputMonitoringDenied
        }

        // `.commonModes`, not `.defaultMode`: while a menu is open or a window
        // is being resized the main run loop switches to a tracking mode, and a
        // default-mode-only source would stop delivering exactly when the user
        // is most likely to be reaching for the dictation key.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.tap = tap
        self.source = source

        // Deliberately *not* seeded from the live flags. Starting with the
        // chord already down and seeding `true` would make the next release
        // fire an `onRelease` with no matching `onPress`; seeding `false` costs
        // nothing but a chord that must be re-pressed once.
        isHeld = false

        Log.trigger.notice("Hotkey monitor listening for \(self.chord.display, privacy: .public)")
    }

    /// Removes the tap and closes any hold that was in flight.
    ///
    /// Safe to call when not running, and safe to call from inside `onRelease`.
    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil

        // State is cleared before the callback so a re-entrant `stop()` from
        // inside `onRelease` finds nothing left to do.
        if isHeld {
            isHeld = false
            Log.trigger.notice("Hotkey monitor stopped mid-hold; releasing.")
            onRelease()
        } else {
            Log.trigger.notice("Hotkey monitor stopped.")
        }
    }

    /// Rebinds the chord without restarting the tap.
    ///
    /// A hold that is open under the old chord is released here: its release
    /// edge is defined in terms of modifiers we have stopped watching, so it
    /// would never arrive and the session would hang open forever.
    public func updateChord(_ newChord: Chord) {
        guard newChord != chord else { return }
        chord = newChord
        Log.trigger.notice("Hotkey chord rebound to \(self.chord.display, privacy: .public)")

        if isHeld {
            isHeld = false
            onRelease()
        }
        // `isHeld` stays false even if the new chord happens to be down right
        // now. Arming it `true` would emit an unmatched release; leaving it
        // false means at worst one extra press is needed, and the alternation
        // guarantee survives either way.
    }

    // MARK: - Event handling

    /// Called on the main actor for every event the tap delivers.
    fileprivate func handle(type: CGEventType, flags: CGEventFlags) {
        switch type {
        case .flagsChanged:
            apply(flags: flags)

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS kills a tap whose callback was slow to return, and does so
            // permanently unless it is re-armed. Skipping this is a silent,
            // unrecoverable death: the app keeps running and simply never
            // responds to the dictation key again.
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            Log.trigger.error("Event tap disabled by \(reason, privacy: .public); re-enabling.")
            guard let tap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)

            // Any flags that changed while the tap was dead were never
            // delivered. Re-reading the live modifier state is what stops a key
            // released during the outage from leaving a session stuck open.
            apply(flags: CGEventSource.flagsState(.combinedSessionState))

        default:
            break
        }
    }

    /// Edge-detects the chord against a set of modifier flags.
    private func apply(flags: CGEventFlags) {
        let held = chord.isHeld(in: flags)
        guard held != isHeld else { return }
        isHeld = held
        if held {
            onPress()
        } else {
            onRelease()
        }
    }
}

/// The tap's C callback.
///
/// It lives at file scope rather than as a closure because a
/// `@convention(c)` function cannot capture context and cannot carry actor
/// isolation. The monitor is reached back through the `userInfo` pointer that
/// `start()` installed.
///
/// The event is always returned unmodified — see the note on `.listenOnly` in
/// `HotkeyMonitor`.
private func hotkeyMonitorTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // The run-loop source was added to `CFRunLoopGetMain()`, so this callback is
    // already executing on the main thread — `assumeIsolated` states that fact
    // instead of hopping. A `Task { @MainActor }` here would defer the edge to a
    // later turn of the run loop, which reorders press against release when the
    // chord is tapped quickly.
    // Read the flags out before the closure: `CGEvent` is not Sendable, and
    // capturing it would be a data-race error even though only this one
    // Sendable field is used.
    let flags = event.flags
    MainActor.assumeIsolated {
        monitor.handle(type: type, flags: flags)
    }

    return Unmanaged.passUnretained(event)
}
