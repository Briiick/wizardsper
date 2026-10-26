import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Delivery of a finished transcript into whatever app the user was typing in.
///
/// Dictation is only useful if the words land where the cursor is, and macOS
/// gives an unprivileged app exactly one way to do that: put the text on the
/// general pasteboard and synthesise Cmd-V. That borrows a system-wide resource
/// the user did not offer us, so everything here exists to give it back — the
/// pasteboard is captured item-by-item and type-by-type before we clear it, and
/// restored afterwards only once the target has had time to read the
/// transcript, and only if nothing else claimed the pasteboard in the meantime.
///
/// Main-actor isolated because `NSPasteboard` and `NSWorkspace` are, and because
/// the whole sequence must observe one consistent pasteboard state: a snapshot
/// taken on one actor and a `clearContents()` on another would race with each
/// other and with the user's own copying.
@MainActor
public enum Paster {

    /// The least time the target app gets to read the pasteboard before we put
    /// the old contents back.
    ///
    /// Cmd-V is asynchronous: `post` only hands the event to the window server,
    /// and the app then has to be scheduled, receive it, and read the
    /// pasteboard. Restore before that and the app reads the *previous*
    /// clipboard instead of the transcript. If that was an image or a file, a
    /// text field accepts nothing at all, so the user sees "Pasted" over an
    /// unchanged document. A fixed 150 ms did exactly that whenever the target
    /// was briefly busy, and the end of a dictation, with the recogniser and
    /// cleanup both finishing, is when it is most likely to be.
    ///
    /// The floor covers the part of the trip the responsiveness check below
    /// cannot see: the window server routing the keystroke to the app.
    private static let pasteboardReadFloor: Duration = .milliseconds(250)

    /// How long after the target proves it is responsive we still leave the
    /// transcript in place. The keystroke was queued before our question, so an
    /// app that has answered has the keystroke in hand or next in line; this is
    /// the margin for it to finish handling it and read the pasteboard.
    private static let pasteboardReadGrace: Duration = .milliseconds(150)

    /// The longest we wait for the target to respond at all. An app that has
    /// not answered by then is hung, and will act on the Cmd-V whenever it
    /// recovers — reading whatever is on the pasteboard at that moment.
    private static let responsivenessTimeout: Duration = .seconds(2)

    /// `kVK_ANSI_V`. Hard-coded rather than imported from Carbon's HIToolbox: it
    /// is a hardware-position code, fixed for all layouts, and the one Carbon
    /// symbol is not worth the framework.
    private static let virtualKeyV: CGKeyCode = 0x09

    /// `kVK_Command`, the left Command key, hard-coded for the same reason.
    private static let virtualKeyCommand: CGKeyCode = 0x37

    /// One (type, data) pair lifted off a pasteboard item while it was still
    /// readable.
    private struct Payload {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    /// Everything we managed to copy out of one `NSPasteboardItem`.
    ///
    /// The captured items are deliberately *not* the `NSPasteboardItem` objects
    /// themselves: an item belongs to the pasteboard it came from, goes stale
    /// the moment the owner changes (which our `clearContents()` causes), and
    /// raises an ObjC exception if handed back to `writeObjects(_:)`. Restoring
    /// therefore means rebuilding fresh items out of these bytes.
    private struct CapturedItem {
        let payloads: [Payload]
    }

    /// Put `text` where the user can use it and report what actually happened.
    ///
    /// Returns exactly one outcome on every path. `.pasted` means an app was
    /// sent Cmd-V; `.copied` means the text is on the pasteboard but nothing was
    /// keyed (no target, auto-paste off, or Accessibility not granted — in all
    /// three the transcript is still recoverable, so none of them is a failure);
    /// `.failed` is reserved for the one case where the text reached neither.
    public static func deliver(
        _ text: String, restorePasteboard: Bool, autoPaste: Bool, trailingSpace: Bool = false,
        pasteboard: NSPasteboard = .general
    ) async -> SessionOutcome {

        // A hold that produced only silence or punctuation-free whitespace has
        // nothing to deliver, and clobbering the clipboard for it would be a
        // pure loss. Bail before touching any shared state.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.paste.debug("Nothing to deliver: transcript is empty.")
            return .nothing(why: .noSpeech)
        }

