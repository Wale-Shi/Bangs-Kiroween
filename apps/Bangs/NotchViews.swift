import BangsCore
import SwiftUI

/// The island's outline: concave shoulders where it meets the menu bar, rounded bottom corners.
/// Both radii animate, so the shape flows from the notch into the open panel.
struct IslandShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, (rect.height - ear) / 2, (rect.width - ear * 2) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + r, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Colours for the island. The notch is always dark; under the menu bar the panel follows the system's light or dark mode,
/// so each colour resolves against the window's appearance.
enum Palette {
    static let ink = Color(nsColor: Shade.ink)
    static let muted = adaptive(dark: NSColor(white: 0.56, alpha: 1), light: NSColor(white: 0.43, alpha: 1))
    static let dim = adaptive(dark: NSColor(white: 0.36, alpha: 1), light: NSColor(white: 0.63, alpha: 1))
    static let accent = Color(nsColor: Shade.accent)
    static let warn = Color(nsColor: Shade.warn)
    static let ok = Color(nsColor: Shade.ok)
    static let danger = adaptive(dark: NSColor(red: 1, green: 0.33, blue: 0.33, alpha: 1), light: NSColor(red: 0.86, green: 0.18, blue: 0.18, alpha: 1))
    /// A meeting's countdown.
    static let meeting = adaptive(dark: NSColor(red: 0.33, green: 0.58, blue: 1, alpha: 1), light: NSColor(red: 0.16, green: 0.42, blue: 0.9, alpha: 1))
    static let row = wash(0.06)
    /// Roughly the popover material, for snapshots.
    static let panel = adaptive(dark: NSColor(white: 0.17, alpha: 1), light: NSColor(white: 0.95, alpha: 1))
    /// The selected segment on Liquid Glass: a raised pill, white in light mode.
    static let knob = adaptive(dark: NSColor(white: 1, alpha: 0.2), light: NSColor(white: 1, alpha: 0.92))
    /// Text on an `ink` fill.
    static let inverse = adaptive(dark: .black, light: .white)

    /// A faint fill for cards, rows and buttons: white on the dark island, black on a light panel.
    static func wash(_ opacity: CGFloat) -> Color {
        adaptive(dark: NSColor(white: 1, alpha: opacity), light: NSColor(white: 0, alpha: opacity * 0.75))
    }

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: Shade.adaptive(dark: dark, light: light))
    }

    /// The same colours for AppKit and Core Animation, which resolve them against a view's appearance themselves.
    enum Shade {
        static let ink = adaptive(dark: NSColor(white: 0.98, alpha: 1), light: NSColor(white: 0.11, alpha: 1))
        static let warn = adaptive(dark: NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1), light: NSColor(red: 0.91, green: 0.50, blue: 0.05, alpha: 1))
        static let accent = adaptive(dark: NSColor(red: 0.55, green: 0.55, blue: 0.97, alpha: 1), light: NSColor(red: 0.30, green: 0.32, blue: 0.86, alpha: 1))
        static let ok = adaptive(dark: NSColor(red: 0.29, green: 0.87, blue: 0.50, alpha: 1), light: NSColor(red: 0.16, green: 0.66, blue: 0.29, alpha: 1))

        static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark }
        }
    }
}

struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore

    var body: some View {
        let size = model.size
        ZStack(alignment: .top) {
            if model.geometry.hasNotch {
                IslandShape(ear: model.ear, radius: model.radius).fill(.black)
            } else {
                PanelBackground(radius: Self.panelRadius)
            }
            VStack(spacing: 0) {
                if model.geometry.hasNotch {
                    Header(model: model, store: store)
                        .frame(width: size.width, height: model.geometry.height)
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggle() }
                        .opacity(model.retracted ? 0 : 1)
                }
                if model.mode.isOpen {
                    content
                        .id(model.mode.key)
                        .transition(.asymmetric(
                            insertion: .modifier(active: Reveal(progress: 0), identity: Reveal(progress: 1)).animation(.easeOut(duration: 0.32).delay(0.09)),
                            removal: .opacity.animation(.easeIn(duration: 0.14))))
                }
            }
            .frame(width: size.width, alignment: .top)
        }
        .frame(width: size.width + model.ear * 2, height: size.height, alignment: .top)
        .environment(\.onGlass, !model.geometry.hasNotch && Self.glass)
        .clipShape(model.geometry.hasNotch ? AnyShape(IslandShape(ear: model.ear, radius: model.radius)) : AnyShape(RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)))
        .shadow(color: .black.opacity(model.mode.isOpen ? (model.geometry.hasNotch ? 0.45 : 0.22) : 0), radius: model.geometry.hasNotch ? 20 : 14, y: model.geometry.hasNotch ? 12 : 6)
        .scaleEffect(model.swells ? 1.06 : 1, anchor: .top)
        .opacity(model.invisible ? 0 : 1)
        .animation(model.motion, value: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.hovered)
        .animation(.easeInOut(duration: 0.25), value: model.invisible)
        // Tapping the open toolbox would close it under your cursor; the header, Esc or a click outside do that.
        .onTapGesture { if model.mode != .expanded { model.toggle() } }
        // Files dropped on the island go to the shelf.
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dropTargeted }, set: { targeted in
            model.dropTargeted = targeted
            if targeted && (model.mode != .expanded || model.tool != .shelf) { model.open(.shelf) }
        })) { providers in model.toolbox.shelf.accept(providers) }
        .contextMenu {
            Button("设置…") { model.openSettings() }
            Button("退出 Bangs") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Open content keeps its final width while the shape grows, so the text never reflows; centred, it is revealed from the middle.
    @ViewBuilder private var content: some View {
        Group {
            switch model.mode {
            case .expanded: ToolboxView(model: model, store: store)
            case .approval: if let approval = store.approvals.first {
                ApprovalView(approval: approval, more: store.approvals.count - 1, store: store,
                             allowKey: model.preferences.shortcuts[.allowRequest]?.display, denyKey: model.preferences.shortcuts[.denyRequest]?.display,
                             allowsForSession: model.preferences.sessionAllow)
            }
            case .finished(let session): FinishedView(session: session, model: model, store: store)
            case .reminder(let meeting): ReminderView(meeting: meeting, model: model)
            case .captured(let url): CapturedView(url: url, model: model)
            case .screenPermission: ScreenPermissionView(model: model)
            case .update(let release): UpdateView(release: release, model: model, updater: model.toolbox.updater)
            case .recognized(let text): RecognizedView(text: text, model: model)
            case .table(let table, let text): TableView(table: table, text: text, model: model)
            case .focusEnded(let ended, let started, let agents): FocusEndedView(ended: ended, started: started, agents: agents, model: model)
            case .changes(let id): TurnChangesView(sessionId: id, model: model, store: store)
            case .translation: TranslationView(translator: model.toolbox.translator, model: model)
            case .collapsed: EmptyView()
            }
        }
        .environment(\.handoff, model.handoff)
        .padding(.horizontal, model.geometry.hasNotch ? 20 : 12)
        .padding(.top, model.geometry.hasNotch ? 4 : 10)
        .padding(.bottom, model.geometry.hasNotch ? 16 : 12)
        .frame(width: model.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in Color.clear.preference(key: ContentHeight.self, value: proxy.size.height) })
        .onPreferenceChange(ContentHeight.self) { height in model.contentHeight = height }
    }
}

extension NotchRoot {
    /// Under Liquid Glass panels are rounder; the toolbox's 8-point controls sit concentric inside it with 12 points around them.
    static var panelRadius: CGFloat { if #available(macOS 26, *) { 20 } else { 12 } }
    /// Offscreen snapshots cannot draw the system material, so they use a plain fill.
    static var solidPanel = false
    /// Whether the menu bar panel is Liquid Glass, which wants capsule controls inside it.
    static var glass: Bool { if #available(macOS 26, *) { true } else { false } }
}

extension EnvironmentValues {
    /// Inside the menu bar panel's Liquid Glass: fields and segmented controls are capsules, as the system's are there.
    @Entry var onGlass = false
}

/// A search field's backdrop: a capsule on Liquid Glass, else a rounded rectangle; ringed in the accent while focused.
private struct FieldChrome: ViewModifier {
    let focused: Bool
    @Environment(\.onGlass) private var onGlass

    func body(content: Content) -> some View {
        let shape = onGlass ? AnyShape(Capsule(style: .continuous)) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        content
            .padding(.horizontal, onGlass ? 11 : 9)
            .frame(height: onGlass ? 30 : 28)
            .background(shape.fill(Palette.wash(focused ? 0.1 : 0.06)))
            .overlay(shape.stroke(focused ? Palette.accent.opacity(0.6) : Palette.wash(0.08), lineWidth: focused ? 1 : 0.5))
    }
}

extension View {
    func fieldChrome(focused: Bool) -> some View { modifier(FieldChrome(focused: focused)) }
}

/// The menu bar panel's backdrop: Liquid Glass where the system has it (macOS 26 and later), else the translucent popover
/// material. Both follow light and dark mode.
private struct PanelBackground: View {
    let radius: CGFloat

    var body: some View {
        if NotchRoot.solidPanel {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.wash(0.14), lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            // The glass draws its own lit edge, so no hairline of ours.
            Glass(radius: radius)
        } else {
            VisualEffect(radius: radius)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.wash(0.14), lineWidth: 0.5))
        }
    }
}

