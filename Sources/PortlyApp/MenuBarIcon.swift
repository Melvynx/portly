import AppKit

/// The Portly mark, drawn for the menu bar: three inbound lanes converging into
/// one supervised process.
///
/// Same 24x24 geometry as `Tools/makeicon.swift` and the website mark, so the
/// status item, the app icon and the site all read as one identity. The image
/// is a template, so macOS tints it for light, dark and highlighted menu bars.
enum PortlyGlyph {
    /// The authored grid, SVG-style, with y growing downwards.
    private static let grid: CGFloat = 24
    private static let lineWidth: CGFloat = 2.3
    private static let dotCenter = CGPoint(x: 18.1, y: 12)
    private static let dotRadius: CGFloat = 2.9

    /// Ink bounds on the authored grid: strokes and dot, half a stroke of slack.
    private static let inkBounds = CGRect(
        x: 2.9 - lineWidth / 2,
        y: 5.8 - lineWidth / 2,
        width: (dotCenter.x + dotRadius) - (2.9 - lineWidth / 2),
        height: (18.2 + lineWidth / 2) - (5.8 - lineWidth / 2)
    )

    private static var cache: [Bool: NSImage] = [:]

    /// - Parameter active: filled process dot when something is running, an open
    ///   ring when everything is idle.
    static func menuBarImage(active: Bool) -> NSImage {
        if let cached = cache[active] { return cached }
        let image = render(active: active)
        cache[active] = image
        return image
    }

    private static func render(active: Bool) -> NSImage {
        let height: CGFloat = 15
        let scale = height / inkBounds.height
        let size = NSSize(width: inkBounds.width * scale, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            // AppKit draws bottom-up, so the authored y is mirrored on the way in.
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(
                    x: (x - inkBounds.minX) * scale,
                    y: (inkBounds.maxY - y) * scale
                )
            }

            // Template images care about coverage, not colour.
            NSColor.black.set()

            let lanes = NSBezierPath()
            lanes.lineWidth = lineWidth * scale
            lanes.lineCapStyle = .round
            lanes.lineJoinStyle = .round

            lanes.move(to: point(2.9, 5.8))
            lanes.line(to: point(5.9, 5.8))
            lanes.curve(
                to: point(12.8, 12),
                controlPoint1: point(9.5, 5.8),
                controlPoint2: point(9.2, 12)
            )

            lanes.move(to: point(2.9, 12))
            lanes.line(to: point(12.8, 12))

            lanes.move(to: point(2.9, 18.2))
            lanes.line(to: point(5.9, 18.2))
            lanes.curve(
                to: point(12.8, 12),
                controlPoint1: point(9.5, 18.2),
                controlPoint2: point(9.2, 12)
            )

            lanes.stroke()

            let center = point(dotCenter.x, dotCenter.y)
            let radius = dotRadius * scale
            let box = NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            if active {
                NSBezierPath(ovalIn: box).fill()
            } else {
                let ring = lineWidth * 0.65 * scale
                let path = NSBezierPath(ovalIn: box.insetBy(dx: ring / 2, dy: ring / 2))
                path.lineWidth = ring
                path.stroke()
            }

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "Portly"
        return image
    }
}
