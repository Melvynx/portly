// Renders Portly.icns from the Portly mark: three inbound lanes converging into
// one supervised process. The same geometry is used by the website favicon and
// the PortlyMark React component, so the app and the site share one identity.
// Usage: swift Tools/makeicon.swift <output.icns>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Portly.icns"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

/// The mark is authored on a 24x24 grid, SVG-style, with y growing downwards.
private let markGrid: CGFloat = 24

private func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.06
    let body = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
    let radius = size * 0.2237

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.24, green: 0.58, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.04, green: 0.32, blue: 0.84, alpha: 1),
        ]
    )
    let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    gradient?.draw(in: tile, angle: -90)

    // Glyph occupies 62% of the tile body, matching the web lockup.
    let scale = body.width * 0.62 / markGrid
    let originX = body.minX + (body.width - markGrid * scale) / 2
    let originY = body.minY + (body.height - markGrid * scale) / 2

    // AppKit draws bottom-up, so the authored y is mirrored on the way in.
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: originX + x * scale, y: originY + (markGrid - y) * scale)
    }

    NSColor.white.set()

    let lanes = NSBezierPath()
    lanes.lineWidth = 2.3 * scale
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

    let center = point(18.1, 12)
    let dotRadius = 2.9 * scale
    NSBezierPath(
        ovalIn: NSRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
    ).fill()

    image.unlockFocus()
    return image
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Portly.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard pixels <= 1024 else { continue }
        let image = icon(size: CGFloat(pixels))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(size)x\(size)\(suffix).png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outputPath)")
