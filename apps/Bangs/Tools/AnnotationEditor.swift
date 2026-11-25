import AppKit
import Combine
import SwiftUI

/// What is being drawn on one screenshot, the tool in hand, and the history to undo.
@MainActor
final class AnnotationModel: ObservableObject {
    /// nil: nothing in hand; a click picks up a mark, a double click finishes.
    @Published var tool: AnnotationTool? { didSet { selected = nil } }
    @Published var color: AnnotationColor { didSet { Self.defaults.set(color.rawValue, forKey: "annotationColor"); restyleSelected() } }
    @Published var size: AnnotationSize { didSet { Self.defaults.set(size.rawValue, forKey: "annotationSize"); restyleSelected() } }
    @Published private(set) var annotations: [Annotation] = []
    @Published var selected: Int?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPin: () -> Void = {}

    private var past: [[Annotation]] = [], future: [[Annotation]] = []
    /// Where a change in progress (a drag) started, to undo it in one step.
    private var before: [Annotation]?
    private static let defaults = UserDefaults.standard

    /// The colour and size you used last time.
    init() {
        color = AnnotationColor(rawValue: Self.defaults.string(forKey: "annotationColor") ?? "") ?? .red
        size = AnnotationSize(rawValue: Self.defaults.integer(forKey: "annotationSize")) ?? .medium
    }

    func add(_ annotation: Annotation) { change(annotations + [annotation]) }

    func removeSelected() {
        guard let selected, annotations.indices.contains(selected) else { return }
        var next = annotations
        next.remove(at: selected)
        self.selected = nil
        change(next)
    }

    /// A drag that moves a mark: live while it moves, one step to undo.
    func begin() { before = annotations }
    func live(_ next: [Annotation]) { annotations = next }
    func end() {
        guard let before, before != annotations else { self.before = nil; return }
        past.append(before)
        future = []
        self.before = nil
        refresh()
    }

    func undo() {
        guard let last = past.popLast() else { return }
        future.append(annotations)
        annotations = last
        selected = nil
        refresh()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        past.append(annotations)
        annotations = next
        selected = nil
        refresh()
    }

    /// The next number for a counter.
    var nextCounter: Int {
        annotations.reduce(0) { if case .counter(let number, _) = $1.kind { max($0, number) } else { $0 } } + 1
    }

    private func change(_ next: [Annotation]) {
        past.append(annotations)
        future = []
        annotations = next
        refresh()
    }

    private func refresh() {
        canUndo = !past.isEmpty
        canRedo = !future.isEmpty
    }

    /// Picking a colour or size with a mark picked restyles that mark, as in other tools.
    private func restyleSelected() {
        guard let selected, annotations.indices.contains(selected) else { return }
        var next = annotations
        next[selected].color = color
        next[selected].size = size
        guard next != annotations else { return }
        change(next)
    }
}

