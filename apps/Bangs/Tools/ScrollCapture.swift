import AppKit
import ScreenCaptureKit

/// A scrolling screenshot: you frame a region, scroll whatever is under it (down, up, or sideways), and Bangs stitches the
/// frames into one long image.
@MainActor
final class ScrollCapture: ScreenCapture {
    var onFinish: (URL?, String?) -> Void = { _, _ in }
    private let output: URL
    /// One per screen until the box is drawn; then the one it was drawn on, dimming the rest of that screen.
    private var overlays: [SelectionOverlay] = []
    private var overlay: SelectionOverlay? { overlays.first }
    private var cursor = false
    private var hud: NSPanel?
    private var hudText: NSTextField?
    private var task: Task<Void, Never>?
    private let stitcher = Stitcher()
    /// Frames are stitched here, one at a time. On the main thread the work (tens of milliseconds a frame) held up the
    /// scroll events passing through `ScrollKeys`' tap: the page stuttered under your fingers, jumped further between
    /// frames, and the stitch lost its place.
    private let work = DispatchQueue(label: "bangs.scroll.stitch", qos: .userInitiated)
    /// How the stitch stood after the last frame, for the bar.
    private var progress = Stitcher.Progress()
    private let focus = CaptureFocus()
    private var keyMonitor: Any?
    /// Return, Esc and Space while you scroll; nil without Accessibility.
    private var keys: ScrollKeys?
    private var finished = false
    private var scale: CGFloat = 2

    private let lockKey: HoldKey

    init(output: URL, lockKey: HoldKey = .space) {
        self.output = output
        self.lockKey = lockKey
    }

