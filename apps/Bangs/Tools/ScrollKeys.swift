import AppKit

/// The keys of a scrolling screenshot, which run while the page you scroll has the keyboard: return finishes, Esc
/// cancels, and holding the lock key (Space unless you chose another) keeps the scroll to one direction, so a hand that drifts up or down while scrolling
/// sideways (or sideways while scrolling down) does not shift the page off the stitch. Bangs sees and changes these
/// events through an event tap, which needs Accessibility; without it there is none, and the bar's buttons remain.
@MainActor
final class ScrollKeys {
    /// The direction scrolling is kept to while Space is held; nil until it is known (the first scroll decides when the
    /// capture has not moved yet).
    private(set) var locked: Stitcher.Axis?
    private(set) var held = false
    var onFinish: (_ save: Bool) -> Void = { _ in }
    var onChange: () -> Void = {}
    private let axis: () -> Stitcher.Axis?
    let key: HoldKey
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Nil without Accessibility.
    init?(key: HoldKey, axis: @escaping () -> Stitcher.Axis?) {
        self.key = key
        self.axis = axis
        guard AXIsProcessTrusted() else { return nil }
        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
                                              guard let context else { return Unmanaged.passUnretained(event) }
                                              let keys = Unmanaged<ScrollKeys>.fromOpaque(context).takeUnretainedValue()
                                              return MainActor.assumeIsolated { keys.handle(type, event) }
                                          }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            guard held else { return Unmanaged.passUnretained(event) }
            if locked == nil, let first = Self.direction(dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                                                         dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) {
                locked = first
                onChange()
            }
            if let locked { Self.keep(event, to: locked) }
            // A modifier held to lock must not reach the page with the scroll (⌃ scrolling zooms the screen).
            if let modifier = key.modifier { event.flags.remove(CGEventFlags(rawValue: UInt64(modifier))) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            if let modifier = key.modifier {
                hold(event.flags.contains(CGEventFlags(rawValue: UInt64(modifier))))
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            // Shortcuts with ⌘, ⌃ or ⌥ are yours.
            guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return Unmanaged.passUnretained(event) }
            let down = type == .keyDown
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            switch code {
            case key.keyCode:
                // Held, a key repeats: only the first press and the release count. The page never sees it (a browser
                // would page down on Space).
                hold(down)
                return nil
            case 36, 76:
                if down { onFinish(true) }
                return nil
            case 53:
                if down { onFinish(false) }
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func hold(_ down: Bool) {
        guard down != held else { return }
        held = down
        locked = down ? axis() : nil
        onChange()
    }

    /// The direction a scroll mostly goes; nil for none.
    nonisolated static func direction(dx: Double, dy: Double) -> Stitcher.Axis? {
        guard dx != 0 || dy != 0 else { return nil }
        return abs(dx) > abs(dy) ? .horizontal : .vertical
    }

    /// Takes out the part of a scroll across `axis`: kept sideways, nothing moves up or down, and the other way round.
    nonisolated static func keep(_ event: CGEvent, to axis: Stitcher.Axis) {
        let fields: [CGEventField] = axis == .horizontal
            ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]
            : [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]
        for field in fields {
            event.setIntegerValueField(field, value: 0)
            event.setDoubleValueField(field, value: 0)
        }
    }
}