/// The screenshot and what is drawn on it, drawn and edited with the mouse. Flipped: points run down from the top left,
/// as the annotations are kept.
final class AnnotationCanvas: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
    let model: AnnotationModel
    private lazy var mosaic = AnnotationRenderer.pixelated(image, scale: scale)
    private var draft: Annotation?
    private var start: CGPoint = .zero
    /// A mark being moved: which, and where the drag began.
    private var moving: (index: Int, from: CGPoint, original: [Annotation])?
    private var field: NSTextField?
    private var fieldOrigin: CGPoint = .zero
    private var subscription: AnyCancellable?

    init(image: CGImage, scale: CGFloat, model: AnnotationModel) {
        self.image = image
        self.scale = scale
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var imageSize: CGSize { bounds.size }

    /// The finished screenshot, at its own resolution.
    func rendered() -> CGImage? {
        commitText()
        return AnnotationRenderer.render(image, annotations: model.annotations, scale: scale, mosaic: mosaic)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        AnnotationRenderer.drawImage(image, in: bounds, context: context)
        let marks = model.annotations + (draft.map { [$0] } ?? [])
        for mark in AnnotationRenderer.layered(marks) { AnnotationRenderer.draw(mark, in: context, mosaic: mosaic, imageSize: imageSize) }
        if let selected = model.selected, model.annotations.indices.contains(selected) {
            let box = AnnotationRenderer.bounds(model.annotations[selected]).insetBy(dx: -3, dy: -3)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.white.cgColor)
            context.stroke(box)
            context.setLineDash(phase: 3.5, lengths: [4, 3])
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.stroke(box)
        }
    }

    override func resetCursorRects() {
        switch model.tool {
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .some: addCursorRect(bounds, cursor: .crosshair)
        case nil: addCursorRect(bounds, cursor: .arrow)
        }
    }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = point(event)
        if field != nil { commitText(); return }
        if event.clickCount == 2 && model.tool == nil { model.onDone(); return }
        // A mark under the pointer is picked up and can be dragged, whatever the tool.
        if let index = model.annotations.indices.reversed().first(where: { AnnotationRenderer.hits(model.annotations[$0], point) }) {
            model.selected = index
            moving = (index, point, model.annotations)
            model.begin()
            return
        }
        model.selected = nil
        guard let tool = model.tool else { return }
        start = point
        switch tool {
        case .text: beginText(at: point)
        case .counter: model.add(Annotation(kind: .counter(model.nextCounter, at: point), color: model.color, size: model.size))
        case .pen, .highlighter: draft = Annotation(kind: tool == .pen ? .pen([point]) : .highlighter([point]), color: model.color, size: model.size)
        default: draft = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var point = point(event)
        if let moving {
            let delta = CGVector(dx: point.x - moving.from.x, dy: point.y - moving.from.y)
            var next = moving.original
            next[moving.index] = moving.original[moving.index].moved(by: delta)
            model.live(next)
            return
        }
        guard let tool = model.tool else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch tool {
        case .pen, .highlighter:
            guard let draft else { return }
            if case .pen(let points) = draft.kind { self.draft?.kind = .pen(points + [point]) }
            if case .highlighter(let points) = draft.kind {
                // Shift: a straight stroke, as for marking a line of text.
                self.draft?.kind = .highlighter(shift ? [points[0], CGPoint(x: point.x, y: points[0].y)] : points + [point])
            }
        case .rectangle, .ellipse, .mosaic:
            var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            if shift && tool != .mosaic {
                let side = max(rect.width, rect.height)
                rect = CGRect(x: point.x < start.x ? start.x - side : start.x, y: point.y < start.y ? start.y - side : start.y, width: side, height: side)
            }
            let kind: Annotation.Kind = tool == .rectangle ? .rectangle(rect) : tool == .ellipse ? .ellipse(rect) : .mosaic(rect)
            draft = Annotation(kind: kind, color: model.color, size: model.size)
        case .arrow:
            if shift {
                // To the nearest 45°.
                let angle = (atan2(point.y - start.y, point.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(point.x - start.x, point.y - start.y)
                point = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
            draft = Annotation(kind: .arrow(from: start, to: point), color: model.color, size: model.size)
        case .text, .counter:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moving != nil {
            moving = nil
            model.end()
            return
        }
        guard let draft else { return }
        self.draft = nil
        // A click without a drag draws nothing.
        if AnnotationRenderer.bounds(draft).width > 3 || AnnotationRenderer.bounds(draft).height > 3 {
            if case .arrow(let from, let to) = draft.kind, hypot(to.x - from.x, to.y - from.y) < 4 { needsDisplay = true; return }
            model.add(draft)
        }
        needsDisplay = true
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AnnotationRenderer.font(model.size)
        field.textColor = model.color.color
        field.delegate = self
        field.placeholderString = "输入文字"
        field.cell?.isScrollable = true
        fieldOrigin = point
        addSubview(field)
        self.field = field
        fit(field)
        window?.makeFirstResponder(field)
    }

    /// The field grows with its text; the text inside it starts where it will be drawn.
    private func fit(_ field: NSTextField) {
        field.sizeToFit()
        let width = max(field.frame.width + 12, 60)
        field.frame = NSRect(x: fieldOrigin.x - 2, y: fieldOrigin.y, width: min(width, bounds.width - fieldOrigin.x + 2), height: field.frame.height)
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field { fit(field) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelText(); return true
        default: return false
        }
    }

    private func commitText() {
        guard let field else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        cancelText()
        if !text.isEmpty { model.add(Annotation(kind: .text(text, at: fieldOrigin), color: model.color, size: model.size)) }
    }

    private func cancelText() {
        field?.removeFromSuperview()
        field = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 53: // Esc: let go of a mark, then of the tool, then of the screenshot.
            if model.selected != nil { model.selected = nil } else if model.tool != nil { model.tool = nil } else { model.onCancel() }
        case 36, 76: model.onDone() // Return, Enter
        case 51, 117: model.removeSelected() // Delete, Forward Delete
        default:
            if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = AnnotationTool.allCases.first(where: { $0.key == key }) {
                model.tool = model.tool == tool ? nil : tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// The Edit menu's undo, redo and copy (⌘Z, ⇧⌘Z, ⌘C).
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func copy(_ sender: Any?) { model.onDone() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): model.canUndo
        case #selector(redo(_:)): model.canRedo
        default: true
        }
    }
}

/// The annotation toolbar: tools, then colour and size for the tool in hand, then undo and the ways out. Dark like other
/// tools' toolbars, so it reads over any screenshot.
struct AnnotationToolbar: View {
    @ObservedObject var model: AnnotationModel
    /// Pinning only makes sense for a region captured in place.
    var canPin = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    button(tool.symbol, "\(tool.title)（\(String(tool.key).uppercased())）", on: model.tool == tool) {
                        model.tool = model.tool == tool ? nil : tool
                    }
                }
                divider
                button("arrow.uturn.backward", "撤销（⌘Z）", enabled: model.canUndo) { model.undo() }
                button("arrow.uturn.forward", "重做（⇧⌘Z）", enabled: model.canRedo) { model.redo() }
                divider
                if canPin { button("pin", "钉在屏幕上") { model.onPin() } }
                button("xmark", "取消（esc）", tint: Color(red: 1, green: 0.42, blue: 0.4)) { model.onCancel() }
                button("checkmark", "完成并复制（回车 / 双击）", tint: Color(red: 0.3, green: 0.85, blue: 0.45)) { model.onDone() }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.82)))
            if showsOptions { options }
        }
        .environment(\.colorScheme, .dark)
    }

    /// For the tool in hand, or the mark picked.
    private var showsOptions: Bool {
        if let tool = model.tool { return tool.hasOptions }
        guard let selected = model.selected, model.annotations.indices.contains(selected) else { return false }
        if case .mosaic = model.annotations[selected].kind { return false }
        return true
    }

    private var options: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationSize.allCases, id: \.self) { size in
                Button { model.size = size } label: {
                    Circle().fill(Color.white).frame(width: [5, 8, 11][size.rawValue], height: [5, 8, 11][size.rawValue])
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(model.size == size ? 0.22 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(["细", "中", "粗"][size.rawValue])
            }
            divider
            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button { model.color = color } label: {
                    RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: color.color)).frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(model.color == color ? 1 : 0.25), lineWidth: model.color == color ? 2 : 0.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.82)))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    private func button(_ symbol: String, _ help: String, on: Bool = false, enabled: Bool = true, tint: Color = .white,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint.opacity(enabled ? 1 : 0.3))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(on ? 0.22 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// Annotating a region just captured, where it was on the screen: the rest of the screen dims, the toolbar sits under the
/// region (over it when there is no room).
@MainActor
final class AnnotationSession {
    enum Result { case done(CGImage), pin(CGImage, NSRect), cancel }
    var onFinish: (Result) -> Void = { _ in }

    private let window: AnnotationOverlay
    private let canvas: AnnotationCanvas
    private let model = AnnotationModel()
    private let rect: NSRect
    private var finished = false

    /// `rect` in screen coordinates, on `screen`.
    init(image: CGImage, rect: NSRect, screen: NSScreen) {
        self.rect = rect
        canvas = AnnotationCanvas(image: image, scale: CGFloat(image.width) / rect.width, model: model)
        window = AnnotationOverlay(screen: screen)
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let backdrop = AnnotationBackdrop(frame: NSRect(origin: .zero, size: screen.frame.size), hole: local)
        canvas.frame = local
        backdrop.addSubview(canvas)
        let toolbar = NSHostingView(rootView: AnnotationToolbar(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing))
        backdrop.addSubview(toolbar)
        window.contentView = backdrop
        // Room for the options row too, so the toolbar does not jump when it appears.
        let size = NSSize(width: toolbar.fittingSize.width, height: 72)
        let gap: CGFloat = 8
        let x = min(max(local.maxX - size.width, 6), backdrop.bounds.width - size.width - 6)
        let y: CGFloat = if local.minY - gap - size.height >= 6 {
            local.minY - gap - size.height
        } else if local.maxY + gap + size.height <= backdrop.bounds.height - 6 {
            local.maxY + gap
        } else {
            local.minY + gap
        }
        toolbar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        model.onDone = { [weak self] in self?.finish(.done) }
        model.onCancel = { [weak self] in self?.finish(.cancel) }
        model.onPin = { [weak self] in self?.finish(.pin) }
    }

    private enum Ending { case done, pin, cancel }

    func show() {
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvas)
    }

    private func finish(_ ending: Ending) {
        guard !finished else { return }
        finished = true
        let result: Result
        switch ending {
        case .cancel: result = .cancel
        case .done: result = canvas.rendered().map(Result.done) ?? .cancel
        case .pin: result = canvas.rendered().map { .pin($0, rect) } ?? .cancel
        }
        close()
        onFinish(result)
    }

    func close() {
        finished = true
        window.orderOut(nil)
    }
}

