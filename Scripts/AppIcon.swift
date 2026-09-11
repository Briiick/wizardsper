import AppKit

/// Draws Wizard's application icon: the same mark as the menu bar, on the
/// standard macOS rounded square.
///
/// The menu-bar glyph and the app icon have to be recognisably the same thing,
/// so the geometry is shared rather than redrawn — but the constraints are
/// opposite. The menu-bar mark is a template at 18pt, monochrome and sparse; the
/// app icon is 1024pt, in colour, and has to hold its own in a Dock beside icons
/// that are extremely rendered. So the mark keeps its proportions and gains
/// depth: a warm gradient ground, a light source at the top-left, and the glyph
/// cut out of it rather than laid on top.
enum AppIcon {

    /// Apple's proportions: the art sits in 824 of a 1024 canvas, leaving the
    /// margin the system expects for shadow and alignment with other icons.
    static let canvas: CGFloat = 1024
    static let plate: CGFloat = 824

    /// A superellipse, not a rounded rectangle. macOS icon corners are
    /// continuous — the curvature eases in rather than meeting the straight edge
    /// at a tangent — and a plain rounded rect next to real Dock icons reads as
    /// subtly wrong without it being obvious why.
    static func squircle(in rect: CGRect, exponent: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let cx = rect.midX, cy = rect.midY
        let steps = 720
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = cx + a * pow(abs(c), 2 / exponent) * (c < 0 ? -1 : 1)
            let y = cy + b * pow(abs(s), 2 / exponent) * (s < 0 ? -1 : 1)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
        }
        path.close()
        return path
    }

    static func draw(size: CGFloat) -> NSBitmapImageRep? {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

        let k = size / canvas
        let inset = (canvas - plate) / 2 * k
        let plateRect = CGRect(x: inset, y: inset, width: plate * k, height: plate * k)
        let shape = squircle(in: plateRect)

        // Drop shadow, as the Dock expects. Offset downwards only.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -10 * k), blur: 24 * k,
            color: NSColor(white: 0, alpha: 0.28).cgColor)
        NSColor.black.setFill()
        shape.fill()
        ctx.restoreGState()

        ctx.saveGState()
        shape.addClip()

        // The ground: Wizard's orange, deepened towards the bottom so the plate
        // reads as lit from above rather than as a flat swatch.
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 1.00, green: 0.68, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.47, blue: 0.11, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.31, blue: 0.06, alpha: 1),
        ])
        gradient?.draw(in: plateRect, angle: -90)

        // A soft highlight at the top-left, the same light source the shadow
        // implies. Without it the gradient alone looks like a print, not an object.
        let glow = NSGradient(colors: [
            NSColor(white: 1, alpha: 0.34), NSColor(white: 1, alpha: 0),
        ])
        glow?.draw(
            fromCenter: CGPoint(x: plateRect.minX + plateRect.width * 0.28,
                                y: plateRect.maxY - plateRect.height * 0.18),
            radius: 0,
            toCenter: CGPoint(x: plateRect.minX + plateRect.width * 0.28,
                              y: plateRect.maxY - plateRect.height * 0.18),
            radius: plateRect.width * 0.72, options: [])

        // The mark, in the same geometry as the menu bar glyph so the two are
        // visibly one identity. Drawn in white with a faint shadow, so it reads
        // as cut into the plate.
        let markSide = plate * k * 0.62
        let markRect = CGRect(
            x: plateRect.midX - markSide / 2, y: plateRect.midY - markSide / 2,
            width: markSide, height: markSide)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -3 * k), blur: 10 * k,
            color: NSColor(srgbRed: 0.4, green: 0.13, blue: 0, alpha: 0.45).cgColor)
        let mark = WizardIcon.image(listening: true)
        let white = NSImage(size: mark.size, flipped: false) { r in
            mark.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: markRect)
        ctx.restoreGState()

        // A hairline rim, which is what stops the plate's edge looking soft
        // against a light desktop.
        ctx.saveGState()
        NSColor(white: 1, alpha: 0.22).setStroke()
        shape.lineWidth = 2 * k
        shape.stroke()
        ctx.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

@main
enum Main {
    static func main() {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            guard let rep = AppIcon.draw(size: CGFloat(size)),
                let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "/tmp/appicon/icon_\(size).png"))
        }
        print("wrote /tmp/appicon/icon_*.png")
    }
}
