import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Small previews of image files and Finder icons, made once and kept, so lists never decode full images while drawing.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// The image at `url` scaled to fit `points` (at 2x), or nil when it is not an image.
    static func image(at url: URL, points: CGFloat) -> NSImage? {
        let key = "\(url.path)#\(Int(points))" as NSString
        if let image = cache.object(forKey: key) { return image }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(points * 2)]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width) / 2, height: CGFloat(thumbnail.height) / 2))
        cache.setObject(image, forKey: key)
        return image
    }

    static func icon(for url: URL) -> NSImage {
        let key = "icon:\(url.path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    /// An image file's own picture, else its Finder icon.
    static func preview(for url: URL, points: CGFloat) -> NSImage {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let image = image(at: url, points: points) { return image }
        return icon(for: url)
    }
}
