import AppKit
import BangsCore
import SwiftUI

/// Hands something from the toolbox (a screenshot, text read off the screen, a clipboard item, a file on the shelf) to
/// an agent: it goes on the pasteboard and, with Accessibility, is pasted into the session's terminal. Return is never
/// pressed, so you add to it and send it yourself. Without Accessibility the terminal comes forward with it on the
/// pasteboard, for ⌘V.
enum Handoff {
    enum Payload: Equatable {
        case text(String)
        case files([URL])
    }

    enum Result { case pasted, copied, noWindow }

    /// What the terminal gets: the text, or the paths escaped as a terminal writes files dropped on it.
    static func text(for payload: Payload) -> String {
        switch payload {
        case .text(let text): text
        case .files(let urls): urls.map { escape($0.path) }.joined(separator: " ") + " "
        }
    }

    static func escape(_ path: String) -> String {
        let special = Set(" \t'\"()[]{}&;|<>*?$`!#~\\")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// The terminal app takes a moment to come forward; the paste waits for it.
    static let settle: TimeInterval = 0.35

    @MainActor @discardableResult
    static func send(_ payload: Payload, to session: Session, clipboard: ClipboardHistory) -> Result {
        clipboard.copyOnly(text(for: payload))
        guard Terminal.focus(pid: session.pid) else { return .noWindow }
        // Asked for once, in the settings; not here, where a prompt would land on top of the terminal.
        guard AXIsProcessTrusted() else { return .copied }
        let pid = session.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            if Terminal.isFrontmost(for: pid) { _ = ClipboardHistory.pasteIntoFrontApp() }
        }
        return .pasted
    }

    /// The sessions worth sending to: those still running a CLI, the latest first.
    @MainActor static func targets(in store: SessionStore) -> [Session] {
        store.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func label(for session: Session) -> String {
        let state = switch session.status {
        case .working: "运行中"
        case .approval: "待审批"
        case .finished: "完成"
        case .idle: "空闲"
        }
        return "\(session.project) · \(session.harness.displayName) · \(state)"
    }
}

/// How views deep in the toolbox send to an agent: the sessions to offer, and the send itself.
struct HandoffAction {
    let sessions: () -> [Session]
    let send: (Handoff.Payload, Session) -> Void
}

extension EnvironmentValues {
    @Entry var handoff: HandoffAction?
}

/// "发送给 Agent ▸" in a context menu, one item per session.
struct SendToAgentMenu: View {
    let payload: () -> Handoff.Payload
    @Environment(\.handoff) private var handoff

    var body: some View {
        if let handoff {
            let sessions = handoff.sessions()
            if !sessions.isEmpty {
                Menu("发送给 Agent") {
                    ForEach(sessions) { session in
                        Button(Handoff.label(for: session)) { handoff.send(payload(), session) }
                    }
                }
            }
        }
    }
}

/// A pill that sends straight to the only session, or asks which with a menu at the pointer.
struct SendToAgentButton: View {
    let payload: () -> Handoff.Payload
    @Environment(\.handoff) private var handoff

    var body: some View {
        if let handoff, !handoff.sessions().isEmpty {
            PillButton(title: "发给 Agent", style: .plain) {
                let sessions = handoff.sessions()
                if sessions.count == 1 {
                    handoff.send(payload(), sessions[0])
                } else {
                    SessionMenu(sessions: sessions) { handoff.send(payload(), $0) }.popUp()
                }
            }
            .help("粘贴到 Agent 所在的终端，不会替你按回车")
        }
    }
}

/// A paper plane on a file's tile: the same, where a pill has no room.
struct SendToAgentIcon: View {
    let payload: () -> Handoff.Payload
    @Environment(\.handoff) private var handoff

    var body: some View {
        if let handoff, !handoff.sessions().isEmpty {
            Button {
                let sessions = handoff.sessions()
                if sessions.count == 1 { handoff.send(payload(), sessions[0]) } else { SessionMenu(sessions: sessions) { handoff.send(payload(), $0) }.popUp() }
            } label: {
                Image(systemName: "paperplane.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("发给 Agent：粘贴到它所在的终端")
        }
    }
}

/// An AppKit menu at the pointer: SwiftUI's own would not look like the pills beside it.
@MainActor
final class SessionMenu: NSObject {
    private let sessions: [Session]
    private let pick: (Session) -> Void

    init(sessions: [Session], pick: @escaping (Session) -> Void) {
        self.sessions = sessions
        self.pick = pick
    }

    func popUp() {
        let menu = NSMenu()
        menu.addItem(withTitle: "发送给…", action: nil, keyEquivalent: "").isEnabled = false
        for (index, session) in sessions.enumerated() {
            let item = menu.addItem(withTitle: Handoff.label(for: session), action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        // The menu runs its own loop: this object lives until it closes.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func chosen(_ item: NSMenuItem) { pick(sessions[item.tag]) }
}
