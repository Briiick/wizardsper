import Foundation

/// Identity of one press-and-hold. Every async hop carries it so late work from
/// an abandoned session can be dropped instead of corrupting the current one.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID
    public init() { self.uuid = UUID() }
    public var description: String { String(uuid.uuidString.prefix(8)) }
}

/// The only three states a session passes through.
///
/// `idle → listening → finishing → idle`. There is no path that skips
/// `finishing`: even a cancel goes through it, because that is where the single
/// terminal outcome is published.
public enum SessionState: Equatable, Sendable {
    case idle
    /// Key is held, audio is being captured and fed to the recogniser.
    case listening
    /// Key released. Draining the tail of the audio, then deciding an outcome.
    case finishing
}

/// Why a transcript ended up on the clipboard instead of in an app.
///
/// Carried rather than discarded because all three look identical to the user —
/// the text is on the clipboard and nothing was typed — and only one of them is
/// something they can act on. "Copied to clipboard" with no reason is what makes
/// a missing Accessibility grant read as the app being broken.
public enum CopyReason: Sendable, Equatable {
    /// Posting the key event would be silently dropped, so it was not posted.
    case accessibilityDenied
    /// Nothing was focused to paste into.
    case noTarget
    /// The user switched auto-paste off.
    case autoPasteDisabled

    public var explanation: String {
        switch self {
        case .accessibilityDenied: return "Copied — allow Accessibility to paste"
        case .noTarget: return "Copied — nothing was focused"
        case .autoPasteDisabled: return "Copied to clipboard"
        }
    }
}

/// Why a session produced no transcript.
///
/// Same argument as `CopyReason`: the three look identical from outside — the
/// pill says nothing was heard — but only one of them is the microphone, and one
/// of them is a setting the user changed a minute ago and will not connect to
/// the symptom on their own.
public enum SilenceReason: Sendable, Equatable {
    /// Held too briefly to be a deliberate hold.
    case tooShort
    /// Audio arrived and decoded to nothing.
    case noSpeech
    /// The gain stage was clipping, which decodes to nothing however loudly the
    /// user spoke.
    case clipping

    public var explanation: String {
        switch self {
        case .tooShort: return "Too short"
        case .noSpeech: return "Nothing heard"
        case .clipping: return "Nothing heard — microphone gain is clipping"
        }
    }
}

/// The single terminal result of a session. Exactly one of these is published
/// per session, and the flow bar does not dismiss until it sees one.
public enum SessionOutcome: Sendable, Equatable {
    /// Text was placed on the pasteboard and Cmd-V was delivered to an app.
    case pasted(String)
    /// Text is on the pasteboard, but nothing was typed into an app.
    case copied(String, why: CopyReason)
    /// The session ended with nothing to show.
    case nothing(why: SilenceReason)
    case failed(WizardError)

    public var transcript: String? {
        switch self {
        case .pasted(let text), .copied(let text, _): return text
        case .nothing, .failed: return nil
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// What the flow bar says while it fades out.
    public var summary: String {
        switch self {
        case .pasted: return "Pasted"
        case .copied(_, let why): return why.explanation
        case .nothing(let why): return why.explanation
        case .failed(let error): return error.errorDescription ?? "Failed"
        }
    }

    public static func == (lhs: SessionOutcome, rhs: SessionOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.pasted(let a), .pasted(let b)): return a == b
        case (.copied(let a, let x), .copied(let b, let y)): return a == b && x == y
        case (.nothing(let a), .nothing(let b)): return a == b
        case (.failed(let a), .failed(let b)):
            return a.errorDescription == b.errorDescription
        default: return false
        }
    }
}

/// What the UI renders. A value type so it can cross to the main actor whole.
public struct SessionSnapshot: Sendable, Equatable {
    public var id: SessionID?
    public var state: SessionState
    public var transcript: String
    public var level: Float
    public var outcome: SessionOutcome?

    public static let idle = SessionSnapshot(
        id: nil, state: .idle, transcript: "", level: 0, outcome: nil)

    public init(
        id: SessionID?, state: SessionState, transcript: String, level: Float,
        outcome: SessionOutcome?
    ) {
        self.id = id
        self.state = state
        self.transcript = transcript
        self.level = level
        self.outcome = outcome
    }
}
