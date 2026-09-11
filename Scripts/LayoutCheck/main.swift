import AppKit
import SwiftUI

/// Renders the real flow-bar transcript view into a canvas wider than the frame
/// it is given, and fails if any ink lands outside that frame.
///
/// This exists because SwiftUI layout bugs are invisible to every other kind of
/// test. The overflow this catches compiled cleanly, passed the whole unit
/// suite, and looked correct in a preview with short text — it only appeared
/// once a sentence grew past the pill's width, at which point words drew over
/// the level meter and out past the capsule entirely. The cause was a container
/// that grew to fit its own oversized child, so the "available width" it
/// measured was the content's width and the scroll offset was always zero.
///
/// Nothing about that is detectable without rasterising the view and looking.

private let frameWidth: CGFloat = 300
private let canvasWidth: CGFloat = 520
private let canvasHeight: CGFloat = 220
private let maxLines = 5

private struct Case {
    let name: String
    let text: String
}

private let cases = [
    Case(name: "empty", text: ""),
    Case(name: "short", text: "Hello"),
    Case(name: "medium", text: "Hello, can you hear me now"),
    Case(
        name: "long",
        text:
            "Hospital ted. Yeah, there are hospital tents. Yeah, there's a lot of hospital ones as well because I"
    ),
    Case(name: "verylong", text: String(repeating: "overflowing ", count: 40)),
    Case(name: "onehugeword", text: String(repeating: "supercalifragilistic", count: 8)),
]

@MainActor
private func overflow(for testCase: Case) -> (rightmostPoints: Double, overflowPixels: Int) {
    let root = ZStack(alignment: .topLeading) {
        Color.white
        // No outer `.frame(width:)`: the view sizes itself now, and forcing a
        // width would hide the very thing this checks — whether its own idea of
        // its width keeps the ink inside.
        TranscriptFlowView(
            text: testCase.text, color: .black, width: frameWidth, maxLines: maxLines)
            .padding(.top, 10)
    }
    .frame(width: canvasWidth, height: canvasHeight)

    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    host.layoutSubtreeIfNeeded()
    // The width is delivered through a preference, so it takes a few run-loop
    // turns to settle before the offset is correct.
    for _ in 0..<8 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        return (0, 0)
    }
    host.cacheDisplay(in: host.bounds, to: rep)

    let scale = CGFloat(rep.pixelsWide) / canvasWidth
    let boundary = Int(frameWidth * scale)
    var rightmost = -1
    var lowest = -1
    var beyond = 0
    // Five lines of text plus the 10pt top padding, with slack for descenders.
    let verticalLimit = Int((CGFloat(maxLines) * 21 + 10 + 8) * scale)
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            guard colour.brightnessComponent < 0.75 else { continue }
            rightmost = max(rightmost, x)
            lowest = max(lowest, y)
            // One pixel of slack for antialiasing on the boundary itself.
            if x > boundary + 1 { beyond += 1 }
            if y > verticalLimit { beyond += 1 }
        }
    }
    _ = lowest
    return (Double(max(rightmost, 0)) / Double(scale), beyond)
}

@main
enum LayoutCheck {
    @MainActor static func main() {
        var failed = false
        for testCase in cases {
            let (edge, beyond) = overflow(for: testCase)
            let verdict = beyond == 0 ? "ok" : "OVERFLOWS by \(beyond) px"
            if beyond > 0 { failed = true }
            print(
                String(
                    format: "  %-12@ frame %.0fpt, rightmost ink %6.1fpt  %@",
                    testCase.name as NSString, frameWidth, edge, verdict as NSString))
        }
        if failed {
            print("  the transcript is drawing outside the pill")
            exit(1)
        }
    }
}
