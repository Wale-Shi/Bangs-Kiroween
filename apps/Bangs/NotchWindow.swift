import AppKit
import Combine
import SwiftUI

/// A transparent, non-activating panel above the menu bar, large enough for the open island.
/// It ignores the mouse except over the island itself, so the menu bar and apps below keep working.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    /// Set for a moment while the keyboard goes back to the app you were in, so AppKit does not hand it straight back here.
    var refusesKeyboard = false
    override var canBecomeKey: Bool { !refusesKeyboard }
    override var canBecomeMain: Bool { false }

    /// Always drawn as if active. The island is often open without the keyboard (an approval, a finished session, after
    /// the keyboard goes back as it closes), and Liquid Glass in an inactive window turns grey and faint. AppKit asks
    /// this private method; it has no public counterpart (NSVisualEffectView's `state` does not reach the glass).
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    /// ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z in the search fields. They are menu shortcuts, and the island takes the keyboard without
    /// making Bangs the active app, so its Edit menu never sees them: they go to the field from here. By key code, so
    /// they work whatever the keyboard layout.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let action = Self.editAction(event), NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    static func editAction(_ event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, flags) {
        case (7, .command): return #selector(NSText.cut(_:))
        case (8, .command): return #selector(NSText.copy(_:))
        case (9, .command): return #selector(NSText.paste(_:))
        case (0, .command): return #selector(NSText.selectAll(_:))
        case (6, .command): return Selector(("undo:"))
        case (6, [.command, .shift]): return Selector(("redo:"))
        default: return nil
        }
    }
}

@MainActor
final class NotchWindowController {
    static let canvas = CGSize(width: 680, height: 560)

    let panel = NotchPanel()
    /// Takes the keyboard from the panel for a moment, to hand it back to the app you were in (see releaseKeyboard).
    private let handback: NSPanel = {
        let panel = NotchPanel()
        panel.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
        panel.becomesKeyOnlyIfNeeded = false
        return panel
    }()
    private let model: NotchModel
    private let store: SessionStore
    /// Bangs' icon in the menu bar, when the island hangs from it rather than from a notch.
    private var menuBarItem: MenuBarItem?
    private var monitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var leaveCollapse: DispatchWorkItem?
    /// The drag pasteboard's change count when the mouse went down, to tell a new file drag from an old one.
    private var dragCount = NSPasteboard(name: .drag).changeCount
    private var fullScreenTimer: Timer?
    /// Checks again while a space or app switch settles (the full screen animation takes most of a second).
    private var fullScreenFollowUp: Timer?
    private var fullScreenFollowUps = 0