        // The space goes on the pasteboard, not into `text`. Dictation happens
        // in bursts — a sentence, a pause, another sentence — and without it
        // every burst arrives welded to the last. But the transcript itself must
        // stay clean: it is what the flow bar shows and what history stores, and
        // a stored trailing space would accumulate through any later re-copy.
        // So the two diverge here, deliberately, and every `return` below still
        // carries the original.
        let delivered = trailingSpace ? text + " " : text

        // Captured only when it will be used. Reading another app's pasteboard
        // is not free — macOS treats it as an access worth telling the user
        // about — so with restore switched off we never look at it at all.
        let captured: [CapturedItem] = restorePasteboard ? capture(pasteboard) : []

        // `clearContents()` returns the count produced by its own increment, and
        // writing data afterwards does not bump it again, so this single value is
        // both the count in force after our write and our claim ticket: if it
        // still holds later, nobody has copied since and restoring is safe.
        // Reading `changeCount` back after the write instead would leave a window
        // in which another app's copy lands between the write and the read — we
        // would record *their* count as ours, the check below would match, and we
        // would overwrite their fresh copy with our stale snapshot.
        let ownedChangeCount = pasteboard.clearContents()

        guard pasteboard.setString(delivered, forType: .string) else {
            // `clearContents()` has already destroyed the user's clipboard by this
            // point. Returning without putting the snapshot back would cost them
            // both the transcript and whatever they had copied, for a write that
            // never landed, so the snapshot is spent here rather than dropped.
            if restorePasteboard {
                restore(captured, to: pasteboard, ifChangeCountIs: ownedChangeCount)
            }
            // The text reached neither the clipboard nor an app: the only path
            // in this function where the transcript is genuinely lost.
            Log.paste.error("NSPasteboard.setString failed; transcript was not delivered.")
            return .failed(.pasteFailed("the clipboard rejected the text"))
        }

        let target: Target
        let keystroke: [CGEvent]
        switch plan(autoPaste: autoPaste) {
        case .copy(let why):
            return .copied(text, why: why)
        case .paste(let app, let events):
            target = app
            keystroke = events
        }

        // The HID tap is the lowest point in the chain, so the events pass
        // through the same session taps and input methods as a real keystroke
        // instead of arriving somewhere downstream of them.
        for event in keystroke {
            event.post(tap: .cghidEventTap)
        }

        // Without a snapshot there is nothing to put back, so nothing to time
        // and no reason to hold the session open waiting.
        guard restorePasteboard, captured.contains(where: { !$0.payloads.isEmpty }) else {
            Log.paste.notice("Posted Cmd-V to \(target.name, privacy: .public); nothing to restore.")
            return .pasted(text)
        }

        // The restore is timed from when the target is demonstrably running, not
        // from when we posted. A fixed delay is a guess about how busy the app
        // is; asking it a question and waiting for the answer measures it.
        let clock = ContinuousClock()
        let posted = clock.now
        let responded = await waitUntilResponsive(target.pid, timeout: responsivenessTimeout)
        let respondedAfter = posted.duration(to: clock.now)

        guard responded else {
            // Hung past the timeout. It will act on the Cmd-V when it recovers,
            // and reads the pasteboard then, so restoring now would turn this
            // paste into the old clipboard. Keeping the transcript costs the user
            // their old clipboard, but their words still land.
            Log.paste.notice(
                "\(target.name, privacy: .public) did not respond within \(milliseconds(respondedAfter), privacy: .public) ms; leaving the transcript on the clipboard.")
            return .pasted(text)
        }

        let restoreAt = max(pasteboardReadFloor, respondedAfter + pasteboardReadGrace)
        do {
            try await Task.sleep(for: restoreAt - posted.duration(to: clock.now))
        } catch {
            // Cancelled mid-flight. The key event is already out, and we no
            // longer know whether the target has read the pasteboard, so putting
            // the old contents back now could turn the user's paste into their
            // previous clipboard. Leaving the transcript in place is the harmless
            // half of the trade.
            Log.paste.notice(
                "Cancelled before the restore delay elapsed; leaving the transcript on the clipboard.")
            return .pasted(text)
        }

