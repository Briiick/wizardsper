import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WizardKit

/// The dashboard's half of the model-management contract.
///
/// The dashboard must be able to start a download, cancel one, delete a tier and
/// import a hand-downloaded archive — but it must not *be* the installer. Owning
/// a `ModelInstaller` here would mean a window that cancels its own downloads
/// when it closes, and two places that disagree about what is installed. So the
/// view renders whatever this object says and calls back out through closures;
/// the app delegate wires them to the real installer and pushes progress in.
@MainActor
@Observable
final class DashboardModel {

    /// One human-readable line: "Not installed", "Downloading… 240 MB of 630 MB",
    /// "Unpacking encoder", "Installed".
    var phaseText = "Not installed"

    /// 0…1 while work is in flight, `nil` when idle. Drives both the progress
    /// bar and which buttons are offered.
    var progress: Double?

    var isInstalled = false

    /// Bytes the active tier occupies, or `nil` when it is not installed.
    var sizeOnDisk: Int64?

    /// The last installer failure, already localised. Cleared by the integrator
    /// when a new attempt starts.
    var lastError: String?

    var onInstall: (NemotronTier) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onRemove: (NemotronTier) -> Void = { _ in }
    /// Hand a user-supplied `.zip` to the installer to unpack in place.
    var onImportArchive: (URL) -> Void = { _ in }
    var onRevealInFinder: (NemotronTier) -> Void = { _ in }
    /// Re-read what is on disk. Called whenever the model pane appears.
    var onRefresh: () -> Void = {}

    init() {}
}

/// Wizard's settings, model management and history in one window.
///
/// A sidebar rather than a `TabView`: the three panes have very different
/// shapes — a long form, a short status page, a scrolling list — and tabs would
/// force them all into the same width and the same scroll behaviour.
struct DashboardView: View {

    // Qualified: SwiftUI exports its own `Settings` scene type.
    @Bindable var settings: WizardKit.Settings
    let model: DashboardModel

