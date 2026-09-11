import SwiftUI
import WizardsperKit

/// Gain calibration: a slider, a live meter, and a verdict on what the meter is
/// showing.
///
/// A bare slider would be worse than nothing here, because this control is not
/// monotonic. Measurement (see `GainBox`) says gain rescues a microphone whose
/// signal is close to its own noise floor — 23.5% WER down to 5.9% — and
/// *damages* a healthy one by clipping it, 0.0% up to 5.9%. A user given a
/// slider and no feedback will reasonably assume more is better, and make their
/// transcripts worse.
///
/// So the slider never appears without the meter. The meter runs capture with no
/// recogniser attached, draws the usable band behind the level so the target is
/// visible before a word is spoken, and says plainly when the setting has gone
/// too far in either direction.
struct InputGainSection: View {
    // Qualified: SwiftUI declares its own `Settings` scene type.
    @Bindable var settings: WizardsperKit.Settings
    let model: DashboardModel

    @State private var isMonitoring = false
    @State private var level: Float = 0
    @State private var peak: Float = 0
    @State private var timer: Timer?

    /// RMS bands for speech at the recogniser's input. Below `quiet` the
    /// log-mel surface sits close enough to the model's noise floor that the
    /// RNN-T emits blanks; above `hot` the gain stage is clipping.
    private static let quiet: Float = 0.02
    private static let hot: Float = 0.45

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { GainBox.decibels(fromLinear: Float(settings.inputGain)) },
                        set: { settings.inputGain = Double(GainBox.linear(fromDecibels: $0)) }
                    ),
                    in: GainBox.minimumDecibels...GainBox.maximumDecibels
                )
                Text(decibelLabel)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 62, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                meter
                HStack {
                    Toggle(isOn: $isMonitoring) {
                        Label(
                            isMonitoring ? "Listening…" : "Test microphone",
                            systemImage: isMonitoring ? "stop.circle" : "waveform.badge.mic")
                    }
                    .toggleStyle(.button)
                    Spacer()
                    if isMonitoring {
                        Text(verdict)
                            .font(.callout)
                            .foregroundStyle(verdictColor)
                    }
                    Button("Reset to 0 dB") { settings.inputGain = 1 }
                        .buttonStyle(.link)
                        .disabled(abs(settings.inputGain - 1) < 0.001)
                }
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text(
                "Speak normally with the meter running and adjust until the level sits in the green band. More is not better — gain past the band clips, and clipping costs more accuracy than a quiet signal does. Leave it at 0 dB unless the meter says otherwise."
            )
        }
        .onChange(of: isMonitoring) { _, monitoring in
            monitoring ? startMonitoring() : stopMonitoring()
        }
        .onDisappear(perform: stopMonitoring)
    }

    // MARK: - Meter

    private var meter: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                // The usable band, drawn behind the level so the target is
                // visible before the user has spoken a word.
                Capsule()
                    .fill(Color.green.opacity(0.18))
                    .frame(
                        width: max(0, width * CGFloat(Self.hot - Self.quiet)),
                        height: 10
                    )
                    .offset(x: width * CGFloat(Self.quiet))
                Capsule()
                    .fill(verdictColor.gradient)
                    .frame(width: max(2, width * CGFloat(min(level, 1))), height: 10)
                // Peak hold, so a short syllable does not vanish before it can
                // be read.
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: 2, height: 14)
                    .offset(x: width * CGFloat(min(peak, 1)) - 1)
                    .opacity(peak > 0.005 ? 1 : 0)
            }
            .frame(height: 14)
            .animation(.linear(duration: 0.05), value: level)
        }
        .frame(height: 14)
    }

    private var decibelLabel: String {
        let dB = GainBox.decibels(fromLinear: Float(settings.inputGain))
        return String(format: "%+.0f dB", dB)
    }

    private var verdict: String {
        if peak < 0.004 { return "No signal" }
        if peak < Self.quiet { return "Too quiet — raise the gain" }
        if peak > Self.hot { return "Clipping — lower the gain" }
        return "Good"
    }

    private var verdictColor: Color {
        if peak < Self.quiet { return .orange }
        if peak > Self.hot { return .red }
        return .green
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        peak = 0
        model.onStartLevelPreview()
        // 60 Hz, matching the flow bar: the capture layer publishes far more
        // often than the display refreshes, so sampling on a timer is what keeps
        // this from invalidating the view dozens of times per frame.
        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let value = model.inputLevel()
                level = value
                peak = max(peak * 0.995, value)
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        level = 0
        peak = 0
        model.onStopLevelPreview()
    }
}