    func start() {
        overlays = NSScreen.screens.map { screen in
            let overlay = SelectionOverlay(screen: screen, hint: "拖出要截取的区域，然后上下或左右滚动页面 · esc 取消")
            overlay.onSelect = { [weak self, weak overlay] rect in
                guard let self, let overlay else { return }
                // The other screens are free again.
                for other in self.overlays where other !== overlay { other.orderOut(nil) }
                self.overlays = [overlay]
                if self.cursor { NSCursor.pop(); self.cursor = false }
                self.begin(rect, on: screen)
            }
            overlay.onCancel = { [weak self] in self?.finish(save: false) }
            return overlay
        }
        focus.take()
        for overlay in overlays { overlay.orderFrontRegardless() }
        (overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first)?.makeKey()
        NSCursor.crosshair.push()
        cursor = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: self?.finish(save: false); return nil
            case 36, 76: self?.finish(save: true); return nil
            default: return event
            }
        }
    }

    private func begin(_ rect: NSRect, on screen: NSScreen) {
        Log.write("scroll: selected \(rect) on \(screen.localizedName) scale \(screen.backingScaleFactor)")
        overlay?.ignoresMouseEvents = true
        scale = screen.backingScaleFactor
        keys = ScrollKeys(key: lockKey, axis: { [weak self] in self?.progress.axis })
        keys?.onFinish = { [weak self] save in self?.finish(save: save) }
        keys?.onChange = { [weak self] in self?.update() }
        if keys == nil { Log.write("scroll: no Accessibility, so no keys while scrolling") }
        showHUD(below: rect, on: screen)
        // Scroll events go to the window under the pointer, so give the page back its focus too.
        focus.returnKeyboard()
        let kept = Capture.keptWindows()
        task = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == number }) ?? content.displays.first else { throw CaptureError.noDisplay }
                let own = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: content.windows.filter { kept.contains($0.windowID) })
                Log.write("scroll: display \(display.displayID) \(display.width)x\(display.height), excluding \(own.count) own app(s)")
                var frames = 0
                let config = SCStreamConfiguration()
                let scale = screen.backingScaleFactor
                config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                config.showsCursor = false
                config.scalesToFit = false
                while !Task.isCancelled {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard let self else { return }
                    let progress = await self.stitch(image)
                    // Finished or cancelled while the frame was being stitched.
                    guard !self.finished else { return }
                    self.progress = progress
                    frames += 1
                    if frames <= 3 || frames % 50 == 0 {
                        Log.write("scroll: frame \(frames) \(image.width)x\(image.height), stitched \(progress.length) px \(progress.axis.map { "\($0)" } ?? "still"), lost \(progress.lost), fixed \(progress.fixed)")
                    }
                    self.update()
                    if progress.full { self.finish(save: true); return }
                    // As often as captures come back: the less the page moves between frames, the surer the match.
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
            } catch is CancellationError {
            } catch {
                Log.write("scroll: capture failed: \(error)")
                guard let self else { return }
                self.fail(CGPreflightScreenCaptureAccess() ? "截图失败：\(error.localizedDescription)" : "需要在「系统设置 → 隐私与安全性 → 屏幕录制」里允许 Bangs")
            }
        }
    }

    private enum CaptureError: Error { case noDisplay }

    private func stitch(_ image: CGImage) async -> Stitcher.Progress {
        await withCheckedContinuation { continuation in
            work.async { [stitcher] in
                stitcher.add(image)
                continuation.resume(returning: stitcher.progress)
            }
        }
    }

    private func showHUD(below rect: NSRect, on screen: NSScreen) {
        let width: CGFloat = 520, height: CGFloat = 40
        var origin = NSPoint(x: rect.midX - width / 2, y: rect.minY - height - 10)
        if origin.y < screen.visibleFrame.minY { origin.y = rect.maxY + 10 }
        if origin.y + height > screen.visibleFrame.maxY { origin.y = rect.minY + 10 }
        origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - width - 8)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.textColor = .white
        text.frame = NSRect(x: 14, y: 12, width: width - 150, height: 16)
        let done = NSButton(title: "完成", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: width - 132, y: 6, width: 60, height: 28)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: width - 70, y: 6, width: 60, height: 28)
        for view in [text, done, cancel] { background.addSubview(view) }
        panel.contentView = background
        panel.orderFrontRegardless()
        hud = panel
        hudText = text
        update()
    }

    /// The bar's line: how the capture goes, and what the keys do (only said when they work).
    private func update() {
        if progress.lost { return say("滚得太快，跟丢了：往回滚一点再慢慢滚") }
        if let keys, keys.held {
            return say(keys.locked.map { "已锁定，只\($0 == .horizontal ? "左右" : "上下")滚动 · 松开\(keys.key.name)解除" } ?? "已按住\(keys.key.name)：先滚动的方向会被锁定")
        }
        let done = keys.map { " · 按住\($0.key.name)锁定方向 · ↩ 完成" } ?? ""
        guard let axis = progress.axis else { return say("上下或左右滚动开始截取" + done) }
        say("\(axis == .horizontal ? "左右" : "上下")滚动 · 已拼接 \(Int(CGFloat(progress.length) / scale)) pt" + done)
    }

    private lazy var returnKey = Keycap.returnImage(size: 10, color: .white)

    /// The bar's line, ↩ drawn as Bangs' return key rather than the font's arrow.
    private func say(_ line: String) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let text = NSMutableAttributedString()
        for (index, part) in line.components(separatedBy: "↩").enumerated() {
            if index > 0, let image = returnKey {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -3, width: image.size.width, height: image.size.height)
                text.append(NSAttributedString(attachment: attachment))
            }
            text.append(NSAttributedString(string: part, attributes: attributes))
        }
        hudText?.attributedStringValue = text
    }

    func cancel() { finish(save: false) }

    @objc private func doneClicked() { finish(save: true) }
    @objc private func cancelClicked() { finish(save: false) }

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        Log.write("scroll: finish save=\(save) length=\(progress.length)")
        task?.cancel()
        task = nil
        tearDown()
        guard save else { onFinish(nil, nil); return }
        // After the frame being stitched, if there is one; and a long image takes a second or two to put together and
        // compress, which must not freeze the island.
        work.async { [self, stitcher, output] in
            let saved = stitcher.compose().map { Capture.save($0, to: output) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch saved {
                    case true?: self.onFinish(output, nil)
                    case false?: self.onFinish(nil, "无法保存截图")
                    case nil: self.onFinish(nil, nil)
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        task?.cancel()
        task = nil
        tearDown()
        onFinish(nil, message)
    }

    private func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keys?.stop()
        keys = nil
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = []
        if cursor { NSCursor.pop(); cursor = false }
        hud?.orderOut(nil)
        hud = nil
        focus.restore()
    }
}

/// Dims the screen and lets you drag out the region to capture.
final class SelectionOverlay: NSWindow {
    var onSelect: (NSRect) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private let selection = SelectionView()

