import AppKit
import Combine
import SwiftUI

/// Bangs in the menu bar, for a Mac without a notch: the face and the status, with the island hanging below when open.
@MainActor
final class MenuBarItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let host: NSHostingView<MenuBarLabel>
    private let model: NotchModel
    private let onClick: () -> Void
    private var subscriptions: Set<AnyCancellable> = []

    init(model: NotchModel, store: SessionStore, onClick: @escaping () -> Void) {
        self.model = model
        self.onClick = onClick
        host = PassThroughHostingView(rootView: MenuBarLabel(model: model, store: store))
        super.init()
        guard let button = item.button else { return }
        button.addSubview(host)
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        resize()
        model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.resize() } }.store(in: &subscriptions)
    }

    /// The icon's frame on screen, once the menu bar has laid it out.
    var frame: NSRect? {
        guard let window = item.button?.window, window.frame.width > 0 else { return nil }
        return window.frame
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
        subscriptions.removeAll()
    }

    private func resize() {
        let size = host.fittingSize
        item.length = ceil(size.width)
        if let button = item.button {
            host.frame = NSRect(x: 0, y: (button.bounds.height - size.height) / 2, width: ceil(size.width), height: size.height)
            button.highlight(model.mode == .expanded)
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = item.button {
            let menu = NSMenu()
            menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Bangs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            onClick()
        }
    }

    @objc private func openSettings() { model.openSettings() }
}

/// Clicks go to the status item's button, not the SwiftUI label on it.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Bangs' status icon, with the minutes to the next meeting and the CPU load beside it when those are on.
struct MenuBarLabel: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore

    var body: some View {
        let glyph = model.glyph
        HStack(spacing: 4) {
            StatusGlyph(state: glyph.state, dots: glyph.dots)
            ForEach(model.extras, id: \.self) { extra in
                switch extra {
                case .meeting(let label), .focus(let label): Text(label)
                case .load(let percent): Text("\(percent)%")
                // Bangs' open eyes already say the Mac is kept awake.
                case .awake: EmptyView()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
        .fixedSize()
    }
}
