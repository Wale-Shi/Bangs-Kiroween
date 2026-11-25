import AppKit
import QuartzCore
import SwiftUI

/// The moving pictures, played by Core Animation: Bangs sets each animation up once when the state changes, and the
/// render server plays it, instead of SwiftUI drawing every frame (which took 7–11% of a CPU core for as long as an
/// agent worked). The keyframes are sampled from the same curves the SwiftUI drawings use.
enum LayerMotion {
    /// Off for snapshots, which ImageRenderer draws and which cannot hold a layer-backed view.
    nonisolated(unsafe) static var usesLayers = true
    static let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// `value(t)` sampled over one `period`, repeating for ever: about 30 samples a second, played smoothly between.
    static func loop(_ keyPath: String, period: Double, _ value: (Double) -> Double) -> CAKeyframeAnimation {
        let steps = max(8, Int(period * 30))
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...steps).map { value(period * Double($0) / Double(steps)) }
        animation.duration = period
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Colours as `appearance` shows them.
    static func resolve(_ colors: [NSColor], in appearance: NSAppearance) -> [CGColor] {
        var resolved: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance { resolved = colors.map(\.cgColor) }
        return resolved
    }
}

// MARK: The status icon

/// `StatusGlyph` as layers: the ring, the fringe, the eyes and the dots, in the drawing's 100 × 104 box.
struct GlyphLayers: NSViewRepresentable {
    let state: StatusGlyph.State
    let dots: [StatusGlyph.Dot]

    func makeNSView(context: Context) -> GlyphLayerView { GlyphLayerView() }

    func updateNSView(_ view: GlyphLayerView, context: Context) {
        // SwiftUI's colour scheme decides the ink when it differs from the window's (the snapshots set it); otherwise the
        // view keeps the window's own appearance, the menu bar's included.
        let dark = context.environment.colorScheme == .dark
        view.appearance = nil
        if (view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) != dark {
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        view.show(state, dots: dots)
    }
}

final class GlyphLayerView: NSView {
    private let canvas = CALayer()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let hair = CAShapeLayer()
    private let eyes = CAShapeLayer()
    private let lids = CAShapeLayer()
    private let dotLayers = (0..<4).map { _ in CAShapeLayer() }
    private var shown: (state: StatusGlyph.State, dots: [StatusGlyph.Dot])?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        canvas.isGeometryFlipped = true
        canvas.anchorPoint = .zero
        layer?.addSublayer(canvas)
        let full = StatusGlyph.arc(0, StatusGlyph.sweep).cgPath
        for ring in [track, ring] {
            ring.path = full
            ring.fillColor = nil
            ring.lineWidth = 8
            ring.lineCap = .round
            canvas.addSublayer(ring)
        }
        hair.path = StatusGlyph.hair.cgPath
        lids.fillColor = nil
        lids.lineWidth = 6
        lids.lineCap = .round
        for (index, dot) in dotLayers.enumerated() {
            let angle = (210 - Double(index) * 20) * .pi / 180
            let point = CGPoint(x: 50 + 48 * sin(angle), y: 50 - 48 * cos(angle))
            dot.path = CGPath(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), transform: nil)
        }
        for layer in [hair, eyes, lids] + dotLayers { canvas.addSublayer(layer) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.bounds = CGRect(x: 0, y: 0, width: 100, height: 104)
        canvas.setAffineTransform(CGAffineTransform(scaleX: bounds.width / 100, y: bounds.width / 100))
        canvas.position = .zero
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let shown { paint(shown.state, dots: shown.dots) }
    }

    func show(_ state: StatusGlyph.State, dots: [StatusGlyph.Dot]) {
        let previous = shown
        guard previous?.state != state || previous?.dots != dots else { return }
        shown = (state, dots)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint(state, dots: dots)
        // A new state starts its motion from the beginning, as the drawing does; new dots alone only restart theirs.
        if previous?.state != state { animateRing(state) }
        animateDots(state, dots: dots)
        CATransaction.commit()
    }

