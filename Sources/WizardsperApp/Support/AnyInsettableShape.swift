import SwiftUI

/// Type-erases an `InsettableShape` so one property can return either a capsule
/// or a rounded rectangle.
///
/// `AnyShape` exists in SwiftUI but loses `InsettableShape`, and the flow bar's
/// border is drawn with `strokeBorder`, which requires it — a plain `stroke`
/// would straddle the edge and leave the outer half of the line outside the
/// material, which is visible against a light desktop.
struct AnyInsettableShape: InsettableShape {
    // `@Sendable` because SwiftUI's `Shape` is `Sendable`, so anything storing
    // one has to be too; the closures only capture the shape itself, which is.
    private let makePath: @Sendable (CGRect) -> Path
    private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        makePath = { shape.path(in: $0) }
        makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { makePath(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}