    @State private var pane: Pane? = .settings
    @State private var chordWarning: String?
    @State private var loginItemError: String?

    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case settings, models, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .settings: return "Settings"
            case .models: return "Model"
            case .history: return "History"
            }
        }

        var symbol: String {
            switch self {
            case .settings: return "gearshape"
            case .models: return "cpu"
            case .history: return "clock"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(minWidth: 460, minHeight: 420)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $pane) {
            ForEach(Pane.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                HStack(spacing: 6) {
                    ChordKeyCap(text: settings.chord.display)
                    Text("to dictate")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .settings {
        case .settings: settingsPane
        case .models: modelPane
        case .history: HistoryListView()
        }
    }

    // MARK: - Settings pane

    private var settingsPane: some View {
        Form {
            Section {
                chordChips
                if let chordWarning {
                    Label(chordWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Dictation key")
            } footer: {
                Text(
                    "Hold \(settings.chord.display) anywhere to dictate. Modifiers only — holding the chord never types a character into the app you are in."
                )
            }

            Section {
                ForEach(NemotronTier.allCases) { tier in
                    tierRow(tier)
                }
            } header: {
                Text("Recognition")
            } footer: {
                Text(
                    "Smaller chunks answer sooner; larger chunks hear more context before committing to a word."
                )
            }

            Section("After a hold") {
                Toggle("Paste into the frontmost app", isOn: $settings.pasteAutomatically)
                Toggle("Put the old clipboard back afterwards", isOn: $settings.restorePasteboard)
                    .disabled(!settings.pasteAutomatically)
                Toggle("Show the flow bar while dictating", isOn: $settings.showFlowBar)
            }

            Section("History") {
                Toggle("Keep a transcript history", isOn: $settings.keepHistory)
                Stepper(value: $settings.historyRetentionDays, in: 0...90) {
                    HStack {
                        Text("Delete transcripts after")
                        Spacer(minLength: 8)
                        Text(retentionLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!settings.keepHistory)
            }

            Section("Trigger") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Minimum hold")
                        Spacer(minLength: 8)
                        Text("\(Int((settings.minimumHoldSeconds * 1000).rounded())) ms")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.minimumHoldSeconds, in: 0...1, step: 0.05)
                    Text("Anything shorter counts as an accidental tap and produces nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Startup") {
                Toggle("Launch Wizard at login", isOn: launchAtLogin)
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reconcileLaunchAtLogin() }
    }

    private var retentionLabel: String {
        switch settings.historyRetentionDays {
        case 0: return "Never"
        case 1: return "1 day"
        case let days: return "\(days) days"
        }
    }

    // MARK: - Chord picker

    private var chordChips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 124), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Chord.Modifier.allCases) { modifier in
                chordChip(modifier)
            }
        }
        .padding(.vertical, 3)
    }

    private func chordChip(_ modifier: Chord.Modifier) -> some View {
        let isOn = settings.chord.modifiers.contains(modifier)
        return Button {
            toggle(modifier)
        } label: {
            HStack(spacing: 7) {
                Text(modifier.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, alignment: .center)
                Text(modifier.label)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOn ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isOn ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// An empty chord would match every event flag set, so the last modifier can
    /// be replaced but never removed. Refusing silently would look like a broken
    /// button, hence the warning line.
    private func toggle(_ modifier: Chord.Modifier) {
        var next = settings.chord.modifiers
        if next.contains(modifier) {
            guard next.count > 1 else {
                chordWarning = "The dictation key needs at least one modifier."
                return
            }
            next.remove(modifier)
        } else {
            next.insert(modifier)
        }
        chordWarning = nil
        settings.chord = Chord(next)
    }

    private func tierRow(_ tier: NemotronTier) -> some View {
        let isOn = settings.tier == tier
        return Button {
            settings.tier = tier
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.displayName)
                    Text("Reported WER \(tier.reportedWER)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Launch at login

    /// Writes through `SMAppService` first and only records the setting if the
    /// system agreed, so the toggle can never claim a state launchd does not
    /// have.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { enabled in setLaunchAtLogin(enabled) })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status != .notRegistered {
                // unregister() throws kSMErrorJobNotFound when there is nothing
                // registered, which is not a failure worth showing anyone.
                try service.unregister()
            }
            settings.launchAtLogin = enabled
            loginItemError = nil
        } catch {
            Log.ui.error(
                "Login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            loginItemError = "macOS refused the login item: \(error.localizedDescription)"
            // Fall back to what launchd actually thinks, not to what was asked.
            settings.launchAtLogin = service.status == .enabled
        }
    }

    /// The user can revoke a login item in System Settings without telling us,
    /// so the stored flag is re-derived every time the pane opens.
    private func reconcileLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let actual = status == .enabled
        if settings.launchAtLogin != actual {
            settings.launchAtLogin = actual
        }
        loginItemError =
            status == .requiresApproval
            ? "Approve Wizard under Login Items in System Settings." : nil
    }

    // MARK: - Model pane

    private var modelPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                activeModelCard

                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                        Text(model.phaseText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                modelActions

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed at")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(.tertiary)
                    Text(WizardPaths.modelDirectory(for: settings.tier).path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(26)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.onRefresh() }
    }

    private var activeModelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.tier.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                statusPill
            }

            HStack(spacing: 18) {
                fact("Chunk", "\(settings.tier.chunkMilliseconds) ms")
                fact("Reported WER", settings.tier.reportedWER)
                fact("On disk", sizeText)
            }

            Text(model.phaseText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.secondary.opacity(0.09))
        )
    }

    private var statusPill: some View {
        let installed = model.isInstalled
        return Text(installed ? "Installed" : "Not installed")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((installed ? Color.green : Color.orange).opacity(0.18))
            )
            .foregroundStyle(installed ? Color.green : Color.orange)
    }

    private func fact(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }

    private var sizeText: String {
        guard let bytes = model.sizeOnDisk, bytes > 0 else { return "—" }
        return bytes.formatted(.byteCount(style: .file))
    }

    @ViewBuilder private var modelActions: some View {
        HStack(spacing: 10) {
            if model.progress != nil {
                Button("Cancel") { model.onCancel() }
            } else if model.isInstalled {
                Button {
                    model.onRemove(settings.tier)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else {
                Button {
                    model.onInstall(settings.tier)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                importArchive()
            } label: {
                Label("Import .zip…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.progress != nil)

            Button {
                model.onRevealInFinder(settings.tier)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!model.isInstalled)

            Spacer(minLength: 0)
        }
    }

    /// Lets someone who already downloaded the archive by hand — or who is
    /// offline — install without going through the network path at all.
    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Choose a .zip containing \(settings.tier.subdirectory)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.onImportArchive(url)
    }
}

#Preview("Dashboard") {
    DashboardView(settings: .previewSettings(), model: .previewModel())
}

extension WizardKit.Settings {
    /// Previews must not scribble on the real defaults domain.
    fileprivate static func previewSettings() -> WizardKit.Settings {
        WizardKit.Settings(
            defaults: UserDefaults(suiteName: "com.bricken.wizard.preview") ?? .standard)
    }
}

extension DashboardModel {
    fileprivate static func previewModel() -> DashboardModel {
        let model = DashboardModel()
        model.isInstalled = true
        model.phaseText = "Installed and verified."
        model.sizeOnDisk = 628_144_000
        return model
    }
}
