import BangsCore
import SwiftUI

struct Spinner: View {
    var color: NSColor
    var size: CGFloat = 12

    /// Turning, as layers (SwiftUI's own spin redrew every frame: about 5% of a core for each running session listed).
    var body: some View {
        if LayerMotion.usesLayers {
            SpinnerLayers(color: color).frame(width: size, height: size)
        } else {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color(nsColor: color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .background(Circle().stroke(Color(nsColor: color).opacity(0.25), lineWidth: 2))
                .frame(width: size, height: size)
        }
    }
}

/// A CLI's official logo (see Logos/README.md), white-on-dark for the notch, dark-on-light for the settings window.
struct HarnessIcon: View {
    let harness: Harness?
    var size: CGFloat = 18
    /// Nil follows the view's light or dark appearance.
    var onDark: Bool?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let harness, let logo = Logos.image(for: harness, onDark: onDark ?? (colorScheme == .dark)) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                if harness == .qoderCN {
                    Text("CN")
                        .font(.system(size: max(5.5, size * 0.3), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, size * 0.06)
                        .background(Capsule().fill(Color(red: 0.86, green: 0.18, blue: 0.18)))
                        .offset(x: size * 0.2, y: size * 0.12)
                }
            } else {
                // No session yet: the app's own face.
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).scaleEffect(1.22).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: harness)
    }
}

// MARK: Open content

struct SessionList: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore
    @ObservedObject var search: SessionSearch
    static let limit = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let approval = store.approvals.first {
                ApprovalView(approval: approval, more: store.approvals.count - 1, store: store)
                    .padding(.bottom, 8)
            }
            SessionSearchField(search: search).padding(.bottom, 4)
            if search.active {
                SessionSearchResults(search: search, history: model.toolbox.history, model: model, store: store)
            } else {
                list
            }
        }
    }

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有运行中的会话").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    Text("在终端里运行 Claude Code、Codex、Gemini CLI 等 Agent，会话会出现在这里。还没装 hooks 的话，先在设置里安装。")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
            if store.unseen.count > 1 {
                HStack {
                    Text("\(store.unseen.count) 个会话完成了还没看").font(.system(size: 11)).foregroundStyle(Palette.dim)
                    Spacer()
                    RowChip(title: "全部已读") { store.markAllSeen() }
                }
                .padding(.vertical, 2)
            }
            ForEach(ordered.prefix(Self.limit)) { session in
                SessionRow(session: session, dismiss: { store.dismiss(session) }, markSeen: { store.markSeen(session) },
                           showsUsage: model.preferences.showsUsage,
                           showChanges: { model.go(.changes(session.id)) }, clearRules: { store.clearRules(of: session) }) {
                    store.markSeen(session)
                    guard Terminal.focus(pid: session.pid) else { return false }
                    model.go(.collapsed)
                    return true
                }
            }
            if ordered.count > Self.limit {
                Text("还有 \(ordered.count - Self.limit) 个会话").font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.top, 4)
            }
            if model.preferences.showsUsage { LimitsStrip(meter: store.meter) }
        }
    }

    private var ordered: [Session] {
        let rank: (Session) -> Int = { session in
            switch session.status {
            case .approval: 0
            case .working: 1
            case .finished: session.unseen ? 2 : 3
            case .idle: 4
            }
        }
        return store.sessions.sorted { (rank($0), $1.updatedAt) < (rank($1), $0.updatedAt) }
    }
}

struct SessionRow: View {
    let session: Session
    var dismiss: () -> Void = {}
    /// Acknowledges a finished session without going to it.
    var markSeen: () -> Void = {}
    /// Shows how full the session's context is.
    var showsUsage = false
    /// Opens what its last turn changed.
    var showChanges: () -> Void = {}
    /// Takes back what was allowed for the rest of the session.
    var clearRules: () -> Void = {}
    /// Jumps to the session's window; false when there is none to find.
    let action: () -> Bool
    @State private var hovering = false
    /// The resume command was just copied: the button says so for a moment.
    @State private var copied = false
    @State private var copiedLabel = "已复制"

