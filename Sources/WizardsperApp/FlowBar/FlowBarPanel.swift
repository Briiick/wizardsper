import AppKit
import QuartzCore
import SwiftUI
import WizardsperKit

/// The window the pill lives in, for as long as the dictation key is held.
///
/// It is an `NSPanel` with `.nonactivatingPanel` — and never key, never main —
/// because showing it must not move focus. The user is holding a key inside some
/// other app; they keep typing into that app while the bar is up, and the Cmd-V
/// at the end of the session is delivered to whatever was frontmost. If this
/// window ever took focus, the frontmost app would become Wizardsper and the
/// dictated text would be pasted into the flow bar's own process instead of the
/// document the user was writing.
@MainActor
final class FlowBarPanel: NSPanel {

    private let model: FlowBarModel

    /// Pending "fade out in N seconds" work, cancelled by the next `show()`.
    private var dismissTask: Task<Void, Never>?

    /// Bumped by every show and every dismiss, so a fade that is already running
    /// can tell it has been superseded. Without it, a `show()` that lands during
    /// a fade-out would be undone a moment later when that fade's completion
    /// handler ordered the panel out from under the new session.
    private var fadeGeneration = 0

    private static let fadeInDuration: TimeInterval = 0.12
    private static let fadeOutDuration: TimeInterval = 0.22

    init(model: FlowBarModel) {
        self.model = model
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: FlowBarMetrics.panelWidth, height: FlowBarMetrics.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        // Nothing in the pill is clickable, and a click that landed here would
        // be a click stolen from the app underneath.
        ignoresMouseEvents = true
        // Above ordinary and full-screen windows, below the menu bar.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Panels hide themselves when their application deactivates. Wizardsper is a
        // menu bar agent that is almost never the active app, so leaving that on
        // would hide the bar in precisely the situation it exists for.
        hidesOnDeactivate = false
        // The panel outlives every session; closing must not deallocate it.
        isReleasedWhenClosed = false
        // We run our own fade, and AppKit's default panel animation fights it.
        animationBehavior = .none
        alphaValue = 0

        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    /// The panel is only ever built in code. No nib contains one, and a decoded
    /// instance would have no model to render, so decoding fails rather than
    /// producing a window that can never show anything.
    required init?(coder: NSCoder) {
        Log.ui.error("FlowBarPanel cannot be decoded from an archive; it is built in code.")
        return nil
    }

    // Never key, never main. See the note on the type: focus must stay with the
    // app the user is dictating into, because that is where the paste lands.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Showing

    /// Put the bar on screen. Safe to call while a previous dismissal is still
    /// fading out, which is the common case when the user dictates twice in
    /// quick succession.
    func show() {
        dismissTask?.cancel()
        dismissTask = nil
        // Retires any fade already in flight: its completion handler checks this
        // and will leave the window alone now that it is wanted again.
        fadeGeneration &+= 1

        guard let screen = activeScreen() else {
            Log.ui.error("No screen available to place the flow bar; skipping display.")
            return
        }
        // Recomputed on every show, not once at construction: the active screen
        // changes between sessions when the user moves to another display, and a
        // display can be unplugged while Wizardsper sits idle in the menu bar.
        position(on: screen)

        model.startSampling()
        // `orderFrontRegardless` shows a window without activating the app —
        // `makeKeyAndOrderFront` would do exactly what this panel must not do.
        orderFrontRegardless()
        // The window is transparent, so AppKit derives the drop shadow from the
        // drawn content and caches that shape; a move invalidates the cache.
        invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    // MARK: - Dismissing

    /// Fade the bar away, after a delay so the outcome stays readable.
    ///
    /// The delay is a `Task` rather than a timer so that the next `show()` can
    /// cancel it outright: a queued dismissal that fired mid-session would take
    /// the bar down while the user was still speaking.
    func dismiss(after delay: TimeInterval = 0) {
        dismissTask?.cancel()
        fadeGeneration &+= 1
        let generation = fadeGeneration

        // Inherits the main actor from this method, so the body needs no hop.
        dismissTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, self.fadeGeneration == generation else { return }
            self.fadeOut(generation: generation)
        }
    }

    /// Take the bar down now, with no fade. For quitting, where an animation
    /// would outlive the run loop that is meant to be running it.
    func dismissImmediately() {
        dismissTask?.cancel()
        dismissTask = nil
        fadeGeneration &+= 1
        orderOut(nil)
        alphaValue = 0
        model.stopSampling()
    }

    private func fadeOut(generation: Int) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeOutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.fadeGeneration == generation else { return }
                    self.orderOut(nil)
                    // The window is gone, so there is nothing left to redraw:
                    // stop the 60 Hz sampler until the next session.
                    self.model.stopSampling()
                }
            })
    }

    // MARK: - Placement

    /// The screen the pointer is on, which is the screen the user is looking at.
    /// `NSScreen.main` is the fallback and means "the screen with the key
    /// window", which for a menu bar agent is usually still the right guess.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func position(on screen: NSScreen) {
        // `visibleFrame`, not `frame`: it already excludes the Dock and the menu
        // bar, so sitting just above its bottom edge clears the Dock at any size
        // and on any edge the user has put it.
        let area = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(
            NSPoint(
                x: (area.midX - size.width / 2).rounded(),
                y: (area.minY + FlowBarMetrics.bottomInset).rounded()))
    }
}
