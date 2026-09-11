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

    public var enabled: Bool
    /// Seconds the user is willing to wait for the rewrite before the raw
    /// transcript is pasted instead.
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
        deadlineSeconds: Double = 1.5,
        excludedBundleIDs: [String] = CleanupPolicy.defaultExclusions
    ) {
        self.enabled = enabled
        self.deadlineSeconds = deadlineSeconds
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// Off by default, deliberately. This feature changes what the user said,
    /// and that is not something to opt someone into silently.
    public static let `default` = CleanupPolicy()

    public var deadline: Duration { .milliseconds(Int(deadlineSeconds * 1000)) }

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
