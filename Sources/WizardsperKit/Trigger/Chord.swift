import AppKit
import Foundation

/// A modifier-only chord. Dictation triggers on modifiers alone, so the chord is
/// a set of modifier keys with no character key — that is what lets it be held
/// down without typing anything into the focused app.
public struct Chord: Hashable, Sendable, Codable {

    /// The modifiers Wizardsper can bind, each backed by the `CGEventFlags` bit the
    /// event tap actually observes.
    public enum Modifier: String, CaseIterable, Sendable, Codable, Identifiable {
        case fn, control, option, command, shift, capsLock

        public var id: String { rawValue }

        public var flag: CGEventFlags {
            switch self {
            case .fn: return .maskSecondaryFn
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .command: return .maskCommand
            case .shift: return .maskShift
            case .capsLock: return .maskAlphaShift
            }
        }

        public var symbol: String {
            switch self {
            case .fn: return "fn"
            case .control: return "⌃"
            case .option: return "⌥"
            case .command: return "⌘"
            case .shift: return "⇧"
            case .capsLock: return "⇪"
            }
        }

        public var label: String {
            switch self {
            case .fn: return "Fn"
            case .control: return "Control"
            case .option: return "Option"
            case .command: return "Command"
            case .shift: return "Shift"
            case .capsLock: return "Caps Lock"
            }
        }
    }

    public var modifiers: Set<Modifier>

    public init(_ modifiers: Set<Modifier>) {
        self.modifiers = modifiers
    }

    /// Hold Fn — the default. It is the one modifier macOS does not itself bind
    /// to a chord in the frontmost app, so holding it types nothing and changes
    /// nothing.
    public static let fn = Chord([.fn])

    public var isEmpty: Bool { modifiers.isEmpty }

    public var display: String {
        let order: [Modifier] = [.fn, .control, .option, .shift, .command, .capsLock]
        return order.filter(modifiers.contains).map(\.symbol).joined(separator: " ")
    }


    /// True when every bound modifier is down in `flags`.
    ///
    /// Deliberately not an equality test: requiring an exact match would break
    /// the chord the moment Caps Lock happened to be on, or a numeric-keypad
    /// event set `maskNumericPad` alongside it.
    public func isHeld(in flags: CGEventFlags) -> Bool {
        guard !modifiers.isEmpty else { return false }
        return modifiers.allSatisfy { flags.contains($0.flag) }
    }
}
