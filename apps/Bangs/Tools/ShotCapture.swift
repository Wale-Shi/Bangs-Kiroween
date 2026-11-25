import AppKit
import ScreenCaptureKit

/// Region and window screenshots taken by Bangs itself through ScreenCaptureKit, under Bangs' own Screen Recording
/// permission. macOS' screencapture tool, run from Bangs, does not always get that permission: it then cannot see other
/// apps' windows and captures a blank screen.
enum Capture {
    /// Bangs' ordinary windows (the settings), which belong in a screenshot like any app's.
    @MainActor static func ownWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    @MainActor static func keptWindows() -> Set<CGWindowID> { Set(ownWindows().map { CGWindowID($0.windowNumber) }) }

    /// Bangs' floating windows (the island, the overlays) are never in a screenshot; its settings window is, when in view.
    static func displayFilter(for screen: NSScreen, keeping kept: Set<CGWindowID>) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == number }) ?? content.displays.first else { throw Failure.noDisplay }
        return SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == getpid() },
                               exceptingWindows: content.windows.filter { kept.contains($0.windowID) })
    }

    static func save(_ image: CGImage, to url: URL) -> Bool {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// What to tell you when a capture fails.
    static func message(for error: Error) -> String {
        CGPreflightScreenCaptureAccess() ? "截图失败：\(error.localizedDescription)" : "需要在「系统设置 → 隐私与安全性 → 屏幕录制」里允许 Bangs"
    }

    enum Failure: Error { case noDisplay, noWindow }
}

/// A capture takes the keyboard (for Esc) by making Bangs the active app, which raises its settings window over the app
/// you were in. Each of Bangs' windows goes back behind the window that covered it, so it stays where it was: hidden if
/// it was, and in the screenshot if it was in view.
@MainActor
final class CaptureFocus {
    private var previous: NSRunningApplication?
    /// Bangs' windows and the other app's window that was just in front of each.
    private var places: [(window: NSWindow, below: Int)] = []
    private var observer: NSObjectProtocol?

    func take() {
        previous = NSWorkspace.shared.frontmostApplication
        guard previous != .current else { return NSApp.activate() }
        // Front to back.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        places = Capture.ownWindows().compactMap { window in
            guard let index = list.firstIndex(where: { ($0[kCGWindowNumber] as? Int) == window.windowNumber }),
                  let cover = list[..<index].last(where: { ($0[kCGWindowLayer] as? Int) == 0 && ($0[kCGWindowOwnerPID] as? pid_t) != getpid() }),
                  let number = cover[kCGWindowNumber] as? Int else { return nil }
            return (window, number)
        }
        NSApp.activate()
        guard !places.isEmpty else { return }
        // Activation lands a moment later; the overlay covers the screen meanwhile, so the shuffle never shows.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.putBack() }
        }
        for delay in [0.1, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.putBack() } }
    }

    private func putBack() {
        for place in places where place.window.isVisible { place.window.order(.below, relativeTo: place.below) }
    }

    /// The app you were in gets the keyboard back, while the capture goes on (a scrolling capture's page).
    func returnKeyboard() {
        if previous != .current { previous?.activate() }
    }

    /// The app you were in comes back in front. Once is enough.
    func restore() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        places = []
        returnKeyboard()
        previous = nil
    }
}

/// A capture under way, which a second press of a screenshot shortcut cancels: the way out should Esc not reach Bangs.
@MainActor
protocol ScreenCapture: AnyObject {
    func cancel()
}

/// Drag out a region, and it is captured.
@MainActor
final class RegionCapture: ScreenCapture {
    var onFinish: (URL?, String?) -> Void = { _, _ in }
    private let output: URL
    /// One per screen: the box is dragged on whichever you like.
    private var overlays: [SelectionOverlay] = []
    private var keyMonitor: Any?
    private let focus = CaptureFocus()
    private let hint: String
    /// Annotate the region in place before it is copied.
    private let annotates: Bool
    private var session: AnnotationSession?
    private var cursor = false
    private var finished = false