        Log.paste.notice(
            "Pasted into \(target.name, privacy: .public), which responded after \(milliseconds(respondedAfter), privacy: .public) ms; restoring at \(milliseconds(restoreAt), privacy: .public) ms.")
        restore(captured, to: pasteboard, ifChangeCountIs: ownedChangeCount)
        return .pasted(text)
    }

    // MARK: - Deciding

    /// The app a paste is aimed at: the pid to check on, the name to log.
    private struct Target {
        let pid: pid_t
        let name: String
    }

    /// What `deliver` does once the text is on the pasteboard.
    private enum Plan {
        /// Leave it there, for this reason.
        case copy(CopyReason)
        /// Send `keystroke` to `target`.
        case paste(target: Target, keystroke: [CGEvent])
    }

    /// Settle whether a paste can happen.
    private static func plan(autoPaste: Bool) -> Plan {
        guard autoPaste else {
            Log.paste.debug("Auto-paste is off; leaving the transcript on the clipboard.")
            return .copy(.autoPasteDisabled)
        }

        // Nothing to paste into means nothing to paste: a posted Cmd-V would go
        // to whatever the window server decides is frontmost next, which could
        // be an app the user never pointed at.
        guard let target = NSWorkspace.shared.frontmostApplication else {
            Log.paste.debug("No frontmost application; copied instead of pasting.")
            return .copy(.noTarget)
        }
        // `Bundle.main.bundleIdentifier` is nil for the CLI target, so compare
        // only when we actually have an identity — otherwise a nil-equals-nil
        // match would make every paste look like a paste into ourselves.
        if let ourBundleID = Bundle.main.bundleIdentifier,
            target.bundleIdentifier == ourBundleID
        {
            Log.paste.debug("Wizardsper is frontmost; copied instead of pasting into ourselves.")
            return .copy(.noTarget)
        }

        // Synthetic events from an untrusted process are dropped by the window
        // server without any error reaching us. Posting anyway would look, from
        // the user's side, exactly like Wizardsper losing the transcript. The text
        // is on the clipboard, so this is `.copied`, not `.failed`.
        guard AXIsProcessTrusted() else {
            Log.paste.notice("Accessibility not granted; copied instead of pasting.")
            return .copy(.accessibilityDenied)
        }

        guard let keystroke = makeCommandV() else {
            // The transcript is still on the clipboard, so the user has not lost
            // anything — but event creation failing is not normal, so it is
            // logged at error level rather than passed over.
            Log.paste.error("Could not synthesise Cmd-V; copied instead of pasting.")
            return .copy(.accessibilityDenied)
        }

        let name = target.bundleIdentifier ?? target.localizedName ?? "pid \(target.processIdentifier)"
        return .paste(target: Target(pid: target.processIdentifier, name: name), keystroke: keystroke)
    }

    // MARK: - Pasteboard snapshot

    /// Copy out every type of every item, eagerly.
    ///
    /// Restoring only `.string` is the common shortcut and it is destructive: a
    /// copied image, a file promise, styled RTF, or an app's private type would
    /// all be silently replaced by their plain-text shadow, or by nothing.
    private static func capture(_ pasteboard: NSPasteboard) -> [CapturedItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }

        var skippedTypes = 0
        let captured = items.map { item -> CapturedItem in
            var payloads: [Payload] = []
            for type in item.types {
                // Some types are promises: the item advertises them, but the
                // bytes only exist if the owning app is still around to produce
                // them, and `data(forType:)` returns nil when it is not. There is
                // nothing to hold on to in that case, so the type is dropped from
                // the snapshot rather than restored as empty data — an empty
                // promise on the pasteboard is worse than an absent one, because
                // a reader will accept it and paste nothing.
                guard let data = item.data(forType: type) else {
                    skippedTypes += 1
                    continue
                }
                payloads.append(Payload(type: type, data: data))
            }
            return CapturedItem(payloads: payloads)
        }

