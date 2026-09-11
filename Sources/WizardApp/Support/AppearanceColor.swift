import AppKit
import SwiftUI

extension Color {
    /// A colour with a different value in each appearance.
    ///
    /// SwiftUI has no literal for this, and hard-coding one value gives a hue
    /// that is right in exactly one appearance: a mid orange that reads well on
    /// a light desktop turns muddy against the dark material of the pill. Built
    /// through `NSColor(name:dynamicProvider:)` so it resolves per appearance at
    /// draw time rather than being captured once.
    init(light: Color, dark: Color) {
        self = Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark =
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(isDark ? dark : light)
            })
    }
}