@available(macOS 26, *)
private struct Glass: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = radius
        // Clear glass over a bright window in dark mode (or a dark one in light mode) leaves the text on it hard to
        // read; a tint toward the panel's own shade keeps it legible and still lets what is behind show through.
        view.tintColor = Palette.Shade.adaptive(dark: NSColor(white: 0.1, alpha: 0.6), light: NSColor(white: 1, alpha: 0.55))
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        if view.cornerRadius != radius { view.cornerRadius = radius }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rectangle: the material does not follow SwiftUI's clipping.
    private static func mask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Content fades in from a blur and settles down, as the island finishes growing.
private struct Reveal: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.97 + 0.03 * progress, anchor: .top)
            .offset(y: (1 - progress) * -8)
    }
}

// MARK: Header

struct Header: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore

    var body: some View {
        if model.mode.isOpen { open } else { closed }
    }

    /// Closed: the agent that matters most on the left, how it is going (and any meeting or load) on the right.
    private var closed: some View {
        ClosedNotch(harness: model.leadingHarness, others: model.otherSessions, status: model.status, pointer: model.pointer, awake: model.toolbox.keepAwake.active,
                    side: model.sideWidth, live: !model.retracted)
    }

    /// Open: Bangs' status icon, the readouts and the agents at work.
    private var open: some View {
        let glyph = model.glyph
        return HStack(spacing: 0) {
            StatusGlyph(state: glyph.state, dots: glyph.dots, size: 20)
                .frame(width: NotchGeometry.side)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ExtrasView(extras: model.extras)
                HStack(spacing: -3) {
                    ForEach(model.shownHarnesses, id: \.self) { harness in
                        HarnessIcon(harness: harness, size: 14)
                            .padding(1.5)
                            .background(Circle().fill(.black))
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.shownHarnesses)
            }
            .padding(.trailing, 14)
        }
        .padding(.leading, 6)
    }
}

/// Keep-awake time left, the next meeting and the CPU load, beside the status.
struct ExtrasView: View {
    let extras: [NotchModel.Extra]
    var light = false

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// How wide these readouts are drawn, so the island can make room for exactly that.
    static func width(of extras: [NotchModel.Extra]) -> CGFloat {
        func text(_ string: String) -> CGFloat { (string as NSString).size(withAttributes: [.font: font]).width }
        func symbol(_ name: String) -> CGFloat {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9.5, weight: .regular))?.size.width ?? 12
        }
        let widths = extras.map { extra in
            switch extra {
            case .awake(let label): symbol("cup.and.saucer.fill") + 3 + text(label)
            case .meeting(let label): symbol("video.fill") + 3 + text(label)
            case .focus(let label): symbol("timer") + 3 + text(label)
            case .load(let percent): text("\(percent)%")
            }
        }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 6
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(extras, id: \.self) { extra in
                switch extra {
                case .awake(let label):
                    HStack(spacing: 3) {
                        Image(systemName: "cup.and.saucer.fill").font(.system(size: 9.5)).foregroundStyle(Palette.warn)
                        Text(label)
                    }
                case .meeting(let label):
                    HStack(spacing: 3) {
                        Image(systemName: "video.fill").font(.system(size: 9.5)).foregroundStyle(Color(red: 0.36, green: 0.55, blue: 1))
                        Text(label)
                    }
                case .focus(let label):
                    HStack(spacing: 3) {
                        Image(systemName: "timer").font(.system(size: 9.5)).foregroundStyle(Palette.meeting)
                        Text(label)
                    }
                case .load(let percent):
                    Text("\(percent)%")
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(light ? Color.primary : Palette.ink)
        .fixedSize()
    }
}
