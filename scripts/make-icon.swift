// Draws the Bangs app icon: a fringe of hair hanging over the top of a dark tile, with two eyes peeking out below.
// swift scripts/make-icon.swift assets  →  assets/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")
let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let s = size / 1024
        let ctx = NSGraphicsContext.current!.cgContext
        // Tile: macOS icon grid, 824pt squircle centred in 1024.
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let squircle = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1).cgColor,
            NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

        // Eyes, peeking out under the fringe.
        for x in [402.0, 622.0] {
            let eye = CGRect(x: (x - 62) * s, y: 520 * s, width: 124 * s, height: 150 * s)
            ctx.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
            ctx.fillEllipse(in: eye)
            ctx.setFillColor(NSColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: (x - 30) * s, y: 580 * s, width: 64 * s, height: 76 * s))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: (x - 14) * s, y: 592 * s, width: 20 * s, height: 20 * s))
        }

        // The fringe: one hair mass whose lower edge is a row of pointed locks.
        let hair = CGMutablePath()
        hair.move(to: CGPoint(x: tile.minX, y: tile.minY))
        hair.addLine(to: CGPoint(x: tile.maxX, y: tile.minY))
        hair.addLine(to: CGPoint(x: tile.maxX, y: 470 * s))
        let locks = 7
        let width = 824.0 / Double(locks)
        for i in (0..<locks).reversed() {
            let left = 100 + Double(i) * width
            let tip = 520 + (i % 2 == 0 ? 40.0 : 0) - abs(Double(i) - 3) * 18
            hair.addQuadCurve(to: CGPoint(x: (left + width * 0.45) * s, y: tip * s), control: CGPoint(x: (left + width * 0.95) * s, y: (tip - 40) * s))
            hair.addQuadCurve(to: CGPoint(x: left * s, y: 450 * s), control: CGPoint(x: (left + width * 0.2) * s, y: (tip - 80) * s))
        }
        hair.closeSubpath()
        let hairGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(red: 0.98, green: 0.60, blue: 0.36, alpha: 1).cgColor,
            NSColor(red: 0.90, green: 0.40, blue: 0.30, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.addPath(hair)
        ctx.clip()
        ctx.drawLinearGradient(hairGradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: 560 * s), options: [])
        // A notch-shaped shadow in the middle of the fringe ties it to the MacBook notch.
        ctx.setFillColor(NSColor(white: 0, alpha: 0.85).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 362 * s, y: 40 * s, width: 300 * s, height: 160 * s), cornerWidth: 46 * s, cornerHeight: 46 * s, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        return true
    }
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = CGFloat(points * scale)
        let image = draw(pixels)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: output.appendingPathComponent("icon.png"))
try FileManager.default.removeItem(at: iconset)