    /// Colours, paths and resting values: everything but the motion.
    private func paint(_ state: StatusGlyph.State, dots: [StatusGlyph.Dot]) {
        let colors = LayerMotion.resolve([.labelColor, Palette.Shade.warn, Palette.Shade.ok], in: effectiveAppearance)
        let (ink, warn, ok) = (colors[0], colors[1], colors[2])
        // As SwiftUI's `.primary.opacity(…)`: the ink, fainter.
        let faint = ink.copy(alpha: ink.alpha * 0.18) ?? ink, half = ink.copy(alpha: ink.alpha * 0.45) ?? ink
        track.strokeColor = faint
        hair.fillColor = ink
        ring.strokeStart = 0
        ring.strokeEnd = 1
        ring.opacity = 1
        switch state {
        case .working: ring.strokeColor = ink; ring.strokeEnd = 0
        case .approval: ring.strokeColor = warn
        case .finished: ring.strokeColor = ink
        case .meeting(let left, _): ring.strokeColor = ink; ring.strokeEnd = max(0.04, min(1, left))
        case .idle(let awake): ring.strokeColor = awake ? half : nil
        }
        // Eyes: asleep, happy, or open (bigger while asking).
        eyes.isHidden = true
        lids.isHidden = true
        lids.strokeColor = ink
        eyes.fillColor = ink
        switch state {
        case .idle(false), .meeting(_, false):
            lids.path = Self.lids(y: 63, control: 68)
            lids.isHidden = false
        case .finished:
            lids.path = Self.lids(y: 66, control: 57)
            lids.isHidden = false
        default:
            let radius: CGFloat = state == .approval ? 7.5 : 6
            let path = CGMutablePath()
            for x: CGFloat in [38, 62] { path.addEllipse(in: CGRect(x: x - radius, y: 63 - radius, width: radius * 2, height: radius * 2)) }
            eyes.path = path
            eyes.isHidden = false
        }
        let meeting = if case .meeting = state { true } else { false }
        for (index, layer) in dotLayers.enumerated() {
            layer.isHidden = meeting
            layer.opacity = 1
            layer.fillColor = switch index < dots.count ? dots[index] : nil {
            case .asking: warn
            case .running: ink
            case .finished: ok
            case nil: faint
            }
        }
    }

    private static func lids(y: CGFloat, control: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for x: CGFloat in [38, 62] {
            path.move(to: CGPoint(x: x - 6, y: y))
            path.addQuadCurve(to: CGPoint(x: x + 6, y: y), control: CGPoint(x: x, y: control))
        }
        return path
    }

    private func animateRing(_ state: StatusGlyph.State) {
        for layer in [ring, eyes] { layer.removeAllAnimations() }
        guard !LayerMotion.reduce else {
            if state == .working { ring.strokeEnd = 70.0 / StatusGlyph.sweep }
            return
        }
        switch state {
        case .working:
            // A bright stretch runs round the ring, easing in and out every 1.4 s.
            let head = { (time: Double) -> Double in
                let phase = time.truncatingRemainder(dividingBy: 1.4) / 1.4
                let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
                return -70 + 310 * eased
            }
            ring.add(LayerMotion.loop("strokeStart", period: 1.4) { max(0, head($0)) / StatusGlyph.sweep }, forKey: "start")
            ring.add(LayerMotion.loop("strokeEnd", period: 1.4) { min(StatusGlyph.sweep, head($0) + 70) / StatusGlyph.sweep }, forKey: "end")
            // Bangs glances from side to side.
            eyes.add(LayerMotion.loop("transform.translation.x", period: 3.2) { 5 * sin($0 * 2 * .pi / 3.2) }, forKey: "glance")
        case .approval:
            ring.add(LayerMotion.loop("opacity", period: 1.1) { 0.72 + 0.28 * cos($0 * 2 * .pi / 1.1) }, forKey: "glow")
        case .finished:
            // One sweep round, then still.
            let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
            sweep.values = (0...21).map { step -> Double in 1 - pow(1 - Double(step) / 21, 3) }
            sweep.duration = 0.7
            ring.add(sweep, forKey: "sweep")
        default:
            break
        }
    }

