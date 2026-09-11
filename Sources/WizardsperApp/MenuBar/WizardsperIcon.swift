import AppKit

/// Wizardsper's menu bar mark, drawn rather than borrowed from SF Symbols.
///
/// Two requirements rule the symbol library out. The mark has to say *wizardsper*
/// and *voice* at once, and no shipped symbol says both. More importantly the
/// idle and listening states have to be the same mark with one property
/// changed, so the eye reads a state and not a different icon; pairing two
/// unrelated symbols — which is what `waveform` and `waveform.badge.mic` were —
/// makes the user re-identify the glyph every time the state flips.
///
/// The mark is a four-point sparkle held between arcs: one pair at rest, two
/// while Wizardsper is listening, so recording *adds* a ring rather than altering
/// one.
///
/// The states differ *topologically* — one shape against three — rather than by
/// degree. An earlier version changed only the arcs' sweep and radius between
/// states, which is a couple of pixels of arc length at 36x36 and was genuinely
/// unreadable: rendered side by side at 18pt you could not tell which state you
/// were looking at without the label. Anything that distinguishes the states has
/// to survive being two pixels tall, and "is there an arc at all" survives where
/// "is this arc slightly longer" does not.
///
/// The tight constraint is the second ring. An 18pt box leaves about 8pt of
/// radius once the outer stroke is accounted for, so the inner pair and the
/// sparkle share what is left. The sparkle narrows rather than shortens when the
/// inner arcs appear: the arcs sweep about the horizontal axis, so they crowd
/// its width while leaving its height clear, which is why the vertical tips
/// still show through the gaps at top and bottom.
///
/// Every number below is in an 18x18 unit box and was chosen by rendering at
/// the real 18pt size, not by eye at a comfortable one. The things that would
/// break it are all size-related: strokes thinner than ~1.5pt vanish, and a
/// sparkle as wide as it is tall merges with the arcs into a single horizontal
/// bar at 18pt, which is why this one is noticeably taller than it is wide.
enum WizardsperIcon {

    /// The mark as a template image, ready for `NSStatusItem.button.image`.
    ///
    /// Template so macOS tints it — black on a light menu bar, white on a dark
    /// one, inverted while the item is selected. The icon itself must therefore
    /// carry no colour; only its alpha channel survives.
    /// Built once each. The two images depend on nothing but the flag, and
    /// `refreshIcon()` asks for one on every state change — twice per dictation,
    /// in the same run-loop turn that is starting the audio engine.
    ///
    /// Main-actor isolated because `NSImage` is not `Sendable`, and a bare
    /// `static let` of one is shared mutable state as far as the compiler is
    /// concerned. That is not pedantry here: the only caller is the status item,
    /// which is main-actor by construction, so stating the isolation costs
    /// nothing and is the truth.
    @MainActor private static let idle = render(listening: false)
    @MainActor private static let live = render(listening: true)

    @MainActor
    static func image(listening: Bool) -> NSImage {
        listening ? live : idle
    }

    private static func render(listening: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            draw(listening: listening, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = listening ? "Wizardsper is listening" : "Wizardsper"
        return image
    }

    // MARK: - Geometry

    /// The design grid. Everything below is expressed in this box and scaled to
    /// whatever rect the drawing handler is handed, so the same source serves
    /// 1x and 2x without a second set of numbers.
    private static let side: CGFloat = 18

    private static let centre = CGPoint(x: side / 2, y: side / 2)

    /// Half-width and half-height of the sparkle, idle and listening. Taller
    /// than wide on purpose: a sparkle as wide as it is tall merges with the
    /// arcs into a single horizontal bar at 18pt.
    ///
    /// It shrinks when the arcs appear, for two reasons — it keeps the whole
    /// mark inside the box once there is something around it, and the change in
    /// the sparkle reinforces the change in the arcs, so the states differ in
    /// two ways at once rather than one.
    private static let idleSparkle = CGSize(width: 3.4, height: 4.9)
    private static let liveSparkle = CGSize(width: 2.3, height: 4.6)

    /// How far the sparkle's arms pinch in, as a fraction of their length.
    /// Lower is a thinner, more elegant star — but below about 0.1 the arms
    /// thin past a pixel at 18pt and the star fills in to a plain diamond.
    private static let sparkleWaist: CGFloat = 0.13

    /// 2pt survives at 18pt on a 1x display; 1pt does not.
    private static let arcWidth: CGFloat = 2

    /// The outer pair, present in both states. The radius is capped so the
    /// stroke's outer edge stays inside the 18pt box, and the sweep is wide
    /// enough that each arc is several pixels long at 18pt rather than a dot.
    private static let arcRadius: CGFloat = 7
    private static let arcSweep: CGFloat = 52

    /// The inner pair, listening only. Thinner and shorter than the outer one so
    /// the two read as a sequence radiating outwards; at this size two strokes
    /// of equal weight sitting 2pt apart merge into a single thick band.
    private static let innerArcRadius: CGFloat = 4.3
    private static let innerArcWidth: CGFloat = 1.6
    private static let innerArcSweep: CGFloat = 44

    private static func draw(listening: Bool, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / side)
        transform.concat()

        sparkle(size: listening ? liveSparkle : idleSparkle).fill()

        arc(radius: arcRadius, width: arcWidth, from: -arcSweep, to: arcSweep).stroke()
        arc(radius: arcRadius, width: arcWidth, from: 180 - arcSweep, to: 180 + arcSweep).stroke()

        guard listening else { return }
        arc(radius: innerArcRadius, width: innerArcWidth, from: -innerArcSweep, to: innerArcSweep)
            .stroke()
        arc(
            radius: innerArcRadius, width: innerArcWidth, from: 180 - innerArcSweep,
            to: 180 + innerArcSweep
        ).stroke()
    }

    /// A four-point star: tips on the axes, each pair joined by a curve whose
    /// control point sits near the centre, which is what pinches the arms.
    private static func sparkle(size: CGSize) -> NSBezierPath {
        let tipX = size.width, tipY = size.height
        let waistX = tipX * sparkleWaist, waistY = tipY * sparkleWaist
        let tips = [
            CGPoint(x: centre.x, y: centre.y + tipY),
            CGPoint(x: centre.x + tipX, y: centre.y),
            CGPoint(x: centre.x, y: centre.y - tipY),
            CGPoint(x: centre.x - tipX, y: centre.y),
        ]
        // One control point per quadrant, used for both handles of that curve.
        let waists = [
            CGPoint(x: centre.x + waistX, y: centre.y + waistY),
            CGPoint(x: centre.x + waistX, y: centre.y - waistY),
            CGPoint(x: centre.x - waistX, y: centre.y - waistY),
            CGPoint(x: centre.x - waistX, y: centre.y + waistY),
        ]

        let path = NSBezierPath()
        path.move(to: tips[0])
        for quadrant in 0..<4 {
            path.curve(
                to: tips[(quadrant + 1) % 4],
                controlPoint1: waists[quadrant],
                controlPoint2: waists[quadrant])
        }
        path.close()
        return path
    }

    private static func arc(
        radius: CGFloat, width: CGFloat, from start: CGFloat, to end: CGFloat
    ) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: end)
        path.lineWidth = width
        // Round caps, so the arcs read as soft strokes rather than cut tubes —
        // and so the two ends stay visible once the sweep shortens in idle.
        path.lineCapStyle = .round
        return path
    }
}
