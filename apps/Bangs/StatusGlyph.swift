import AppKit
import SwiftUI

/// Bangs' menu bar icon: an open ring for what the agents are doing, Bangs' face in the middle, and a dot per session in
/// the gap at the bottom. It is drawn in the menu bar's own ink, so it reads like the system's icons, and moves only while
/// something is happening.
struct StatusGlyph: View {
    enum State: Equatable {
        /// Nothing running; `awake` when keep-awake is on, so Bangs keeps its eyes open.
        case idle(awake: Bool)
        case working
        case approval
        case finished
        /// A meeting is coming up: the ring drains as it gets closer (1 is ten minutes away, 0 is now).
        case meeting(left: Double, awake: Bool)
    }

    /// A session, as a dot in the gap.
    enum Dot: Equatable {
        case running
        /// Waiting for your answer: orange.
        case asking
        /// Finished and not yet looked at: green.
        case finished
    }

    var state: State
    /// At most four are shown.
    var dots: [Dot]
    var size: CGFloat = 17
    /// Played by Core Animation; off, drawn frame by frame by SwiftUI.
    var layers = LayerMotion.usesLayers

    @SwiftUI.State private var since = Date()
    /// The sweep that marks a finished turn has played; the icon can stand still.
    @SwiftUI.State private var settled = true
    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        if layers {
            GlyphLayers(state: state, dots: dots).frame(width: size, height: size * 1.04)
        } else {
            drawing
        }
    }

    /// The same picture drawn by SwiftUI, for snapshots.
    private var drawing: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
            Canvas { canvas, area in
                draw(in: &canvas, scale: area.width / 100, time: Self.reduceMotion ? 10 : context.date.timeIntervalSince(since))
            }
        }
        .frame(width: size, height: size * 1.04)
        .onChange(of: state) {
            since = Date()
            settled = false
        }
        .task(id: since) {
            try? await Task.sleep(for: .seconds(1))
            settled = true
        }
    }

    private var moving: Bool {
        guard !Self.reduceMotion else { return false }
        switch state {
        case .working, .approval: return true
        case .finished: return !settled
        default: return false
        }
    }

    // MARK: Drawing, in a 100 × 104 box

    static let center = CGPoint(x: 50, y: 50)
    private static let radius: CGFloat = 46.5
    /// The ring runs clockwise from 8 o'clock to 4 o'clock; these are degrees clockwise from 12 o'clock.
    static let start: Double = 240, sweep: Double = 240

    private func draw(in canvas: inout GraphicsContext, scale: CGFloat, time: TimeInterval) {
        canvas.scaleBy(x: scale, y: scale)
        let ink = GraphicsContext.Shading.color(.primary)
        let faint = GraphicsContext.Shading.color(.primary.opacity(0.18))
        let warn = GraphicsContext.Shading.color(Palette.warn)
        let ring = StrokeStyle(lineWidth: 8, lineCap: .round)

        canvas.stroke(Self.arc(0, Self.sweep), with: faint, style: ring)
        switch state {
        case .working:
            // A bright stretch runs round the ring.
            let phase = time.truncatingRemainder(dividingBy: 1.4) / 1.4
            let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
            let head = -70 + 310 * eased
            let from = max(0, head), to = min(Self.sweep, head + 70)
            if to > from { canvas.stroke(Self.arc(from, to), with: ink, style: ring) }
        case .approval:
            var glow = canvas
            glow.opacity = 0.72 + 0.28 * cos(time * 2 * .pi / 1.1)
            glow.stroke(Self.arc(0, Self.sweep), with: warn, style: ring)
        case .finished:
            let progress = min(1, time / 0.7)
            canvas.stroke(Self.arc(0, Self.sweep * (1 - pow(1 - progress, 3))), with: ink, style: ring)
        case .meeting(let left, _):
            let length = Self.sweep * max(0.04, min(1, left))
            canvas.stroke(Self.arc(0, length), with: ink, style: ring)
        case .idle(let awake):
            if awake { canvas.stroke(Self.arc(0, Self.sweep), with: .color(.primary.opacity(0.45)), style: ring) }
        }

        canvas.fill(Self.hair, with: ink)
        drawEyes(in: &canvas, time: time, ink: ink)

        for index in 0..<4 where !isMeeting {
            let angle = (210 - Double(index) * 20) * .pi / 180
            let point = CGPoint(x: 50 + 48 * sin(angle), y: 50 - 48 * cos(angle))
            let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            switch index < dots.count ? dots[index] : nil {
            case .asking:
                var pulse = canvas
                pulse.opacity = 0.65 + 0.35 * cos(time * 2 * .pi / 0.8)
                pulse.fill(dot, with: warn)
            case .running:
                var lit = canvas
                if state == .working { lit.opacity = 0.67 + 0.33 * cos((time - Double(index) * 0.2) * 2 * .pi / 1.2) }
                lit.fill(dot, with: ink)
            case .finished:
                canvas.fill(dot, with: .color(Palette.ok))
            case nil:
                canvas.fill(dot, with: faint)
            }
        }
    }

    private var isMeeting: Bool { if case .meeting = state { true } else { false } }

    private func drawEyes(in canvas: inout GraphicsContext, time: TimeInterval, ink: GraphicsContext.Shading) {
        let lids = StrokeStyle(lineWidth: 6, lineCap: .round)
        switch state {
        case .idle(false), .meeting(_, false):
            // Asleep.
            var closed = Path()
            for x: CGFloat in [38, 62] {
                closed.move(to: CGPoint(x: x - 6, y: 63))
                closed.addQuadCurve(to: CGPoint(x: x + 6, y: 63), control: CGPoint(x: x, y: 68))
            }
            canvas.stroke(closed, with: ink, style: lids)
        case .finished:
            var happy = Path()
            for x: CGFloat in [38, 62] {
                happy.move(to: CGPoint(x: x - 6, y: 66))
                happy.addQuadCurve(to: CGPoint(x: x + 6, y: 66), control: CGPoint(x: x, y: 57))
            }
            canvas.stroke(happy, with: ink, style: lids)
        default:
            let radius: CGFloat = state == .approval ? 7.5 : 6
            // While working Bangs glances from side to side.
            let glance = state == .working ? 5 * sin(time * 2 * .pi / 3.2) : 0
            for x: CGFloat in [38, 62] {
                canvas.fill(Path(ellipseIn: CGRect(x: x + glance - radius, y: 63 - radius, width: radius * 2, height: radius * 2)), with: ink)
            }
        }
    }

    /// Part of the ring, from `from` to `to` degrees along it.
    static func arc(_ from: Double, _ to: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(start + from - 90), endAngle: .degrees(start + to - 90), clockwise: false)
        return path
    }

    /// The fringe: a cap with a zig-zag edge.
    static let hair: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 21, y: 50))
        path.addCurve(to: CGPoint(x: 50, y: 19), control1: CGPoint(x: 21, y: 29), control2: CGPoint(x: 34, y: 19))
        path.addCurve(to: CGPoint(x: 79, y: 50), control1: CGPoint(x: 66, y: 19), control2: CGPoint(x: 79, y: 29))
        for point in [(72.5, 44), (66, 51), (58, 43.5), (50, 51), (42, 43.5), (34, 51), (27.5, 44)] {
            path.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        path.closeSubpath()
        return path
    }()
}