/// Covers the screen while a region is annotated.
final class AnnotationOverlay: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

/// The dimmed screen around the region, and its border.
final class AnnotationBackdrop: NSView {
    let hole: NSRect

    init(frame: NSRect, hole: NSRect) {
        self.hole = hole
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: hole).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1).setStroke()
        border.stroke()
    }

    /// Clicks outside the region and the toolbar do nothing (they would otherwise fall through to the app below).
    override func mouseDown(with event: NSEvent) {}
}

/// Annotating a screenshot already taken (a window, a scrolling page): its own window, scrolling when the image is big.
@MainActor
final class AnnotationWindow: NSObject, NSWindowDelegate {
    var onDone: (CGImage) -> Void = { _ in }
    private let window: NSWindow
    private let canvas: AnnotationCanvas
    private let model = AnnotationModel()
    private static var open: Set<AnnotationWindow> = []

    init(image: CGImage, scale: CGFloat, title: String) {
        canvas = AnnotationCanvas(image: image, scale: scale, model: model)
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.16, alpha: 1)
        let toolbar = NSHostingView(rootView: AnnotationToolbar(model: model, canPin: false).padding(8))
        let stack = NSView()
        stack.addSubview(scroll)
        stack.addSubview(toolbar)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: stack.topAnchor),
            toolbar.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 88),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ])
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(max(canvas.frame.width, toolbar.fittingSize.width + 16), visible.width * 0.85),
                          height: min(canvas.frame.height + 88, visible.height * 0.85))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: toolbar.fittingSize.width + 16, height: 240)
        super.init()
        window.delegate = self
        model.onDone = { [weak self] in
            guard let self, let image = self.canvas.rendered() else { return }
            self.window.close()
            self.onDone(image)
        }
        model.onCancel = { [weak self] in self?.window.close() }
    }

    func show() {
        Self.open.insert(self)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

/// A screenshot pinned over everything, to keep in view while you work: drag it about, double-click or esc to close.
final class PinnedImage: NSPanel {
    private static var pinned: Set<PinnedImage> = []
    private let image: CGImage

    @MainActor
    static func pin(_ image: CGImage, at rect: NSRect) {
        let panel = PinnedImage(image: image, frame: rect)
        pinned.insert(panel)
        panel.orderFrontRegardless()
    }

    private init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinnedImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = NSImage(cgImage: image, size: frame.size)
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        view.layer?.borderWidth = 0.5
        view.onClose = { [weak self] in self?.unpin() }
        view.menu = menu()
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { unpin() } else { super.keyDown(with: event) }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "存到桌面", action: #selector(saveToDesktop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭", action: #selector(unpin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: frame.size)])
    }

    @objc private func saveToDesktop() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        _ = Capture.save(image, to: Storage.unique(Storage.stamp("钉图"), in: desktop))
    }

    @objc private func unpin() {
        orderOut(nil)
        Self.pinned.remove(self)
    }
}

private final class PinnedImageView: NSImageView {
    var onClose: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose() } else { super.mouseDown(with: event) }
    }

    override var mouseDownCanMoveWindow: Bool { true }
}