    init(screen: NSScreen, hint: String) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        selection.hint = hint
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        selection.frame = NSRect(origin: .zero, size: screen.frame.size)
        selection.onDone = { [weak self] rect in
            guard let self else { return }
            self.onSelect(rect.offsetBy(dx: self.frame.minX, dy: self.frame.minY))
        }
        contentView = selection
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    /// White text on a dark rounded box, readable over any page.
    static func label(_ text: String, size: CGFloat, centredAt centre: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: size * 0.8, height: size * 0.4)
        let box = NSRect(x: centre.x - textSize.width / 2 - padding.width, y: centre.y - textSize.height / 2 - padding.height,
                         width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height * 0.3, yRadius: box.height * 0.3).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + padding.width, y: box.minY + padding.height), withAttributes: attributes)
    }

    /// The box's size in points, under its corner (above it near the screen's bottom).
    private func drawSize(of rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let below = rect.minY - 16 > bounds.minY + 10
        let x = min(max(rect.maxX - 34, bounds.minX + 40), bounds.maxX - 40)
        Self.label(text, size: 11, centredAt: NSPoint(x: x, y: below ? rect.minY - 16 : rect.maxY + 16))
    }

    var onDone: (NSRect) -> Void = { _ in }
    var hint = ""
    private var anchor: NSPoint?
    private var rect: NSRect?
    private var fixed = false

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard !fixed else { return }
        anchor = convert(event.locationInWindow, from: nil)
        rect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !fixed, let anchor else { return }
        // Past the screen's edge the box stops at the edge: a capture is of one screen.
        var point = convert(event.locationInWindow, from: nil)
        point.x = min(max(point.x, bounds.minX), bounds.maxX)
        point.y = min(max(point.y, bounds.minY), bounds.maxY)
        rect = NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).integral
        needsDisplay = true
    }

    /// Small enough for a single line of text to read, big enough that a click is not a capture.
    static let smallest: CGFloat = 4

    override func mouseUp(with event: NSEvent) {
        guard !fixed, let rect, rect.width >= Self.smallest, rect.height >= Self.smallest else {
            // Too small to mean anything: start again.
            rect = nil
            needsDisplay = true
            return
        }
        fixed = true
        needsDisplay = true
        onDone(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let rect {
            dim.append(NSBezierPath(rect: rect).reversed)
        }
        NSColor.black.withAlphaComponent(fixed ? 0.45 : 0.3).setFill()
        dim.fill()
        if let rect {
            let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1).setStroke()
            border.stroke()
            if !fixed { drawSize(of: rect) }
        } else if !hint.isEmpty {
            Self.label(hint, size: 15, centredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        }
    }
}

/// Joins frames of a scrolling page: each new frame contributes only the rows that scrolled into view.
/// Not safe to use from two threads at once: a capture keeps it to one queue.
final class Stitcher: @unchecked Sendable {
    /// Which way the page scrolls: settled by the first movement, then kept for the capture.
    enum Axis { case vertical, horizontal }

    private(set) var axis: Axis?
    /// What has been captured, as strips placed along the axis, counted from where the first frame starts. Scrolling
    /// back over them adds nothing; scrolling past either end adds a strip there.
    private var strips: [(image: CGImage, at: Int)] = []
    private var start = 0, end = 0
    /// Where the last frame that lined up starts, and its signatures each way.
    private var position = 0
    private var last: (rows: Signature, columns: Signature?)?
    private var first: CGImage?
    /// The last frame did not line up with the one before (scrolled too far at once); later frames are matched against
    /// the last one that did, so scrolling back a little picks the thread up again.
    private(set) var lost = false
    /// Long enough; stop before the image gets unwieldy.
    var full: Bool { length > 30_000 }
    /// The stitched length along the axis, in pixels (the frame's height until the page has moved).
    var length: Int { axis == nil ? first?.height ?? 0 : extent(head) + end - start + extent(tail) }

    /// What does not scroll with the page at the frame's two ends, in rows along the axis: a header or toolbar that
    /// stays put at the start, a footer or input bar at the end. Strips are cut clear of them, and each is drawn once,
    /// at its end of the image; taken from every frame, a footer would repeat down the whole image, covering the page
    /// under it.
    ///
    /// They are the rows at each end that look the same in two frames the page moved between, the most seen over the
    /// last few such pairs: one pair may come short (a caret blinking in the footer), and too many rows cost nothing,
    /// since rows that only looked fixed (a blank margin) are drawn where the screen showed them all the same.
    private(set) var fixed: Edges = (0, 0)
    private var recent: [Edges] = []
    /// The frame's fixed rows as last seen at the image's two ends.
    private var head: CGImage?, tail: CGImage?

