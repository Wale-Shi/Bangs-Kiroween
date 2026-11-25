import AppKit
import CoreImage

/// A mark drawn on a screenshot, in the image's points (y down, from its top left).
struct Annotation: Equatable {
    enum Kind: Equatable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case mosaic(CGRect)
        case text(String, at: CGPoint)
        case counter(Int, at: CGPoint)
    }

    var kind: Kind
    var color: AnnotationColor
    var size: AnnotationSize

    var isMosaic: Bool { if case .mosaic = kind { true } else { false } }

    func moved(by delta: CGVector) -> Annotation {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.dx, y: point.y + delta.dy) }
        var copy = self
        switch kind {
        case .rectangle(let rect): copy.kind = .rectangle(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .ellipse(let rect): copy.kind = .ellipse(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .arrow(let from, let to): copy.kind = .arrow(from: move(from), to: move(to))
        case .pen(let points): copy.kind = .pen(points.map(move))
        case .highlighter(let points): copy.kind = .highlighter(points.map(move))
        case .mosaic(let rect): copy.kind = .mosaic(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .text(let text, let at): copy.kind = .text(text, at: move(at))
        case .counter(let number, let at): copy.kind = .counter(number, at: move(at))
        }
        return copy
    }
}

/// The tools of the annotation toolbar, as other screenshot tools have them.
enum AnnotationTool: String, CaseIterable {
    case rectangle, ellipse, arrow, pen, highlighter, mosaic, text, counter

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .highlighter: "荧光笔"
        case .mosaic: "马赛克"
        case .text: "文字"
        case .counter: "序号"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .mosaic: "checkerboard.rectangle"
        case .text: "textformat"
        case .counter: "1.circle"
        }
    }

    /// Pressed while annotating, picks the tool.
    var key: Character {
        switch self {
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .pen: "p"
        case .highlighter: "h"
        case .mosaic: "m"
        case .text: "t"
        case .counter: "n"
        }
    }

    /// Mosaic has neither colour nor size to pick.
    var hasOptions: Bool { self != .mosaic }
}

enum AnnotationColor: String, CaseIterable {
    case red, yellow, green, blue, black, white

    var color: NSColor {
        switch self {
        case .red: NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: NSColor(red: 1, green: 0.8, blue: 0, alpha: 1)
        case .green: NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: NSColor(red: 0, green: 0.48, blue: 1, alpha: 1)
        case .black: NSColor(white: 0.1, alpha: 1)
        case .white: .white
        }
    }
}

enum AnnotationSize: Int, CaseIterable {
    case small, medium, large

    var stroke: CGFloat { [2, 4, 6][rawValue] }
    var font: CGFloat { [14, 18, 26][rawValue] }
    var counter: CGFloat { [10, 13, 17][rawValue] }
}

/// Draws annotations, on screen and into the saved image alike, so what you see is what you get.
enum AnnotationRenderer {
    /// The text font: the system's, slightly bold, like other tools' labels.
    static func font(_ size: AnnotationSize) -> NSFont { .systemFont(ofSize: size.font, weight: .semibold) }

