import Foundation

/// Every failure Wizard can surface to a user, in one place.
///
/// The coordinator turns any of these into a single `.failed` outcome, so the
/// message here is what the flow bar shows before it dismisses.
public enum WizardError: LocalizedError, Sendable {
    case modelsMissing(String)
    case modelLoadFailed(String, underlying: String)
    case modelOutputMissing(String)
    case modelShapeMismatch(name: String, expected: [Int], actual: [Int])
    case encoderProducedSilence
    case tokenizerInvalid(String)
    case downloadFailed(String)
    case microphoneDenied
    case inputMonitoringDenied
    case accessibilityDenied
    case audioEngineFailed(String)
    case noAudioCaptured
    case transcriptEmpty
    case pasteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelsMissing(let path):
            return "Model files are missing at \(path)."
        case .modelLoadFailed(let name, let underlying):
            return "Could not load \(name): \(underlying)"
        case .modelOutputMissing(let name):
            return "Model produced no output named “\(name)”."
        case .modelShapeMismatch(let name, let expected, let actual):
            return "“\(name)” has shape \(actual), expected \(expected)."
        case .encoderProducedSilence:
            return "The encoder returned an all-zero result — its Neural Engine program did not start."
        case .tokenizerInvalid(let detail):
            return "tokenizer.json is not usable: \(detail)"
        case .downloadFailed(let detail):
            return "Model download failed: \(detail)"
        case .microphoneDenied:
            return "Wizard needs Microphone access in System Settings ▸ Privacy & Security."
        case .inputMonitoringDenied:
            return "Wizard needs Input Monitoring access to see the dictation key."
        case .accessibilityDenied:
            return "Wizard needs Accessibility access to paste into other apps."
        case .audioEngineFailed(let detail):
            return "Audio capture failed: \(detail)"
        case .noAudioCaptured:
            return "No audio was captured."
        case .transcriptEmpty:
            return "Nothing was said."
        case .pasteFailed(let detail):
            return "Could not paste: \(detail)"
        }
    }
}