    init(output: URL, hint: String = "拖出要截取的区域 · esc 取消", annotates: Bool = false) {
        self.output = output
        self.hint = hint
        self.annotates = annotates
    }

    func start() {
        overlays = NSScreen.screens.map { screen in
            let overlay = SelectionOverlay(screen: screen, hint: hint)
            overlay.onSelect = { [weak self] rect in self?.capture(rect, on: screen) }
            return overlay
        }
        focus.take()
        for overlay in overlays { overlay.orderFrontRegardless() }
        (overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first)?.makeKey()
        // A crosshair on every screen, not only over the one with the keyboard.
        NSCursor.crosshair.push()
        cursor = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(nil, nil)
            return nil
        }
    }

    private func capture(_ rect: NSRect, on screen: NSScreen) {
        // To annotate, the overlay stays up while the region is taken (Bangs' own windows are never in a screenshot), so
        // the region does not flicker before the editor takes its place.
        if !annotates { tearDown() }
        Log.write("screenshot: region \(rect) on \(screen.localizedName)")
        let kept = Capture.keptWindows()
        Task { [weak self] in
            do {
                let filter = try await Capture.displayFilter(for: screen, keeping: kept)
                let config = SCStreamConfiguration()
                let scale = screen.backingScaleFactor
                config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                config.showsCursor = false
                // The overlay has just gone; let the screen catch up before the shot.
                if !(self?.annotates ?? false) { try await Task.sleep(nanoseconds: 80_000_000) }
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let self else { return }
                if self.annotates { return self.annotate(image, rect: rect, on: screen) }
                Capture.save(image, to: self.output) ? self.finish(self.output, nil) : self.finish(nil, "无法保存截图")
            } catch {
                Log.write("screenshot: region failed: \(error)")
                self?.finish(nil, Capture.message(for: error))
            }
        }
    }

    /// The region, frozen where it was, with the annotation toolbar; done copies it, pinned keeps it over the screen.
    private func annotate(_ image: CGImage, rect: NSRect, on screen: NSScreen) {
        guard !finished else { return }
        let session = AnnotationSession(image: image, rect: rect, screen: screen)
        session.onFinish = { [weak self] result in
            guard let self else { return }
            switch result {
            case .done(let image):
                Capture.save(image, to: self.output) ? self.finish(self.output, nil) : self.finish(nil, "无法保存截图")
            case .pin(let image, let rect):
                PinnedImage.pin(image, at: rect)
                self.finish(nil, nil)
            case .cancel:
                self.finish(nil, nil)
            }
        }
        self.session = session
        session.show()
        // The editor has Esc now (it first lets go of a mark or the tool in hand), and its own cursors.
        tearDown()
    }

    func cancel() { finish(nil, nil) }

    private func finish(_ url: URL?, _ error: String?) {
        guard !finished else { return }
        finished = true
        tearDown()
        session?.close()
        session = nil
        focus.restore()
        onFinish(url, error)
    }

    private func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = []
        if cursor { NSCursor.pop(); cursor = false }
    }
}

/// Point at a window to highlight it, click to capture just that window at its own size.
@MainActor
final class WindowCapture: ScreenCapture {
    struct Candidate {
        let window: SCWindow
        /// In screen coordinates (origin bottom left).
        let frame: NSRect
        let app: String
    }

    var onFinish: (URL?, String?) -> Void = { _, _ in }
    private let output: URL
    private var overlays: [WindowOverlay] = []
    private var candidates: [Candidate] = []
    private var hovered: Candidate?
    private var monitors: [Any] = []
    private let focus = CaptureFocus()
    private var finished = false

    init(output: URL) { self.output = output }

    func cancel() { finish(nil, nil) }