    typealias Edges = (lead: Int, trail: Int)

    private func extent(_ image: CGImage?) -> Int { image.map { axis == .horizontal ? $0.width : $0.height } ?? 0 }

    /// How the stitch stands, to show while it goes on.
    struct Progress: Sendable {
        var axis: Axis?
        var length = 0
        var lost = false
        var full = false
        var fixed = 0
    }

    var progress: Progress { Progress(axis: axis, length: length, lost: lost, full: full, fixed: fixed.lead + fixed.trail) }
    var height: Int { axis == .horizontal ? first?.height ?? 0 : length }

    /// Each pixel row as the mean brightness of narrow column blocks. Apps redraw text a little differently after a
    /// scroll (sub-pixel offsets, re-rasterised glyphs), so rows are compared with a tolerance rather than exactly.
    /// Columns, for a sideways scroll, are rows of the image turned on its side.
    struct Signature: Equatable {
        let rows: Int
        let blocks: Int
        let values: [UInt8]

        /// Mean difference per block between row `a` of this frame and row `b` of another.
        func distance(_ a: Int, _ other: Signature, _ b: Int) -> Int {
            var total = 0
            let x = a * blocks, y = b * other.blocks
            for k in 0..<blocks { total += abs(Int(values[x + k]) - Int(other.values[y + k])) }
            return total / blocks
        }

        /// Whether row `a` of this frame shows what row `b` of another does: close on average, and no more than one block
        /// far off (a blinking caret, a hover highlight). The average alone could forgive a differing word in a row
        /// otherwise like its neighbours (a list, a chat).
        func matches(_ a: Int, _ other: Signature, _ b: Int) -> Bool {
            var total = 0, outliers = 0
            let x = a * blocks, y = b * other.blocks
            for k in 0..<blocks {
                let difference = abs(Int(values[x + k]) - Int(other.values[y + k]))
                if difference > 40 {
                    outliers += 1
                    if outliers > 1 { return false }
                }
                total += difference
            }
            return total <= 6 * blocks
        }

        /// Rows with something drawn on them; blank rows match anything and prove nothing.
        func detailed(_ row: Int) -> Bool {
            var low: UInt8 = 255, high: UInt8 = 0
            for k in 0..<blocks { let value = values[row * blocks + k]; low = min(low, value); high = max(high, value) }
            return high - low >= 12
        }
    }

    /// How far the page must move before its direction counts: less is the jitter of a finger landing on the trackpad,
    /// which often drags the page a pixel or two up or down before a sideways scroll gets going.
    static let settleDistance = 16

    /// The latest frame that moved, a little, before the direction was settled.
    private var pending: (image: CGImage, rows: Signature, columns: Signature?)?

    /// Adds a frame and returns the stitched length in pixels.
    @discardableResult
    func add(_ image: CGImage) -> Int {
        guard let rows = Self.signatures(image) else { return length }
        let columns = axis == .vertical ? nil : Self.signatures(image, axis: .horizontal)
        guard let last else {
            strips = [(image, 0)]
            first = image
            self.last = (rows, columns)
            return length
        }
        // The rows that stayed put between this frame and the last. Matching goes by these two frames alone, not by
        // `fixed`: that errs on the side of more rows, which is right for cutting strips and would here set aside rows
        // that do line up.
        let pair: Edges = switch axis {
        case .vertical?: Self.fixedEdges(from: last.rows, to: rows)
        case .horizontal?: last.columns.flatMap { old in columns.map { Self.fixedEdges(from: old, to: $0) } } ?? (0, 0)
        case nil: (0, 0)
        }
        // Still: nothing to do. Going by the rows that scroll: under a tall header and footer the rest of the frame
        // moving would otherwise pass for nothing having changed.
        let moving = axis == .vertical ? Self.samples(rows).filter { $0 >= pair.lead && $0 < rows.rows - pair.trail } : []
        if Self.score(from: last.rows, to: rows, shift: 0, sample: moving.count >= 8 ? moving : nil) ?? 0 >= 0.9,
           axis == .vertical || last.columns.flatMap({ old in columns.flatMap { Self.score(from: old, to: $0, shift: 0) } }) ?? 0 >= 0.9 {
            lost = false
            return length
        }
        guard let axis else {
            settle(image, rows: rows, columns: columns)
            return length
        }
        guard let old = axis == .vertical ? last.rows : last.columns, let new = axis == .vertical ? rows : columns,
              let shift = Self.match(from: old, to: new, fixed: pair)?.shift, shift != 0 else {
            lost = true
            return length
        }
        note(pair)
        advance(image, by: shift, along: axis, rows: rows, columns: columns)
        return length
    }

