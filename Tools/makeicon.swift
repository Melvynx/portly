// Renders Portly.icns from an SF Symbol so the app has a native-looking icon
// without shipping a binary asset in the repo.
// Usage: swift Tools/makeicon.swift <output.icns>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Portly.icns"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.2237

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.85, alpha: 1),
        ]
    )
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    gradient?.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        let symbolRect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: symbolRect)
        symbolRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let target = NSRect(
            x: (size - symbol.size.width) / 2,
            y: (size - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        tinted.draw(in: target)
    }

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
