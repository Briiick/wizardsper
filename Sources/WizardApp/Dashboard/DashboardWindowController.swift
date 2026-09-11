import AppKit
import SwiftUI
import WizardKit

/// Hosts `DashboardView` in a real window.
///
/// A plain `NSWindowController` rather than a SwiftUI `Window` scene, because
/// Wizard's only scene is the menu bar: there is no `App` body to hang a
/// `Window` off, and SwiftUI scene lifecycle would fight the `LSUIElement`
/// behaviour the whole app depends on.
@MainActor
final class DashboardWindowController: NSWindowController {

    /// The name AppKit files the remembered frame under in `UserDefaults`.
    private static let autosaveName = "WizardDashboardWindow"

    /// Frame restoration happens once, on the first show, not in `init` — a
    /// window that is never shown should not consume the saved frame.
    private var hasRestoredFrame = false

    // `Settings` is qualified because SwiftUI exports a `Settings` scene type.
    init(settings: WizardKit.Settings, model: DashboardModel) {
        let hosting = NSHostingController(
            rootView: DashboardView(settings: settings, model: model))
        let window = NSWindow(contentViewController: hosting)

        super.init(window: window)

        // Configured after `super.init(window:)` on purpose: assigning a window
        // to a controller stamps the controller's own (empty) frame autosave
        // name onto it, which would undo `setFrameAutosaveName` set earlier.
        configure(window)
    }

    /// Never reached: this controller is only ever built in code. `required` by
    /// `NSCoding` conformance on `NSWindowController`, so it cannot simply be
    /// omitted.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("DashboardWindowController is not loaded from a nib.")
    }

    private func configure(_ window: NSWindow) {
        window.title = "Wizard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 720, height: 520)
        // The controller owns the window; without this, closing it would
        // deallocate the window out from under a controller that still holds it.
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .disallowed

        shouldCascadeWindows = false
        if !window.setFrameAutosaveName(Self.autosaveName) {
            // Only fails when another window already claimed the name. Position
            // is then not remembered, which is cosmetic but worth knowing about.
            Log.ui.error("Dashboard frame autosave name is already in use; frame will not persist.")
        }
    }

    /// Bring the dashboard forward.
    ///
    /// `LSUIElement` apps have no Dock tile and are never the active
    /// application, so `makeKeyAndOrderFront` on its own puts the window on
    /// screen behind whatever the user was using. `NSApp.activate()` is what
    /// actually makes it frontmost.
    override func showWindow(_ sender: Any?) {
        guard let window else {
            Log.ui.error("Dashboard controller has no window to show.")
            return
        }

        if !hasRestoredFrame {
            hasRestoredFrame = true
            if !window.setFrameUsingName(Self.autosaveName) {
                window.center()
            }
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(sender)
    }
}