    func start() {
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let self else { return }
                self.candidates = Self.candidates(from: content, keeping: Capture.keptWindows())
                Log.write("screenshot: window picker with \(self.candidates.count) windows")
                guard !self.candidates.isEmpty else { throw Capture.Failure.noWindow }
                self.showOverlays()
            } catch {
                Log.write("screenshot: window list failed: \(error)")
                self?.finish(nil, Capture.message(for: error))
            }
        }
    }

    /// Ordinary app windows, front to back. The window server's list gives the stacking order; ScreenCaptureKit's the
    /// windows it can capture.
    /// The windows under the pointer that can be picked: other apps', and Bangs' own `kept` ones (its settings).
    static func candidates(from content: SCShareableContent, keeping kept: Set<CGWindowID> = []) -> [Candidate] {
        let capturable = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowLayer] as? Int) == 0,
                  (info[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber] as? CGWindowID, let window = capturable[number],
                  (info[kCGWindowOwnerPID] as? pid_t) != getpid() || kept.contains(number),
                  let bounds = info[kCGWindowBounds] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.height >= 40 else { return nil }
            // The window server measures from the top of the main screen.
            let frame = NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            return Candidate(window: window, frame: frame, app: info[kCGWindowOwnerName] as? String ?? "")
        }
    }

    private func showOverlays() {
        overlays = NSScreen.screens.map { screen in
            let overlay = WindowOverlay(screen: screen)
            overlay.onClick = { [weak self] in self?.pick() }
            overlay.orderFrontRegardless()
            return overlay
        }
        focus.take()
        overlays.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(nil, nil)
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.track()
            return event
        } as Any)
        track()
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        let next = candidates.first { $0.frame.contains(mouse) }
        guard next?.window.windowID != hovered?.window.windowID else { return }
        hovered = next
        for overlay in overlays { overlay.highlight(next) }
    }

    private func pick() {
        track()
        guard let candidate = hovered else { return }
        tearDown()
        Log.write("screenshot: window \(candidate.window.windowID) of \(candidate.app), \(candidate.frame)")
        Task { [weak self] in
            do {
                let filter = SCContentFilter(desktopIndependentWindow: candidate.window)
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let self else { return }
                Capture.save(image, to: self.output) ? self.finish(self.output, nil) : self.finish(nil, "无法保存截图")
            } catch {
                Log.write("screenshot: window failed: \(error)")
                self?.finish(nil, Capture.message(for: error))
            }
        }
    }

    private func finish(_ url: URL?, _ error: String?) {
        guard !finished else { return }
        finished = true
        tearDown()
        focus.restore()
        onFinish(url, error)
    }

    private func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = []
    }
}

/// A clear sheet over one screen that tints the window under the pointer.
final class WindowOverlay: NSWindow {
    var onClick: () -> Void = {}
    private let canvas = WindowHighlightView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
        canvas.onClick = { [weak self] in self?.onClick() }
        contentView = canvas
    }

    override var canBecomeKey: Bool { true }

    func highlight(_ candidate: WindowCapture.Candidate?) {
        canvas.highlight = candidate.map { (rect: $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), app: $0.app) }
        canvas.needsDisplay = true
    }
}

final class WindowHighlightView: NSView {
    var onClick: () -> Void = {}
    var highlight: (rect: NSRect, app: String)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        guard let highlight else {
            let hint = "点选要截取的窗口 · esc 取消" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            let box = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.midY - size.height / 2 - 8, width: size.width + 28, height: size.height + 16)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            hint.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 8), withAttributes: attributes)
            return
        }
        let accent = NSColor(red: 0.36, green: 0.55, blue: 1, alpha: 1)
        let shape = NSBezierPath(roundedRect: highlight.rect, xRadius: 10, yRadius: 10)
        accent.withAlphaComponent(0.22).setFill()
        shape.fill()
        shape.lineWidth = 3
        accent.setStroke()
        shape.stroke()
        guard !highlight.app.isEmpty else { return }
        let label = highlight.app as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        let box = NSRect(x: highlight.rect.midX - size.width / 2 - 10, y: highlight.rect.midY - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
        accent.setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        label.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attributes)
    }
}
