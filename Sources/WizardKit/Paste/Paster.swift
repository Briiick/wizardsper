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
/// restored afterwards only if nothing else claimed it in the meantime.
///
/// Main-actor isolated because `NSPasteboard` and `NSWorkspace` are, and because
/// the whole sequence must observe one consistent pasteboard state: a snapshot
/// taken on one actor and a `clearContents()` on another would race with each
/// other and with the user's own copying.
@MainActor
public enum Paster {

    /// How long the target app gets to read the pasteboard before we put the old
    /// contents back. Cmd-V is asynchronous: `post` only hands the event to the
    /// window server, and the app then has to be scheduled, receive it, and read
    /// the pasteboard. Restoring immediately would swap the contents out from
    /// under a paste that has not happened yet and the user would get their
    /// previous clipboard instead of their words. 150 ms is comfortably longer
    /// than a healthy app's turnaround while still being under the threshold
    /// where a person would notice their clipboard "stuck" on the transcript.
    private static let pasteboardReadDelay: Duration = .milliseconds(150)

    /// `kVK_ANSI_V`. Hard-coded rather than imported from Carbon's HIToolbox: it
    /// is a hardware-position code, fixed for all layouts, and the one Carbon
    /// symbol is not worth the framework.
    private static let virtualKeyV: CGKeyCode = 0x09

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
        _ text: String, restorePasteboard: Bool, autoPaste: Bool
    ) async -> SessionOutcome {

        // A hold that produced only silence or punctuation-free whitespace has
        // nothing to deliver, and clobbering the clipboard for it would be a
        // pure loss. Bail before touching any shared state.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.paste.debug("Nothing to deliver: transcript is empty.")
            return .nothing(why: .noSpeech)
        }

        let pasteboard = NSPasteboard.general

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

        guard pasteboard.setString(text, forType: .string) else {
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

        guard autoPaste else {
            Log.paste.debug("Auto-paste is off; leaving the transcript on the clipboard.")
            return .copied(text, why: .autoPasteDisabled)
        }

        // Nothing to paste into means nothing to paste: a posted Cmd-V would go
        // to whatever the window server decides is frontmost next, which could
        // be an app the user never pointed at.
        guard let target = NSWorkspace.shared.frontmostApplication else {
            Log.paste.debug("No frontmost application; copied instead of pasting.")
            return .copied(text, why: .noTarget)
        }
        // `Bundle.main.bundleIdentifier` is nil for the CLI target, so compare
        // only when we actually have an identity — otherwise a nil-equals-nil
        // match would make every paste look like a paste into ourselves.
        if let ourBundleID = Bundle.main.bundleIdentifier,
            target.bundleIdentifier == ourBundleID
        {
            Log.paste.debug("Wizard is frontmost; copied instead of pasting into ourselves.")
            return .copied(text, why: .noTarget)
        }

        // Synthetic events from an untrusted process are dropped by the window
        // server without any error reaching us. Posting anyway would look, from
        // the user's side, exactly like Wizard losing the transcript. The text
        // is on the clipboard, so this is `.copied`, not `.failed`.
        guard AXIsProcessTrusted() else {
            Log.paste.notice("Accessibility not granted; copied instead of pasting.")
            return .copied(text, why: .accessibilityDenied)
        }

        guard postCommandV() else {
            // The transcript is still on the clipboard, so the user has not lost
            // anything — but event creation failing is not normal, so it is
            // logged at error level rather than passed over.
            Log.paste.error("Could not synthesise Cmd-V; copied instead of pasting.")
            return .copied(text, why: .accessibilityDenied)
        }

        do {
            try await Task.sleep(for: pasteboardReadDelay)
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

        if restorePasteboard {
            restore(captured, to: pasteboard, ifChangeCountIs: ownedChangeCount)
        }
        return .pasted(text)
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

    // MARK: - Key event

    /// Post Cmd-V as a down/up pair. Returns false if the events could not be
    /// built; a successful post says nothing about whether the target acted on it.
    private static func postCommandV() -> Bool {
        // One source for both halves so the window server sees them as a single
        // device's keystroke rather than two unrelated events. Combined session
        // state is the table that reflects the real hardware the user is holding.
        guard let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
            let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else {
            return false
        }

        // Assignment, deliberately not `insert` into the live modifier state. The
        // user is almost certainly still holding the dictation chord (Fn by
        // default) at this instant — the paste happens on key release, and
        // fingers do not lift instantly. A held Fn riding along with Cmd-V is a
        // different chord as far as the target app is concerned, and events
        // created from a live source inherit whatever is physically down. Stating
        // the flags exactly guarantees the app sees a plain Cmd-V.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // The HID tap is the lowest point in the chain, so the event passes
        // through the same session taps and input methods as a real keystroke
        // instead of arriving somewhere downstream of them.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
