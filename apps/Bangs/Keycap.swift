import AppKit
import SwiftUI

/// Bangs' return key: a line down and round to the left into an arrowhead, drawn at the weight of the text beside it
/// rather than borrowed from a font, whose ↩ is heavy and sits off the baseline.
struct ReturnArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x = { (f: CGFloat) in rect.minX + w * f }
        let y = { (f: CGFloat) in rect.minY + h * f }
        var path = Path()
        // Down the right side, a soft corner, along to the left.
        path.move(to: CGPoint(x: x(0.82), y: y(0.12)))
        path.addLine(to: CGPoint(x: x(0.82), y: y(0.44)))
        path.addQuadCurve(to: CGPoint(x: x(0.62), y: y(0.64)), control: CGPoint(x: x(0.82), y: y(0.64)))
        path.addLine(to: CGPoint(x: x(0.16), y: y(0.64)))
        // The arrowhead.
        path.move(to: CGPoint(x: x(0.38), y: y(0.40)))
        path.addLine(to: CGPoint(x: x(0.14), y: y(0.64)))
        path.addLine(to: CGPoint(x: x(0.38), y: y(0.88)))
        return path
    }
}

/// A key as the hints show it: a quiet keycap holding a character (⌘, esc) or Bangs' return arrow.
struct Keycap: View {
    enum Key: Hashable {
        case text(String)
        case returnKey
    }

    let key: Key
    /// The size of the text beside it.
    var size: CGFloat = 10
    var color: Color = Palette.muted

    var body: some View {
        Group {
            switch key {
            case .text(let text):
                Text(text).font(.system(size: size, weight: .medium)).padding(.horizontal, size * 0.3)
            case .returnKey:
                ReturnArrow()
                    .stroke(color, style: StrokeStyle(lineWidth: max(1, size * 0.12), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 1.05, height: size * 0.95)
                    .padding(.horizontal, size * 0.25)
            }
        }
        .foregroundStyle(color)
        .frame(minWidth: size * 1.55, minHeight: size * 1.5)
        .background(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(color.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }
}

/// A row of keys and what they do: "⌘ ⏎ 只复制".
struct KeyHint: View {
    let keys: [Keycap.Key]
    let title: String
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { Keycap(key: $0, size: size) }
            }
            Text(title).font(.system(size: size + 0.5)).foregroundStyle(Palette.dim)
        }
    }
}

extension Keycap {
    /// The return key as an image, for AppKit text (the scrolling screenshot's bar).
    @MainActor
    static func returnImage(size: CGFloat = 11, color: NSColor = .white) -> NSImage? {
        let renderer = ImageRenderer(content: Keycap(key: .returnKey, size: size, color: Color(nsColor: color)))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}