    var body: some View {
        HStack(spacing: 6) {
            main
            if let changes = session.changes { ChangesChip(changes: changes, action: showChanges) }
            if session.status == .finished {
                if session.unseen { RowChip(title: "已读", action: markSeen) }
                RowChip(title: "打开会话", tint: session.unseen ? Palette.ok : nil, action: jump)
            }
            if let command = session.resumeCommand, hovering || copied {
                Button { copy(command) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "terminal").font(.system(size: 10.5, weight: .semibold))
                        if copied { Text(copiedLabel).font(.system(size: 11, weight: .medium)) }
                    }
                    .foregroundStyle(copied ? Palette.ok : Palette.muted)
                    .frame(minWidth: 24, minHeight: 22)
                    .padding(.horizontal, copied ? 7 : 0)
                    .background(Capsule().fill(Palette.wash(copied ? 0.1 : 0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("复制恢复命令：\(command)")
                .transition(.opacity)
            }
        }
        .padding(.trailing, hovering || copied || session.changes != nil || session.status == .finished ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Palette.row : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("跳到终端") { jump() }
            if session.unseen { Button("标为已读", action: markSeen) }
            if let changes = session.changes { Button("查看上一轮的改动（\(changes.summary)）", action: showChanges) }
            if !session.rules.isEmpty {
                Section("本会话不再询问") {
                    ForEach(session.rules, id: \.self) { rule in Text(rule.title) }
                    Button("恢复询问", action: clearRules)
                }
            }
            if let command = session.resumeCommand {
                Button("复制恢复命令") { copy(command) }
                Button("复制会话 ID") { copy(session.sessionId) }
            }
            Divider()
            Button("从列表移除", action: dismiss)
        }
        .padding(.horizontal, -8)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// To the session's window; with none to find (closed, or run by a background service), its resume command is
    /// copied instead, and the row says so.
    private func jump() {
        guard !action(), let command = session.resumeCommand else { return }
        copy(command, label: "找不到窗口，已复制恢复命令")
    }

    private func copy(_ text: String, label: String = "已复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLabel = label
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(label == "已复制" ? 1.5 : 3))
            copied = false
        }
    }

    private var main: some View {
        Button(action: jump) {
            HStack(spacing: 11) {
                HarnessIcon(harness: session.harness, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.project).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                        if !session.prompt.isEmpty {
                            Text(Self.firstLine(session.prompt)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                    }
                    .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11, design: session.activity.isEmpty ? .default : .monospaced))
                            .foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if showsUsage, let context = session.context { ContextBadge(context: context) }
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("跳到终端；右键可复制恢复命令")
    }

    private var subtitle: String {
        switch session.status {
        case .working, .approval: Self.firstLine(session.activity)
        case .finished, .idle: Self.firstLine(session.lastMessage)
        }
    }

    /// Only one line shows, and laying out a whole multi-KB reply for it makes the list slow to appear.
    static func firstLine(_ text: String) -> String {
        let head = text.prefix(400)
        return String(head.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? head)
    }

    @ViewBuilder private var trailing: some View {
        switch session.status {
        case .approval:
            Text("待审批").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warn)
        case .working:
            HStack(spacing: 6) {
                if let start = session.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: start, to: context.date)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.dim)
                    }
                }
                Spinner(color: Palette.Shade.accent, size: 11)
            }
        case .finished:
            // Its buttons sit outside the row's own button (see body), so they take their own clicks.
            EmptyView()
        case .idle:
            Text("空闲").font(.system(size: 11)).foregroundStyle(Palette.dim)
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A small button beside a session row, the size of its changes chip.
struct RowChip: View {
    let title: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? Palette.muted)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(Capsule().fill(Palette.wash(hovering ? 0.14 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
