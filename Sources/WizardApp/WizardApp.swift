import AppKit
import Observation
import SwiftUI
import WizardKit

/// Menu-bar-only entry point.
///
/// Hand-rolled rather than a SwiftUI `App` because Wizard has no window at
/// launch, no main menu, and must never activate: a `MenuBarExtra` scene still
/// builds an application that wants to come forward, and coming forward would
/// take focus away from the app the transcript is about to be pasted into.
@main
enum WizardMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // .accessory, matching LSUIElement: no Dock tile, no menu bar takeover,
        // and the app is never the active application unless the dashboard is
        // explicitly opened.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = Settings.shared
    private let history = TranscriptionHistory.shared
    private let coordinator = DictationCoordinator()

    private let status = AppStatusModel()
    private let dashboardModel = DashboardModel()
    private let flowModel = FlowBarModel()

    private var menuBar: MenuBarController?
    private var flowBar: FlowBarPanel?
    private var dashboard: DashboardWindowController?
    private var hotkey: HotkeyMonitor?

    private var modelTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?

    /// How long the pill lingers after the outcome lands. A failure stays up
    /// longer because its text is the only place the reason is shown.
    private let successLinger: TimeInterval = 1.1
    private let failureLinger: TimeInterval = 3.0

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try WizardPaths.ensureApplicationSupport()
        } catch {
            Log.ui.error("Could not create the support directory: \(error.localizedDescription)")
        }

        buildInterface()
        wireCoordinator()
        wireDashboard()
        observeSettings()

        Task { await history.load() }

        refreshPermissions()
        startHotkey()
        loadModel(settings.tier)

        // Ask for the microphone now, at launch, rather than at the first hold.
        // `AudioCapture.start()` deliberately cannot prompt: the prompt is async
        // and by the time it is answered the key is long since down, so a
        // first-run session would fail with `.microphoneDenied` instead of
        // recording. Getting the grant out of the way here means the first hold
        // is a normal one.
        Task { @MainActor in
            // Deferred one run-loop turn past launch. Asking in
            // applicationDidFinishLaunching itself fires before the process has
            // finished registering with the window server, and the prompt is
            // then dismissed out from under the user and reported as a denial.
            try? await Task.sleep(for: .milliseconds(600))
            let before = AudioCapture.microphoneAuthorization.rawValue
            Log.audio.info("Microphone authorisation before request: \(before, privacy: .public)")
            do {
                try await AudioCapture.ensureMicrophoneAccess()
                Log.audio.info("Microphone authorised")
            } catch let error as WizardError {
                self.status.statusText = error.errorDescription ?? "Microphone unavailable"
            } catch {
                self.status.statusText = error.localizedDescription
            }
            self.refreshPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.cancel()
        hotkey?.stop()
        modelTask?.cancel()
        phaseTask?.cancel()
    }

    /// The app has no windows, so the default "quit when the last window closes"
    /// would quit the moment the dashboard is dismissed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Interface

    private func buildInterface() {
        status.chord = settings.chord
        status.activeTier = settings.tier
        status.onOpenDashboard = { [weak self] in self?.openDashboard() }
        status.onQuit = { NSApp.terminate(nil) }
        status.onRetryPermission = { [weak self] raw in
            guard let kind = PermissionKind(rawValue: raw) else { return }
            self?.request(kind)
        }

        menuBar = MenuBarController(status: status)

        // The meter is pulled at 60 Hz by the bar rather than pushed from the
        // audio thread; this closure is the whole of the coupling between them.
        flowModel.attach(levelSource: { [weak self] in self?.coordinator.currentLevel() ?? 0 })
        flowBar = FlowBarPanel(model: flowModel)
    }

    private func wireCoordinator() {
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            self.menuBar?.setListening(state == .listening)
            switch state {
            case .listening:
                self.flowModel.beginSession()
                if self.settings.showFlowBar { self.flowBar?.show() }
            case .finishing, .idle:
                break
            }
        }

        coordinator.onOutcome = { [weak self] outcome in
            guard let self else { return }
            self.flowModel.finish(outcome)
            if let text = outcome.transcript { self.status.lastTranscript = text }
            // Exactly one outcome per session reaches here, which is what lets
            // the bar dismiss on a timer instead of guessing when it is done.
            self.flowBar?.dismiss(
                after: outcome.isFailure ? self.failureLinger : self.successLinger)
        }

        // The coordinator's snapshot carries the live partial transcript.
        observe { [weak self] in self?.coordinator.snapshot ?? .idle } onChange: { [weak self] snapshot in
            self?.flowModel.apply(snapshot)
        }
        observe { [weak self] in self?.coordinator.statusText ?? "" } onChange: { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.status.statusText = text
            self.status.isReady = self.coordinator.isReady
        }
    }

    private func wireDashboard() {
        dashboardModel.onInstall = { [weak self] tier in self?.loadModel(tier) }
        dashboardModel.onCancel = { [weak self] in self?.modelTask?.cancel() }
        dashboardModel.onRefresh = { [weak self] in self?.refreshModelStatus() }
        dashboardModel.onRemove = { [weak self] tier in
            guard let self else { return }
            Task {
                do {
                    try await ModelInstaller.shared.remove(tier)
                    self.refreshModelStatus()
                } catch {
                    self.dashboardModel.lastError = error.localizedDescription
                }
            }
        }
        dashboardModel.onImportArchive = { [weak self] url in
            guard let self else { return }
            let tier = self.settings.tier
            self.modelTask?.cancel()
            self.modelTask = Task { @MainActor in
                do {
                    let directory = try await ModelInstaller.shared.importZip(at: url, as: tier)
                    await self.coordinator.prepare(tier: tier, directory: directory)
                    self.refreshModelStatus()
                } catch {
                    self.dashboardModel.lastError = error.localizedDescription
                }
            }
        }
        dashboardModel.onRevealInFinder = { tier in
            NSWorkspace.shared.activateFileViewerSelecting([WizardPaths.modelDirectory(for: tier)])
        }
        refreshModelStatus()
    }

    private func openDashboard() {
        menuBar?.closePopover()
        if dashboard == nil {
            dashboard = DashboardWindowController(settings: settings, model: dashboardModel)
        }
        refreshModelStatus()
        refreshPermissions()
        dashboard?.showWindow(nil)
    }

    // MARK: - Trigger

    private func startHotkey() {
        hotkey?.stop()
        let monitor = HotkeyMonitor(
            chord: settings.chord,
            onPress: { [weak self] in self?.coordinator.begin() },
            onRelease: { [weak self] in self?.coordinator.end() })
        do {
            try monitor.start()
            hotkey = monitor
            Log.ui.info("Watching for \(self.settings.chord.display, privacy: .public)")
        } catch let error as WizardError {
            hotkey = nil
            status.statusText = error.errorDescription ?? "Cannot watch the keyboard"
            Log.ui.error("Hotkey tap failed: \(self.status.statusText, privacy: .public)")
        } catch {
            hotkey = nil
            status.statusText = error.localizedDescription
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        status.permissions = PermissionStatus.current()
    }

    private func request(_ kind: PermissionKind) {
        Task { @MainActor in
            switch kind {
            case .microphone:
                _ = await Permissions.requestMicrophone()
            case .inputMonitoring:
                _ = Permissions.requestInputMonitoring()
            case .accessibility:
                _ = Permissions.requestAccessibility()
            }
            self.refreshPermissions()
            // Input Monitoring is the one that gates the event tap, so a grant
            // is only useful if the tap is then actually created.
            if kind == .inputMonitoring, self.hotkey == nil {
                self.startHotkey()
            }
            Permissions.openSystemSettings(for: kind)
        }
    }

    // MARK: - Model

    private func loadModel(_ tier: NemotronTier) {
        modelTask?.cancel()
        phaseTask?.cancel()
        status.isReady = false
        status.activeTier = tier
        dashboardModel.lastError = nil

        phaseTask = Task { @MainActor in
            for await phase in await ModelInstaller.shared.events() {
                self.apply(phase)
            }
        }

        modelTask = Task { @MainActor in
            do {
                let directory = try await ModelInstaller.shared.install(tier)
                guard !Task.isCancelled else { return }
                await self.coordinator.prepare(tier: tier, directory: directory)
                self.status.isReady = self.coordinator.isReady
                self.status.statusText = self.coordinator.statusText
                self.status.installProgress = nil
                self.refreshModelStatus()
            } catch is CancellationError {
                self.status.statusText = "Download cancelled"
                self.status.installProgress = nil
            } catch let error as WizardError {
                let message = error.errorDescription ?? "Model unavailable"
                self.status.statusText = message
                self.dashboardModel.lastError = message
                self.status.installProgress = nil
            } catch {
                self.status.statusText = error.localizedDescription
                self.dashboardModel.lastError = error.localizedDescription
                self.status.installProgress = nil
            }
            self.phaseTask?.cancel()
        }
    }

    private func apply(_ phase: ModelInstaller.Phase) {
        status.installProgress = phase.fraction
        dashboardModel.progress = phase.fraction
        switch phase {
        case .idle:
            break
        case .listing:
            status.statusText = "Checking model files…"
        case .downloading(let completed, let total, _):
            let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            status.statusText = "Downloading \(done) of \(all)"
        case .verifying:
            status.statusText = "Verifying model files…"
        case .ready:
            status.statusText = "Ready"
        case .failed(let message):
            status.statusText = message
            dashboardModel.lastError = message
        }
        dashboardModel.phaseText = status.statusText
    }

    private func refreshModelStatus() {
        let tier = settings.tier
        Task { @MainActor in
            var present: Set<NemotronTier> = []
            for candidate in NemotronTier.allCases
            where await ModelInstaller.shared.isInstalled(candidate) {
                present.insert(candidate)
            }
            self.dashboardModel.installedTiers = present
            self.dashboardModel.isInstalled = present.contains(tier)
            self.dashboardModel.sizeOnDisk = Self.directorySize(
                WizardPaths.modelDirectory(for: tier))
        }
    }

    private static func directorySize(_ url: URL) -> Int64? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])
        else { return nil }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total > 0 ? total : nil
    }

    // MARK: - Settings

    private func observeSettings() {
        observe { [weak self] in self?.settings.chord ?? .fn } onChange: { [weak self] chord in
            guard let self else { return }
            self.status.chord = chord
            if let hotkey = self.hotkey {
                hotkey.updateChord(chord)
            } else {
                self.startHotkey()
            }
        }
        observe { [weak self] in self?.settings.tier ?? .default } onChange: { [weak self] tier in
            guard let self, tier != self.coordinator.activeTier else { return }
            self.loadModel(tier)
        }
        observe { [weak self] in self?.settings.historyRetentionDays ?? 7 } onChange: {
            [weak self] days in
            self?.history.prune(retentionDays: days)
        }
    }

    /// Re-arming observation helper.
    ///
    /// `withObservationTracking` fires its handler once and then stops, so a
    /// long-lived observer has to re-register. It re-arms by calling itself
    /// rather than through a nested function, because the handler is `@Sendable`
    /// and a local function cannot be captured by one.
    ///
    /// The value is read again on the main actor inside the handler: `onChange`
    /// fires *before* the mutation is visible, so reading it there would hand
    /// back the old value.
    private func observe<Value: Equatable>(
        _ read: @escaping @Sendable @MainActor () -> Value,
        onChange: @escaping @Sendable @MainActor (Value) -> Void
    ) {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            Task { @MainActor in
                onChange(read())
                self?.observe(read, onChange: onChange)
            }
        }
    }
}