    /// Draws into the current NSGraphicsContext, flipped (y down), in image points. `mosaic` is the whole image
    /// pixelated, which mosaic marks show through.
    static func draw(_ annotations: [Annotation], mosaic: CGImage?, imageSize: CGSize) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for annotation in layered(annotations) { draw(annotation, in: context, mosaic: mosaic, imageSize: imageSize) }
    }

    /// Mosaics first: they hide what is in the screenshot, never the marks drawn on it.
    static func layered(_ annotations: [Annotation]) -> [Annotation] {
        annotations.filter(\.isMosaic) + annotations.filter { !$0.isMosaic }
    }

    static func draw(_ annotation: Annotation, in context: CGContext, mosaic: CGImage?, imageSize: CGSize) {
        let color = annotation.color.color
        let width = annotation.size.stroke
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.kind {
        case .rectangle(let rect):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(width, rect.width / 2), cornerHeight: min(width, rect.height / 2), transform: nil))
            context.strokePath()
        case .ellipse(let rect):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokeEllipse(in: rect)
        case .arrow(let from, let to):
            context.setFillColor(color.cgColor)
            context.addPath(arrow(from: from, to: to, width: width))
            context.fillPath()
        case .pen(let points):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.addPath(smooth(points))
            context.strokePath()
        case .highlighter(let points):
            // Plain see-through ink: multiplied, it would vanish on dark windows.
            context.setStrokeColor(color.withAlphaComponent(0.42).cgColor)
            context.setLineWidth(width * 3 + 10)
            context.setLineCap(.square)
            context.addPath(smooth(points))
            context.strokePath()
        case .mosaic(let rect):
            guard let mosaic else { return }
            context.clip(to: rect)
            drawImage(mosaic, in: CGRect(origin: .zero, size: imageSize), context: context)
        case .text(let text, let at):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let shadow = NSShadow()
            shadow.shadowColor = (annotation.color == .white ? NSColor.black : NSColor.white).withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 2
            (text as NSString).draw(at: at, withAttributes: [.font: font(annotation.size), .foregroundColor: color, .shadow: shadow])
            NSGraphicsContext.restoreGraphicsState()
        case .counter(let number, let at):
            let radius = annotation.size.counter
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                                                             .foregroundColor: annotation.color == .white || annotation.color == .yellow ? NSColor.black : NSColor.white]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: at.x - size.width / 2, y: at.y - size.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// An arrow as one shape: a shaft that widens toward a solid head, as other tools draw it.
    static func arrow(from: CGPoint, to: CGPoint, width: CGFloat) -> CGPath {
        let length = hypot(to.x - from.x, to.y - from.y)
        let path = CGMutablePath()
        guard length > 1 else { return path }
        let head = min(max(width * 4 + 6, 12), length * 0.6)
        let headWidth = head * 0.9
        let shaft = width * 0.9
        // Along the arrow (x) and across it (y), from `from`.
        let points: [CGPoint] = [
            CGPoint(x: 0, y: -shaft * 0.25), CGPoint(x: length - head, y: -shaft), CGPoint(x: length - head, y: -headWidth / 2),
            CGPoint(x: length, y: 0),
            CGPoint(x: length - head, y: headWidth / 2), CGPoint(x: length - head, y: shaft), CGPoint(x: 0, y: shaft * 0.25),
        ]
        let angle = atan2(to.y - from.y, to.x - from.x)
        let transform = CGAffineTransform(translationX: from.x, y: from.y).rotated(by: angle)
        path.addLines(between: points, transform: transform)
        path.closeSubpath()
        return path
    }

    /// A freehand line through its points, rounded between them.
    static func smooth(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first); return path }
        for index in 1..<points.count {
            let mid = CGPoint(x: (points[index - 1].x + points[index].x) / 2, y: (points[index - 1].y + points[index].y) / 2)
            path.addQuadCurve(to: mid, control: points[index - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Where an annotation can be picked up: on its line for shapes, anywhere on it for the rest.
    static func hits(_ annotation: Annotation, _ point: CGPoint) -> Bool {
        let slack = max(annotation.size.stroke, 4) + 6
        func onLine(_ path: CGPath, width: CGFloat) -> Bool {
            path.copy(strokingWithWidth: width + slack, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        }
        switch annotation.kind {
        case .rectangle(let rect): return onLine(CGPath(rect: rect, transform: nil), width: annotation.size.stroke)
        case .ellipse(let rect): return onLine(CGPath(ellipseIn: rect, transform: nil), width: annotation.size.stroke)
        case .arrow(let from, let to): return onLine(arrow(from: from, to: to, width: annotation.size.stroke), width: 2)
        case .pen(let points): return onLine(smooth(points), width: annotation.size.stroke)
        case .highlighter(let points): return onLine(smooth(points), width: annotation.size.stroke * 3 + 10)
        default: return bounds(annotation).insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    /// The box an annotation takes up, for picking it and showing it picked.
    static func bounds(_ annotation: Annotation) -> CGRect {
        let pad = annotation.size.stroke
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect): return rect.insetBy(dx: -pad, dy: -pad)
        case .arrow(let from, let to): return arrow(from: from, to: to, width: annotation.size.stroke).boundingBox
        case .pen(let points), .highlighter(let points): return smooth(points).boundingBox.insetBy(dx: -pad * 2, dy: -pad * 2)
        case .text(let text, let at):
            return CGRect(origin: at, size: (text as NSString).size(withAttributes: [.font: font(annotation.size)]))
        case .counter(_, let at):
            let radius = annotation.size.counter
            return CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// The image pixelated in blocks of about `block` points, for mosaic marks to show.
    static func pixelated(_ image: CGImage, scale: CGFloat, block: CGFloat = 9) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(block * scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// The screenshot with its annotations, at the screenshot's own resolution.
    static func render(_ image: CGImage, annotations: [Annotation], scale: CGFloat, mosaic: CGImage?) -> CGImage? {
        guard !annotations.isEmpty else { return image }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Points, y down, as on screen.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)
        drawImage(image, in: CGRect(origin: .zero, size: size), context: context)
        for annotation in layered(annotations) { draw(annotation, in: context, mosaic: mosaic, imageSize: size) }
        return context.makeImage()
    }

    /// A CGImage the right way up in a context whose y runs down.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
