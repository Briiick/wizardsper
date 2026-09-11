import AppKit
import Foundation

/// Where cleanup is allowed to run.
///
/// Cleanup is a rewrite, and there are places a rewrite is simply wrong however
/// good it is. Text going into a terminal or an editor is usually a command, an
/// identifier, a path or a snippet of code — things whose value is in being
/// exactly what was said. "cd slash user slash local" tidied into a sentence is
/// worse than useless, and the user will not notice until it fails to run.
///
/// So the rule is not a preference but a guard, and it is stated as a list of
/// bundle identifiers because that is what `NSWorkspace` can actually tell us
/// about the app receiving the paste.
public struct CleanupPolicy: Sendable, Equatable, Codable {

    /// Decoded with defaults for anything missing, so a policy stored by an
    /// earlier build still loads instead of resetting every other setting in it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        waitsForCompletion =
            try container.decodeIfPresent(Bool.self, forKey: .waitsForCompletion) ?? false
        deadlineSeconds = try container.decodeIfPresent(Double.self, forKey: .deadlineSeconds) ?? 1.5
        excludedBundleIDs =
            try container.decodeIfPresent([String].self, forKey: .excludedBundleIDs)
            ?? CleanupPolicy.defaultExclusions
    }


    public var enabled: Bool

    /// Run the rewrite to completion instead of racing a stopwatch.
    ///
    /// With a deadline, whether your words get cleaned depends on how busy the
    /// machine happened to be — the same sentence can come back polished once
    /// and raw the next time, for reasons invisible to you. That is the kind of
    /// inconsistency that makes a tool feel unreliable even when every
    /// individual result is defensible. Switching this on trades a possible wait
    /// for an answer that depends only on what you said: one pass, greedy
    /// sampling, same input, same output, every time.
    ///
    /// A hard ceiling still applies (`safetyCeiling`) because "wait forever" is
    /// not a behaviour a paste can have.
    public var waitsForCompletion: Bool

    /// Seconds the user is willing to wait for the rewrite before the raw
    /// transcript is pasted instead. Ignored when `waitsForCompletion` is set.
    public var deadlineSeconds: Double
    /// Bundle identifiers, lowercased, where cleanup never runs.
    public var excludedBundleIDs: [String]

    public static let defaultExclusions = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "org.vim.macvim",
        "com.apple.scripteditor2",
        "com.1password.1password",
        "com.apple.keychainaccess",
    ]

    public init(
        enabled: Bool = false,
        waitsForCompletion: Bool = false,
        deadlineSeconds: Double = 1.5,
        excludedBundleIDs: [String] = CleanupPolicy.defaultExclusions
    ) {
        self.enabled = enabled
        self.waitsForCompletion = waitsForCompletion
        self.deadlineSeconds = deadlineSeconds
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// The longest a paste may ever be held, whatever the settings say. Not a
    /// user preference: it is the difference between "this took a while" and "my
    /// transcript never arrived".
    public static let safetyCeiling: Duration = .seconds(30)

    /// Off by default, deliberately. This feature changes what the user said,
    /// and that is not something to opt someone into silently.
    public static let `default` = CleanupPolicy()

    public var deadline: Duration {
        waitsForCompletion ? Self.safetyCeiling : .milliseconds(Int(deadlineSeconds * 1000))
    }

    public func allows(bundleID: String?) -> Bool {
        guard enabled else { return false }
        guard let bundleID = bundleID?.lowercased() else { return true }
        return !excludedBundleIDs.contains { bundleID == $0.lowercased() }
    }

    /// The app that is about to receive the paste.
    @MainActor
    public static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
