import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// One of the three TCC gates Wizard cannot work without.
///
/// Modelled as a value rather than three ad-hoc call sites because the
/// dashboard renders them as a uniform checklist: every row needs the same
/// four things — a name, a reason, somewhere to send the user, and the error
/// the coordinator raises when the gate is shut.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable, Codable {
    /// Capture the audio being dictated.
    case microphone
    /// See the dictation chord while another app is frontmost (the event tap).
    case inputMonitoring
    /// Post the synthetic Cmd-V that delivers the transcript.
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    /// One line, phrased as what Wizard does with it — this is what the user
    /// reads before deciding to grant it.
    public var reason: String {
        switch self {
        case .microphone:
            return "Records your voice while you hold the dictation key."
        case .inputMonitoring:
            return "Notices when the dictation key is held, even in other apps."
        case .accessibility:
            return "Pastes the transcript into whichever app you were typing in."
        }
    }

    /// The failure the coordinator surfaces when this gate is shut.
    public var error: WizardError {
        switch self {
        case .microphone: return .microphoneDenied
        case .inputMonitoring: return .inputMonitoringDenied
        case .accessibility: return .accessibilityDenied
        }
    }

    /// Deep link into the matching Privacy & Security pane.
    ///
    /// The anchor names are the internal TCC service names, not the visible
    /// titles: Input Monitoring is `Privacy_ListenEvent`, which is why this
    /// mapping is spelled out rather than derived from `rawValue`.
    public var settingsURL: URL? {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Logged under the subsystem that actually breaks when this gate is shut.
    var log: Logger {
        switch self {
        case .microphone: return Log.audio
        case .inputMonitoring: return Log.trigger
        case .accessibility: return Log.paste
        }
    }
}

/// A snapshot of all three gates, taken together.
///
/// The dashboard needs to show the whole checklist at once and re-read it every
/// time the app is reactivated (TCC changes take effect while the app runs and
/// send no notification), so the cheap thing to pass around is a value.
public struct PermissionStatus: Sendable, Equatable {
    public var microphone: Bool
    public var inputMonitoring: Bool
    public var accessibility: Bool

    /// Defaults to "nothing granted" so a UI model can hold a status before the
    /// first check has run, without having to make the property optional.
    public init(
        microphone: Bool = false, inputMonitoring: Bool = false, accessibility: Bool = false
    ) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    public subscript(kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone: return microphone
        case .inputMonitoring: return inputMonitoring
        case .accessibility: return accessibility
        }
    }

    /// Gates still shut, in the order the checklist shows them.
    public var missing: [PermissionKind] {
        PermissionKind.allCases.filter { self[$0] == false }
    }

    public var allGranted: Bool { missing.isEmpty }

    /// Everything Wizard needs to capture and transcribe. Accessibility is
    /// excluded: without it a session still succeeds, it just ends as `.copied`
    /// instead of `.pasted`.
    public var canDictate: Bool { microphone && inputMonitoring }

    @MainActor
    public static func current() -> PermissionStatus {
        PermissionStatus(
            microphone: Permissions.hasMicrophone,
            inputMonitoring: Permissions.hasInputMonitoring,
            accessibility: Permissions.hasAccessibility)
    }
}

/// The three TCC gates behind one façade.
///
/// Each one is checked and requested through a different framework with
/// different conventions — a preflight/request pair, a trusted-process check
/// that prompts asynchronously, and an AVFoundation status enum. Keeping them
/// apart in the UI layer meant three different mental models for the same
/// question; this collapses them to `has…` / `request…` / `openSystemSettings`.
///
/// Main-actor isolated because requesting any of them puts a system panel on
/// screen, and the dashboard is the only caller.
@MainActor
public enum Permissions {

    // MARK: - Input Monitoring

    /// Whether the event tap will be allowed to see keys in other apps.
    public static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts for Input Monitoring, once per install.
    ///
    /// Returns the access state *before* the user answers, so a `false` here
    /// means "not granted yet", not "refused". macOS shows this panel only the
    /// first time; afterwards `openSystemSettings(for: .inputMonitoring)` is
    /// the only route.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        let granted = CGRequestListenEventAccess()
        if !granted {
            Log.trigger.notice("Input Monitoring not granted yet; prompt requested.")
        }
        return granted
    }

    // MARK: - Accessibility

    /// Whether this process may post synthetic events into other apps.
    public static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for Accessibility, showing the "open System Settings" panel.
    ///
    /// The prompt is asynchronous and does not affect the return value, which
    /// is simply the current trust state — so the caller must poll
    /// `hasAccessibility` (on reactivation, say) rather than believe this.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // The literal key, not `kAXTrustedCheckOptionPrompt`: that symbol is
        // imported from C as a mutable global `var`, which Swift 6 refuses to
        // read from concurrent code. Its value is this string.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.paste.notice("Accessibility not granted yet; prompt requested.")
        }
        return trusted
    }

    // MARK: - Microphone

    public static var microphoneAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var hasMicrophone: Bool {
        microphoneAuthorization == .authorized
    }

    /// Asks for the microphone if it has never been asked for.
    ///
    /// `.denied` and `.restricted` are terminal: AVFoundation will not show the
    /// panel a second time, so re-requesting would look like a hang. Those
    /// cases return `false` and the caller should offer System Settings.
    @discardableResult
    public static func requestMicrophone() async -> Bool {
        switch microphoneAuthorization {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            Log.audio.notice("Microphone access is denied or restricted; System Settings required.")
            return false
        @unknown default:
            Log.audio.error("Unknown microphone authorization status; treating as not granted.")
            return false
        }
    }

    // MARK: - Escape hatch

    /// Opens the Privacy & Security pane for one gate.
    ///
    /// The only recovery once a gate has been refused, since none of the
    /// request APIs will prompt twice.
    public static func openSystemSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else {
            kind.log.error(
                "No System Settings URL for \(kind.rawValue, privacy: .public)")
            return
        }
        if !NSWorkspace.shared.open(url) {
            kind.log.error(
                "System Settings refused to open \(url.absoluteString, privacy: .public)")
        }
    }
}
