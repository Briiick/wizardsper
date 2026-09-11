import AppKit
import Observation
import SwiftUI
import WizardsperKit

/// Everything the menu bar and the popover need to draw themselves, in one
/// observable box.
///
/// Wizardsper is an `LSUIElement` app: the status item is the only thing on screen
/// most of the time, and it has to reflect work happening in an audio actor, a
/// model installer and a permissions probe — none of which should know that a
/// popover exists. They push into this model instead, and the closures below
/// carry intent back out. Everything is defaulted so a `#Preview` can build one
/// with no wiring at all.
@MainActor
@Observable
final class AppStatusModel {

    /// True once a model is loaded *and* the trigger is armed — the green dot.
    var isReady = false

    /// One line describing whatever is currently true: "Ready", "Downloading
    /// 560 ms model", "Microphone access needed".
    var statusText = "Starting up…"

    /// 0…1 while a model is downloading or unpacking, `nil` when nothing is in
    /// flight. The popover shows a progress bar exactly when this is non-nil.
    var installProgress: Double?

    var isListening = false

    var permissions = PermissionStatus()

    /// The text of the most recent successful session, for the copy affordance.
    var lastTranscript: String?

    var activeTier: NemotronTier = .default

    /// Mirrors `Settings.chord`. Held here rather than read from `Settings` in
    /// the view so the popover has exactly one source of truth.
    var chord: Chord = .fn

    var onOpenDashboard: () -> Void = {}
    var onQuit: () -> Void = {}

    /// Asked to re-check — and, where macOS still allows it, re-prompt for —
    /// one permission. The argument is a `PermissionKind` raw value; a `String`
    /// rather than the enum so this model stays a plain bag of display state.
    var onRetryPermission: (String) -> Void = { _ in }

    init() {}
}

/// Owns the `NSStatusItem`: its icon, its popover, and its right-click menu.
///
/// This is deliberately not a singleton and not an `NSApplicationDelegate`
/// extension. It takes the one model it renders and nothing else, so the app
/// delegate decides what `onOpenDashboard` and `onQuit` actually do and this
/// class stays testable by construction.
@MainActor
final class MenuBarController: NSObject {

    private let status: AppStatusModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hosting: NSHostingController<PopoverView>

    init(status: AppStatusModel) {
        self.status = status
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let hosting = NSHostingController(rootView: PopoverView(status: status))
        // Lets the hosting controller publish its SwiftUI fitting size as
        // `preferredContentSize`, which NSPopover tracks. Without it the popover
        // keeps whatever size it was first given and clips when the permission
        // list or the transcript preview grows.
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting

        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting

        configureButton()
        observeListening()
    }

    // MARK: - Public surface

    /// Swap the icon between idle and listening. Also updates the model, so a
    /// caller that only knows about the menu bar still keeps the popover honest.
    func setListening(_ listening: Bool) {
        status.isListening = listening
        refreshIcon()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    // MARK: - Status item

    private func configureButton() {
        guard let button = statusItem.button else {
            // The only way this happens is a status bar with no room left. Not
            // fatal — the app still dictates — but the user has no affordance,
            // so it must not pass silently.
            Log.ui.error("NSStatusBar gave no button; Wizardsper has no menu bar item.")
            return
        }
        button.image = Self.icon(listening: false)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.toolTip = "Wizardsper"
        button.setAccessibilityLabel("Wizardsper")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // A status item button only reports left-mouse-down by default; both of
        // these are needed to tell a plain click from a menu click.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Wizardsper's own mark rather than an SF Symbol, so the two states are one
    /// glyph with its arcs opened rather than two unrelated symbols. Drawn in
    /// code, so it can never come back nil the way a missing symbol name does.
    private static func icon(listening: Bool) -> NSImage {
        WizardsperIcon.image(listening: listening)
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(listening: status.isListening)
        button.image?.isTemplate = true
        button.toolTip = status.isListening ? "Wizardsper — listening" : "Wizardsper"
    }

    /// Keep the AppKit icon in step with the observable model.
    ///
    /// `withObservationTracking` fires once and then goes dead, so the handler
    /// re-arms it. It re-arms in exactly one place — re-arming from
    /// `refreshIcon` as well would double the number of live observations on
    /// every change.
    private func observeListening() {
        withObservationTracking {
            _ = status.isListening
        } onChange: { [weak self] in
            // onChange runs *before* the new value is stored, and possibly off
            // the main actor, so the read has to happen in a hop.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshIcon()
                self.observeListening()
            }
        }
    }

    // MARK: - Click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu =
            event.map { $0.type == .rightMouseUp || $0.modifierFlags.contains(.control) } ?? false
        if wantsMenu {
            presentMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else {
            Log.ui.error("Cannot show the popover: the status item has no button.")
            return
        }
        // An LSUIElement app is never the active app, so without this the
        // popover draws in its inactive appearance and the first click on any of
        // its buttons is spent activating Wizardsper instead.
        NSApp.activate()
        sizePopoverToContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The popover is sized from the SwiftUI content, never from a constant.
    /// `sizingOptions` handles later growth; this seeds the first presentation,
    /// which would otherwise animate open at the hosting view's zero size.
    private func sizePopoverToContent() {
        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        popover.contentSize = fitting
    }

    // MARK: - Menu

    private func presentMenu() {
        popover.performClose(nil)

        // NSStatusItem has no "pop this menu now" call. Assigning the menu and
        // clicking the button is the supported route; it must be cleared again
        // or every later left-click opens the menu instead of the popover.
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let dashboard = NSMenuItem(
            title: "Dashboard…", action: #selector(openDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(dashboard)

        let permissions = NSMenuItem(
            title: "Check Permissions", action: #selector(checkPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Wizardsper", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openDashboard() {
        status.onOpenDashboard()
    }

    @objc private func checkPermissions() {
        // Sending the first shut gate re-probes all three on the way through and
        // gives the user somewhere to go. With nothing missing there is nothing
        // to request, so the checklist in the popover is the answer.
        if let missing = status.permissions.missing.first {
            status.onRetryPermission(missing.rawValue)
        } else {
            togglePopover()
        }
    }

    @objc private func quit() {
        status.onQuit()
    }

    // No deinit removes the status item: the controller lives as long as the
    // process, and a deinit is nonisolated so it could not touch NSStatusBar
    // safely anyway.
}