    /// Before the direction is known. Measured against the frame it started from, the page must move far enough one way
    /// to count (so a slow start loses nothing). Moving a little one way and then the other (the jitter of a landing
    /// finger, then the real scroll) starts again from where the jitter left the page.
    private func settle(_ image: CGImage, rows: Signature, columns: Signature?) {
        guard let base = last else { return }
        let fromBase = Self.best(from: base, to: (rows, columns))
        if let fromBase, abs(fromBase.shift) >= Self.settleDistance {
            begin(along: fromBase.axis, fixed: fromBase.fixed)
            advance(image, by: fromBase.shift, along: fromBase.axis, rows: rows, columns: columns)
            return
        }
        if let pending, let fromPending = Self.best(from: (pending.rows, pending.columns), to: (rows, columns)),
           fromBase == nil || fromPending.axis != fromBase?.axis {
            strips = [(pending.image, 0)]
            first = pending.image
            last = (pending.rows, pending.columns)
            self.pending = nil
            if abs(fromPending.shift) >= Self.settleDistance {
                begin(along: fromPending.axis, fixed: fromPending.fixed)
                advance(image, by: fromPending.shift, along: fromPending.axis, rows: rows, columns: columns)
            } else {
                self.pending = (image, rows, columns)
            }
            lost = false
            return
        }
        guard fromBase != nil else { lost = true; return }
        lost = false
        pending = (image, rows, columns)
    }

    /// The surer of the two directions a frame may have moved in, with the rows that stayed put across it.
    private static func best(from old: (rows: Signature, columns: Signature?), to new: (rows: Signature, columns: Signature?)) -> (axis: Axis, shift: Int, fixed: Edges)? {
        func moved(_ old: Signature?, _ new: Signature?) -> (shift: Int, score: Double, fixed: Edges)? {
            guard let old, let new else { return nil }
            let fixed = fixedEdges(from: old, to: new)
            guard let match = match(from: old, to: new, fixed: fixed), match.shift != 0 else { return nil }
            return (match.shift, match.score, fixed)
        }
        return switch (moved(old.rows, new.rows), moved(old.columns, new.columns)) {
        case let (v?, h?): v.score >= h.score ? (.vertical, v.shift, v.fixed) : (.horizontal, h.shift, h.fixed)
        case let (v?, nil): (.vertical, v.shift, v.fixed)
        case let (nil, h?): (.horizontal, h.shift, h.fixed)
        case (nil, nil): nil
        }
    }

    /// The direction is settled: the frame the capture started from is cut into what stays put at its two ends and the
    /// page between them.
    private func begin(along axis: Axis, fixed: Edges) {
        self.axis = axis
        self.fixed = fixed
        recent = [fixed]
        guard let first else { return }
        let frame = axis == .vertical ? first.height : first.width
        start = fixed.lead
        end = frame - fixed.trail
        guard fixed.lead > 0 || fixed.trail > 0, let page = Self.crop(first, along: axis, from: start, to: end) else {
            start = 0
            end = frame
            return
        }
        strips = [(page, start)]
        head = Self.crop(first, along: axis, from: 0, to: fixed.lead)
        tail = Self.crop(first, along: axis, from: end, to: frame)
    }

    /// Takes in the rows that stayed put between the last two frames: the most of the last three pairs counts.
    private func note(_ edges: Edges) {
        recent.append(edges)
        if recent.count > 3 { recent.removeFirst() }
        fixed = (recent.map(\.lead).max() ?? 0, recent.map(\.trail).max() ?? 0)
    }

