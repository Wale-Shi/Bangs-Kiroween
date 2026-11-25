import AppKit
import BangsCore

/// The CLIs' official logos (see Logos/README.md), loaded from the app bundle, or from the sources in a development build.
/// Each is trimmed to the bounds of its mark, so every logo fills the same box however much margin its file has.
@MainActor
enum Logos {
    private static var cache: [String: NSImage] = [:]

    private static var directory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Logos"), FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Logos")
    }

    static func image(for harness: Harness, onDark: Bool) -> NSImage? {
        let name = harness == .qoderCN ? "qoder" : harness.rawValue
        let key = "\(name)-\(onDark)"
        if let image = cache[key] { return image }
        guard let svg = try? String(contentsOf: directory.appendingPathComponent("\(name).svg"), encoding: .utf8),
              let image = NSImage(data: Data(svg.replacingOccurrences(of: "currentColor", with: ink(for: harness, onDark: onDark)).utf8)) else { return nil }
        let trimmed = trim(image) ?? image
        cache[key] = trimmed
        return trimmed
    }

    /// The colour for marks drawn in `currentColor`: the brand colour where the brand has one, else white or black.
    static func ink(for harness: Harness, onDark: Bool) -> String {
        switch harness {
        case .kiro: onDark ? "#A77BFF" : "#7C3AED"
        case .codebuddy: onDark ? "#8C84FF" : "#5B4BEF"
        default: onDark ? "#FFFFFF" : "#000000"
        }
    }

    /// Renders the image and crops it to its visible pixels.
    private static func trim(_ image: NSImage) -> NSImage? {
        let side = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = NSRect(x: (CGFloat(side) - image.size.width * scale) / 2, y: (CGFloat(side) - image.size.height * scale) / 2,
                           width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: drawn)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where data[(y * side + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, let cg = rep.cgImage,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