    init(model: NotchModel, store: SessionStore) {
        self.model = model
        self.store = store
        let host = NSHostingView(rootView: NotchRoot(model: model, store: store))
        host.sizingOptions = []
        panel.contentView = host
        place()
        panel.orderFrontRegardless()

        let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] _ in MainActor.assumeIsolated { self?.track() } } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self] event in MainActor.assumeIsolated { self?.track() }; return event } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dragCount = NSPasteboard(name: .drag).changeCount
                self?.clickedElsewhere()
            }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.fileDragMoved() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel, self.model.keyDown(event) else { return event }
                return nil
            }
        } as Any)

        model.focusKeyboard = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.panel.makeKey() }
        }
        model.holdsKeyboard = { [weak self] in self?.panel.isKeyWindow ?? false }
        model.releaseKeyboard = { [weak self] in
            // An invisible window takes the keyboard and goes, which hands it back to the app you were in. Ordering the
            // panel itself out and back would do that too, but it cuts short the island's closing animation: it flashes.
            guard let self, self.panel.isKeyWindow else { return }
            self.panel.refusesKeyboard = true
            self.handback.makeKeyAndOrderFront(nil)
            self.handback.orderOut(nil)
            self.panel.refusesKeyboard = false
        }

        // Track size changes too: the island grows under a still pointer.
        model.objectWillChange.sink { [weak self] in
            self?.shape = nil
            DispatchQueue.main.async { self?.track() }
        }.store(in: &subscriptions)

        model.preferences.$placement.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.place() } }.store(in: &subscriptions)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.fullScreenMayChange() } }
        }
        // An app's native full screen is a space of its own, so entering or leaving it is a space switch and is seen at
        // once. Only a window made to cover the screen without one (some games and players) needs this slow look, and
        // it still shows within a few seconds; each look lists every window on screen, so not every two seconds.
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkFullScreen() } }
        fullScreenTimer?.tolerance = 1
    }

    /// Hangs the panel from the notch, or from the menu bar icon on a Mac without a notch (or when the user prefers the menu bar).
    func place() {
        let notch = model.preferences.placement == .auto ? NotchGeometry.notchScreen : nil
        let geometry: NotchGeometry
        if let notch {
            menuBarItem?.remove()
            menuBarItem = nil
            geometry = NotchGeometry(notchScreen: notch)
        } else {
            if menuBarItem == nil {
                menuBarItem = MenuBarItem(model: model, store: store) { [weak self] in self?.toggle() }
            }
            let item = menuBarItem?.frame
            geometry = NotchGeometry(menuBarItem: item, screen: NotchGeometry.screen(containing: item))
        }
        if geometry.placement != model.geometry.placement, model.mode.isOpen { model.go(.collapsed) }
        model.update(geometry: geometry)
        // The notch is always dark; the menu bar panel follows the system.
        // Only when they change: this runs each time the island opens, and setting them again redraws it all.
        let appearance = geometry.hasNotch ? NSAppearance(named: .darkAqua) : nil
        if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
        let frame = NSRect(x: geometry.anchor.x - Self.canvas.width / 2, y: geometry.anchor.y - Self.canvas.height,
                           width: Self.canvas.width, height: Self.canvas.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The menu bar icon or the shortcut: open the list, or close whatever is open.
    func toggle() {
        // The menu bar icon may have moved since it was last placed.
        if !model.mode.isOpen { place() }
        model.toggle()
    }

    /// The session search shortcut: the sessions tab, its search field taking the keyboard.
    func searchSessions() {
        if !model.mode.isOpen { place() }
        model.searchSessions()
    }

    /// The file search shortcut: the files tab, its search field taking the keyboard; again, it closes.
    func searchFiles() {
        if model.mode == .expanded && model.tool == .files { model.collapse(); return }
        if !model.mode.isOpen { place() }
        model.searchFiles()
    }

    /// A shortcut for one tool: opens on it, or closes it when it is already showing.
    func open(_ tool: Tool) {
        if model.mode == .expanded && model.tool == tool { model.collapse(); return }
        if !model.mode.isOpen { place() }
        model.open(tool)
    }

    /// Where the island is and where its face looks from, worked out once for many pointer moves: the model changing
    /// clears it, and it is never older than half a second (a meeting's countdown narrows the notch as it runs).
    private var shape: (rect: CGRect, face: CGPoint?, at: Date)?

    private func track() {
        let mouse = NSEvent.mouseLocation
        if shape == nil || Date().timeIntervalSince(shape!.at) > 0.5 {
            // The face only shows beside a notch with no agent about.
            let face = model.geometry.hasNotch && model.leadingHarness == nil ? model.faceCentre : nil
            shape = (model.invisible ? .null : model.screenRect.insetBy(dx: -4, dy: -4), face, Date())
        }
        if let face = shape?.face { model.pointer.moved(to: mouse, face: face) }
        let inside = shape?.rect.contains(mouse) ?? false
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside != model.hovered {
            model.hovered = inside
            if inside {
                leaveCollapse?.cancel()
            } else {
                model.hoverEnded()
                // An open list closes shortly after the pointer leaves it.
                if model.mode == .expanded { scheduleLeave() }
            }
        }
    }

    private func scheduleLeave() {
        leaveCollapse?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.hovered, self.model.mode == .expanded else { return }
            // Searching from the keyboard: a pointer passing by must not close it under your typing.
            // Esc, a pick or a click elsewhere still does.
            if self.panel.isKeyWindow && [.clipboard, .sessions, .files].contains(self.model.tool) { return }
            self.model.collapse()
        }
        leaveCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Dragging files toward the notch opens the shelf, so they can be dropped on it.
    private func fileDragMoved() {
        let pasteboard = NSPasteboard(name: .drag)
        guard model.preferences.shelfCatchesDrags, pasteboard.changeCount != dragCount, pasteboard.types?.contains(.fileURL) == true else { return }
        let mouse = NSEvent.mouseLocation
        let anchor = model.geometry.anchor
        let near = abs(mouse.x - anchor.x) < 220 && anchor.y - mouse.y < 90 && mouse.y <= anchor.y + 1
        guard near, model.mode != .expanded || model.tool != .shelf else { return }
        leaveCollapse?.cancel()
        place()
        model.open(.shelf)
        track()
    }

    private func clickedElsewhere() {
        // The open list, and read text or a table (already copied), go when you click elsewhere.
        let recognized = switch model.mode { case .recognized, .table: true; default: false }
        guard model.mode == .expanded || recognized, !model.screenRect.contains(NSEvent.mouseLocation) else { return }
        model.collapse()
    }

    /// A full-screen window from the frontmost app covers the notch screen.
    private func fullScreenMayChange() {
        checkFullScreen()
        fullScreenFollowUps = 3
        guard fullScreenFollowUp == nil else { return }
        fullScreenFollowUp = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkFullScreen()
                self.fullScreenFollowUps -= 1
                if self.fullScreenFollowUps <= 0 {
                    self.fullScreenFollowUp?.invalidate()
                    self.fullScreenFollowUp = nil
                }
            }
        }
        fullScreenFollowUp?.tolerance = 0.2
    }

    private func checkFullScreen() {
        let screen = model.geometry.screen.frame
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let covering = windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid, (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return abs((bounds["Width"] ?? 0) - screen.width) < 1 && abs((bounds["Height"] ?? 0) - screen.height) < 1
                && abs((bounds["X"] ?? -1) - screen.minX) < 1
        }
        if covering != model.fullScreen { model.fullScreen = covering }
    }
}