    /// The frame `shift` further along than the last one: what is new past either end joins the image.
    private func advance(_ image: CGImage, by shift: Int, along axis: Axis, rows: Signature, columns: Signature?) {
        lost = false
        let frame = axis == .vertical ? image.height : image.width
        let at = position + shift
        // New content past the far end, then before the near end; what lies between was captured already. Each strip
        // stops short of the fixed rows at its own end only: at the other it joins what is there, whatever the rows.
        if at + frame - fixed.trail > end, let strip = Self.crop(image, along: axis, from: max(0, end - at), to: frame - fixed.trail) {
            strips.append((strip, max(at, end)))
            // The image ends with this frame's last rows, unless an earlier frame reached further (you scrolled back,
            // and rows that had looked fixed turned out to be the page): then with what is left of that one's.
            let reach = end + extent(tail), to = at + frame - fixed.trail
            tail = at + frame >= reach ? Self.crop(image, along: axis, from: frame - fixed.trail, to: frame)
                : tail.flatMap { Self.crop($0, along: axis, from: to - end, to: extent($0)) }
            end = to
        } else if at + frame > end + extent(tail) {
            // Further along than any frame before, though with nothing to add to the page (more rows stayed put than
            // it moved by): the image still ends where this frame does.
            tail = Self.crop(image, along: axis, from: end - at, to: frame)
        }
        if at + fixed.lead < start, let strip = Self.crop(image, along: axis, from: fixed.lead, to: min(frame, start - at)) {
            strips.append((strip, at + fixed.lead))
            let reach = start - extent(head), from = at + fixed.lead
            head = at <= reach ? Self.crop(image, along: axis, from: 0, to: fixed.lead)
                : head.flatMap { Self.crop($0, along: axis, from: 0, to: extent($0) - (start - from)) }
            start = from
        } else if at < start - extent(head) {
            head = Self.crop(image, along: axis, from: 0, to: start - at)
        }
        position = at
        last = (rows, axis == .horizontal ? columns : nil)
    }

    /// The rows at each end of the frame that look the same in two frames the page moved between. None when they would
    /// leave under a quarter of the frame to move: that is a page mostly blank, not one mostly toolbar.
    static func fixedEdges(from old: Signature, to new: Signature) -> Edges {
        guard old.rows == new.rows, old.blocks == new.blocks else { return (0, 0) }
        let count = new.rows
        var lead = 0, trail = 0
        while lead < count, new.matches(lead, old, lead) { lead += 1 }
        while trail < count - lead, new.matches(count - 1 - trail, old, count - 1 - trail) { trail += 1 }
        return lead + trail > count * 3 / 4 ? (0, 0) : (lead, trail)
    }

    /// A slice of `image` across the axis, from `from` to `to` pixels along it, in pixels of its own: a cropped CGImage
    /// keeps its whole frame alive, and a slow scroll leaves hundreds of thin slices (gigabytes of frames).
    private static func crop(_ image: CGImage, along axis: Axis, from: Int, to: Int) -> CGImage? {
        guard to > from else { return nil }
        // CGImage crops from the top left.
        guard let slice = image.cropping(to: axis == .vertical ? CGRect(x: 0, y: from, width: image.width, height: to - from)
                                                               : CGRect(x: from, y: 0, width: to - from, height: image.height)) else { return nil }
        guard let context = CGContext(data: nil, width: slice.width, height: slice.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return slice }
        context.draw(slice, in: CGRect(x: 0, y: 0, width: slice.width, height: slice.height))
        return context.makeImage()
    }

    func compose() -> CGImage? {
        guard let first else { return nil }
        // The page never moved: the one frame is the screenshot.
        guard let axis else { return first }
        let length = length, lead = extent(head)
        let width = axis == .vertical ? first.width : length
        let height = axis == .vertical ? length : first.height
        // In the screen's own colours (Display P3 on most Macs), not converted to sRGB.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var pieces = strips.map { (image: $0.image, offset: lead + $0.at - start) }
        if let head { pieces.append((head, 0)) }
        if let tail { pieces.append((tail, lead + end - start)) }
        for strip in pieces {
            let offset = strip.offset
            // The context draws from the bottom left.
            let rect = axis == .vertical ? CGRect(x: 0, y: height - offset - strip.image.height, width: strip.image.width, height: strip.image.height)
                                         : CGRect(x: offset, y: 0, width: strip.image.width, height: strip.image.height)
            context.draw(strip.image, in: rect)
        }
        return context.makeImage()
    }

