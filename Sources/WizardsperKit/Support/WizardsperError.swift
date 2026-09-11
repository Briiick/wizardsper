import Foundation

/// Every failure Wizardsper can surface to a user, in one place.
///
/// The coordinator turns any of these into a single `.failed` outcome, so the
/// message here is what the flow bar shows before it dismisses.
public enum WizardsperError: LocalizedError, Sendable {
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
    case pasteFailed(String)

    /// Coerce any error into this type.
    ///
    /// Eight places used to write the same two-armed catch — one arm for a
    /// `WizardsperError`, one wrapping anything else — and the arms had started
    /// to differ in what they did afterwards. One coercion means the catch is a
    /// single clause and the difference cannot creep back.
    public static func wrapping(_ error: any Error) -> WizardsperError {
        (error as? WizardsperError) ?? .audioEngineFailed(error.localizedDescription)
    }

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
            return "Wizardsper needs Microphone access in System Settings ▸ Privacy & Security."
        case .inputMonitoringDenied:
            return "Wizardsper needs Input Monitoring access to see the dictation key."
        case .accessibilityDenied:
            return "Wizardsper needs Accessibility access to paste into other apps."
        case .audioEngineFailed(let detail):
            return "Audio capture failed: \(detail)"
        case .noAudioCaptured:
            return "No audio was captured."
        case .pasteFailed(let detail):
            return "Could not paste: \(detail)"
        }
    }
}
