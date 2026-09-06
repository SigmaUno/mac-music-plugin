#!/usr/bin/env swift
// Renders Resources/AppIcon.icns — a rounded-square gradient tile with a music
// glyph. Run once when the look should change: `swift scripts/make-icon.swift`.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
    let tile = NSBezierPath(roundedRect: inset, xRadius: size * 0.22, yRadius: size * 0.22)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.24, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.28, blue: 0.55, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: -60)

    let glyph = "\u{266B}" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.5, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let g = glyph.size(withAttributes: attrs)
    glyph.draw(at: NSPoint(x: (size - g.width) / 2, y: (size - g.height) / 2), withAttributes: attrs)

    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
}

for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