    /// The share of the new frame's detailed rows that look like the old frame's rows `shift` further along.
    /// A row is compared only where the old frame showed the page too, not its `fixed` rows: what has scrolled in from
    /// under a footer was not there to compare with.
    private static func score(from old: Signature, to new: Signature, shift: Int, sample: [Int]? = nil, fixed: Edges = (0, 0)) -> Double? {
        let rows = sample ?? samples(new)
        var compared = 0, matched = 0
        for row in rows where row < new.rows && row + shift >= fixed.lead && row + shift < old.rows - fixed.trail {
            compared += 1
            if new.matches(row, old, row + shift) { matched += 1 }
        }
        return compared >= 8 ? Double(matched) / Double(compared) : nil
    }

    /// Up to 240 detailed rows, spread over the frame.
    private static func samples(_ signature: Signature) -> [Int] {
        let detailed = (0..<signature.rows).filter { signature.detailed($0) }
        let step = max(1, detailed.count / 240)
        return stride(from: 0, to: detailed.count, by: step).map { detailed[$0] }
    }

    /// How far the content moved between two frames, in rows: positive when it moved up (you scrolled down), negative
    /// when you scrolled back. It is the offset, nearest first, at which the new frame's detailed rows best match the
    /// old frame's; nil when nothing lines up (scrolled too far at once).
    static func shift(from old: Signature, to new: Signature) -> Int? { match(from: old, to: new)?.shift }

    /// The shift, with the share of rows that matched at it. Rows that do not scroll with the page (`fixed`) say nothing
    /// of how far it moved, and enough of them (a tall header and an input bar) would outvote the rows that do.
    static func match(from old: Signature, to new: Signature, fixed: Edges = (0, 0)) -> (shift: Int, score: Double)? {
        guard old.blocks == new.blocks else { return nil }
        let count = min(old.rows, new.rows)
        var sample = samples(new)
        let moving = sample.filter { $0 >= fixed.lead && $0 < new.rows - fixed.trail }
        if moving.count >= 8 { sample = moving }
        guard sample.count >= 8 else { return nil }
        var best: (shift: Int, score: Double)?
        var open = (down: true, up: true)
        for distance in 1..<max(2, count * 19 / 20) {
            for shift in [distance, -distance] where shift > 0 ? open.down : open.up {
                guard let score = score(from: old, to: new, shift: shift, sample: sample, fixed: moving.count >= 8 ? fixed : (0, 0)) else {
                    if shift > 0 { open.down = false } else { open.up = false }
                    continue
                }
                if score > (best?.score ?? 0.8) { best = (shift, score) }
            }
            // A near-perfect match this close is the movement: on a page of look-alike rows (a list, a table), a
            // farther offset may match as well, and the nearest is the one scrolling produced.
            if let best, best.score >= 0.97 { return best }
            if !open.down && !open.up { break }
        }
        return best
    }

    /// The brightness of each row in blocks of at least 8 pixels, ignoring the right edge where overlay scroll bars
    /// appear; sideways, of each column, ignoring the bottom edge.
    static func signatures(_ image: CGImage, axis: Axis = .vertical) -> Signature? {
        if axis == .horizontal { return columnSignatures(image) }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let usable = max(1, width - 48)
        let blockWidth = max(8, usable / 96)
        let blocks = max(1, usable / blockWidth)
        var values = [UInt8](repeating: 0, count: height * blocks)
        // A bitmap context's memory holds the top row first.
        for row in 0..<height {
            for block in 0..<blocks {
                var total = 0
                var x = block * blockWidth
                let end = x + blockWidth
                while x < end {
                    let i = (row * width + x) * 4
                    total += Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])
                    x += 1
                }
                values[row * blocks + block] = UInt8(total / (blockWidth * 10))
            }
        }
        return Signature(rows: height, blocks: blocks, values: values)
    }

    private static func columnSignatures(_ image: CGImage) -> Signature? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let usable = max(1, height - 48)
        let blockHeight = max(8, usable / 96)
        let blocks = max(1, usable / blockHeight)
        var values = [UInt8](repeating: 0, count: width * blocks)
        for column in 0..<width {
            for block in 0..<blocks {
                var total = 0
                for y in (block * blockHeight)..<(block * blockHeight + blockHeight) {
                    let i = (y * width + column) * 4
                    total += Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])
                }
                values[column * blocks + block] = UInt8(total / (blockHeight * 10))
            }
        }
        return Signature(rows: width, blocks: blocks, values: values)
    }
}