        if skippedTypes > 0 {
            Log.paste.debug(
                "Skipped \(skippedTypes, privacy: .public) lazily-provided pasteboard type(s).")
        }
        return captured
    }

    /// Put the snapshot back, but only if the pasteboard is still ours.
    private static func restore(
        _ captured: [CapturedItem], to pasteboard: NSPasteboard, ifChangeCountIs owned: Int
    ) {
        // Anything that copied while we were waiting is more recent than what we
        // saved, and the user meant it. Losing their fresh copy to a restore of
        // stale contents is far more annoying than an unrestored clipboard.
        guard pasteboard.changeCount == owned else {
            Log.paste.debug("Pasteboard changed during the paste; leaving the newer contents alone.")
            return
        }

        let restorable = captured.filter { !$0.payloads.isEmpty }
        // Nothing was capturable — either the pasteboard was empty to begin with
        // or every item was an unfulfillable promise. Clearing here would leave
        // the user with neither their old contents nor their transcript, so the
        // transcript stays.
        guard !restorable.isEmpty else {
            Log.paste.debug("Nothing captured to restore; leaving the transcript on the clipboard.")
            return
        }

        let items = restorable.map { capturedItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for payload in capturedItem.payloads {
                guard item.setData(payload.data, forType: payload.type) else {
                    // A type the snapshot carried that the fresh item refuses —
                    // in practice a legacy, non-UTI type name. One type is lost;
                    // the rest of the item is still worth restoring, so this is
                    // recorded and the loop goes on.
                    Log.paste.notice(
                        "Could not restore pasteboard type \(payload.type.rawValue, privacy: .public).")
                    continue
                }
            }
            return item
        }

        _ = pasteboard.clearContents()
        if !pasteboard.writeObjects(items) {
            Log.paste.error("Failed to restore the previous pasteboard contents.")
        }
    }

    // MARK: - Responsiveness

    /// Ask the target a trivial Accessibility question and wait for its answer.
    /// Returns false if it did not answer within `timeout`.
    ///
    /// An Accessibility request is served by the app's own main thread, so the
    /// answer cannot come back while that thread is stalled — which is exactly
    /// the condition under which a queued Cmd-V has not been handled yet. Any
    /// answer counts, an error included: `.noValue` from an app with nothing
    /// focused still proves it is running. Only `.cannotComplete`, which is
    /// what a timeout or a hung app produces, means it is not.
    ///
    /// Run off the main actor because the call blocks, and blocking here would
    /// be worse than slow: the target's paste may need to read the pasteboard
    /// from *us*, and a main thread parked waiting on the target could not
    /// answer it.
    private static func waitUntilResponsive(_ pid: pid_t, timeout: Duration) async -> Bool {
        let seconds = Float(milliseconds(timeout)) / 1000
        return await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, seconds)
            var focused: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                app, kAXFocusedUIElementAttribute as CFString, &focused)
            return result != .cannotComplete
        }.value
    }

    /// Whole milliseconds in `duration`, for log lines.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    // MARK: - Key event

    /// Build Cmd-V as the four events a real keystroke produces: Command down,
    /// V down, V up, Command up. Returns nil if the events could not be built.
    ///
    /// The Command key gets its own events rather than only riding along as a
    /// flag on V. A flag-only Cmd-V works for an app that reads the flags off
    /// the key event, but not for one that asks for the *live* modifier state
    /// as it handles the event — and that state only changes on a Command
    /// key event. Sending one costs nothing and removes the difference between
    /// our keystroke and the user's.
    private static func makeCommandV() -> [CGEvent]? {
        // One source for every event so the window server sees them as a single
        // device's keystroke rather than unrelated events. Combined session
        // state is the table that reflects the real hardware the user is holding.
        guard let source = CGEventSource(stateID: .combinedSessionState),
            let commandDown = CGEvent(
                keyboardEventSource: source, virtualKey: virtualKeyCommand, keyDown: true),
            let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
            let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false),
            let commandUp = CGEvent(
                keyboardEventSource: source, virtualKey: virtualKeyCommand, keyDown: false)
        else {
            return nil
        }

        // Assignment, deliberately not `insert` into the live modifier state. The
        // user is almost certainly still holding the dictation chord (Fn by
        // default) at this instant — the paste happens on key release, and
        // fingers do not lift instantly. A held Fn riding along with Cmd-V is a
        // different chord as far as the target app is concerned, and events
        // created from a live source inherit whatever is physically down. Stating
        // the flags exactly guarantees the app sees a plain Cmd-V, and an empty
        // set on the final Command-up leaves no modifier latched behind it.
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        return [commandDown, keyDown, keyUp, commandUp]
    }
}