    private func animateDots(_ state: StatusGlyph.State, dots: [StatusGlyph.Dot]) {
        for (index, layer) in dotLayers.enumerated() {
            layer.removeAllAnimations()
            guard !LayerMotion.reduce, index < dots.count else { continue }
            switch dots[index] {
            case .asking:
                layer.add(LayerMotion.loop("opacity", period: 0.8) { 0.65 + 0.35 * cos($0 * 2 * .pi / 0.8) }, forKey: "pulse")
            case .running where state == .working:
                layer.add(LayerMotion.loop("opacity", period: 1.2) { 0.67 + 0.33 * cos(($0 - Double(index) * 0.2) * 2 * .pi / 1.2) }, forKey: "pulse")
            default:
                break
            }
        }
    }
}

// MARK: The notch's bars

/// Three bars stretching one after another while an agent works, as layers; `running` off holds them still.
struct PulseBars: NSViewRepresentable {
    let asking: Bool
    let running: Bool
    /// The side of the square they fill (13 at full size).
    let size: CGFloat

    func makeNSView(context: Context) -> PulseBarsView { PulseBarsView() }

    func updateNSView(_ view: PulseBarsView, context: Context) {
        view.show(asking: asking, running: running && !LayerMotion.reduce, size: size)
    }
}

final class PulseBarsView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }
    private var shown: (asking: Bool, running: Bool, size: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars { layer?.addSublayer(bar) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let shown { recolor(asking: shown.asking) }
    }

    /// Each bar's height as a share of the full one at `time`: it follows the one before it by a sixth of a beat.
    static func scale(_ index: Int, at time: Double) -> Double {
        let phase = (time / 0.9 - Double(index) / 6) * 2 * .pi
        return 0.3 + 0.7 * (0.5 - 0.5 * cos(phase))
    }

    func show(asking: Bool, running: Bool, size: CGFloat) {
        let previous = shown
        guard previous?.asking != asking || previous?.running != running || previous?.size != size else { return }
        shown = (asking, running, size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let unit = size / 13
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 3 * unit, height: 13 * unit)
            bar.cornerRadius = 1.5 * unit
            bar.position = CGPoint(x: (1.5 + 5 * CGFloat(index)) * unit, y: size / 2)
            bar.transform = CATransform3DMakeScale(1, Self.scale(index, at: 0), 1)
        }
        recolor(asking: asking)
        if previous?.running != running {
            for (index, bar) in bars.enumerated() {
                bar.removeAllAnimations()
                if running { bar.add(LayerMotion.loop("transform.scale.y", period: 0.9) { Self.scale(index, at: $0) }, forKey: "pulse") }
            }
        }
        CATransaction.commit()
    }

    private func recolor(asking: Bool) {
        let color = LayerMotion.resolve([asking ? Palette.Shade.warn : Palette.Shade.ink], in: effectiveAppearance)[0]
        for bar in bars { bar.backgroundColor = color }
    }
}

// MARK: The session list's spinner

/// `Spinner` as layers: a faint ring and a 70% arc turning once every 0.9 s.
struct SpinnerLayers: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.color = color
    }
}

final class SpinnerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    var color: NSColor = .labelColor {
        didSet { if color != oldValue { recolor() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0.7
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        // Clockwise: the layer's y axis points up.
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 0.9
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "turn")
        recolor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        for shape in [track, arc] {
            shape.bounds = bounds
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            shape.path = path
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        let resolved = LayerMotion.resolve([color], in: effectiveAppearance)[0]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = resolved
        track.strokeColor = resolved.copy(alpha: resolved.alpha * 0.25)
        CATransaction.commit()
    }
}
