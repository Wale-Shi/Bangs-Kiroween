import BangsCore
import SwiftUI

/// Under the session list: how much of each CLI's plan limits is used, one line per CLI that reported any.
struct LimitsStrip: View {
    @ObservedObject var meter: UsageMeter

    var body: some View {
        let shown = meter.shown()
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown, id: \.harness) { row in
                    HStack(spacing: 8) {
                        HarnessIcon(harness: row.harness, size: 12)
                        Text(row.harness.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                            .lineLimit(1).frame(width: 82, alignment: .leading)
                        ForEach(Array(row.windows.enumerated()), id: \.offset) { _, window in LimitGauge(window: window) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Palette.wash(0.08)).frame(height: 0.5).padding(.horizontal, 8) }
            .padding(.top, 6)
        }
    }
}

struct LimitGauge: View {
    let window: Limits.Window
    static let width: CGFloat = 46

    var body: some View {
        let percent = Int((window.used * 100).rounded())
        HStack(spacing: 5) {
            Text(window.name).font(.system(size: 10.5)).foregroundStyle(Palette.dim)
            Capsule().fill(Palette.wash(0.12)).frame(width: Self.width, height: 4)
                .overlay(alignment: .leading) { Capsule().fill(Self.color(window.used)).frame(width: max(window.used > 0 ? 4 : 0, Self.width * window.used)) }
            Text("\(percent)%").font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(window.used >= 0.75 ? Self.color(window.used) : Palette.muted)
            // Running low: when it comes back matters more than how much is gone.
            if window.used >= 0.8, let reset = window.resetsAt {
                Text("\(Self.time(reset)) 重置").font(.system(size: 10.5)).foregroundStyle(Palette.dim)
            }
        }
        .fixedSize()
        .help(window.resetsAt.map { "\(window.name)额度已用 \(percent)%，\(Self.time($0)) 重置" } ?? "\(window.name)额度已用 \(percent)%")
    }

    static func color(_ used: Double) -> Color { used >= 0.9 ? Palette.danger : used >= 0.75 ? Palette.warn : Palette.ink.opacity(0.7) }

    /// "14:10" today, "明天 9:00", else "周一 14:10".
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if calendar.isDateInTomorrow(date) { return "明天 \(clock)" }
        let weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][calendar.component(.weekday, from: date) - 1]
        return "\(weekday) \(clock)"
    }
}

/// How full a session's context is: a small ring with the share, or the tokens where the window's size is not known.
struct ContextBadge: View {
    let context: ContextFill

    var body: some View {
        HStack(spacing: 4) {
            if let fraction = context.fraction {
                Circle().stroke(Palette.wash(0.16), lineWidth: 2)
                    .overlay(Circle().trim(from: 0, to: fraction).stroke(color(fraction), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)))
                    .frame(width: 10, height: 10)
                Text("\(Int((fraction * 100).rounded()))%").foregroundStyle(fraction >= 0.8 ? color(fraction) : Palette.dim)
            } else {
                Text(Usage.tokens(context.tokens)).foregroundStyle(Palette.dim)
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .help(help)
    }

    private var help: String {
        if let window = context.window, let fraction = context.fraction {
            return "上下文已用 \(Int((fraction * 100).rounded()))%（\(Usage.tokens(context.tokens)) / \(Usage.tokens(window))）"
        }
        return "上下文 \(Usage.tokens(context.tokens)) tokens"
    }

    private func color(_ fraction: Double) -> Color { fraction >= 0.9 ? Palette.danger : fraction >= 0.8 ? Palette.warn : Palette.muted }
}

/// "+142 −37" on a session whose last turn changed files; a click shows the changes.
struct ChangesChip: View {
    let changes: TurnChanges
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if changes.files.isEmpty {
                    Text("\(changes.commits) 次提交").foregroundStyle(Palette.muted)
                } else {
                    Text("+\(changes.added)").foregroundStyle(Palette.ok)
                    Text("−\(changes.removed)").foregroundStyle(Palette.danger)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7)
            .frame(minHeight: 20)
            .background(Capsule().fill(Palette.wash(hovering ? 0.14 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("上一轮改了：\(changes.summary)。点开看改动")
    }
}

/// What a session's last turn changed: its files, each opening to its diff.
struct TurnChangesView: View {
    let sessionId: String
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore
    @State private var open: String?
    @State private var diffs: [String: FileChange] = [:]
    static let files = 10

    init(sessionId: String, model: NotchModel, store: SessionStore, open: String? = nil, diffs: [String: FileChange] = [:]) {
        self.sessionId = sessionId
        self.model = model
        self.store = store
        _open = State(initialValue: open)
        _diffs = State(initialValue: diffs)
    }

    var body: some View {
        let session = store.sessions.first { $0.id == sessionId }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(session?.harness.displayName ?? "Agent") 上一轮的改动").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(session?.project ?? "").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                Spacer()
                if let changes = session?.changes { Text(changes.summary).font(.system(size: 11)).foregroundStyle(Palette.dim) }
            }
            .lineLimit(1)
            if let changes = session?.changes {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes.files.prefix(Self.files), id: \.path) { file in
                        row(file, in: changes)
                    }
                    if changes.files.count > Self.files {
                        Text("还有 \(changes.files.count - Self.files) 个文件，在终端里看全部").font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.leading, 4)
                    }
                    if changes.files.isEmpty {
                        Text("这一轮只提交了改动，工作区没有留下新的修改。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
                .padding(.top, 10)
                HStack(spacing: 6) {
                    Spacer()
                    PillButton(title: "在终端里看 git diff", style: .plain) {
                        Terminal.run("cd \(Self.quote(changes.folder)) && git diff \(changes.base)")
                        model.go(.collapsed)
                    }
                    PillButton(title: "完成", style: .primary) { model.open(.sessions) }
                }
                .padding(.top, 12)
            } else {
                Text("这一轮的改动已经不在了：会话有了新的一轮，或已经结束。").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 8)
                HStack { Spacer(); PillButton(title: "完成", style: .primary) { model.open(.sessions) } }.padding(.top, 12)
            }
        }
    }

    @ViewBuilder private func row(_ file: TurnChanges.File, in changes: TurnChanges) -> some View {
        let opened = open == file.path
        VStack(alignment: .leading, spacing: 4) {
            Button {
                open = opened ? nil : file.path
                if !opened, diffs[file.path] == nil { load(file, in: changes) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: opened ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.dim).frame(width: 10)
                    Text(file.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.head)
                    if file.untracked { Text("新文件").font(.system(size: 10.5)).foregroundStyle(Palette.muted).fixedSize() }
                    Spacer(minLength: 6)
                    if let added = file.added, let removed = file.removed {
                        HStack(spacing: 4) {
                            Text("+\(added)").foregroundStyle(Palette.ok)
                            Text("−\(removed)").foregroundStyle(Palette.danger)
                        }
                        .font(.system(size: 10.5, design: .monospaced)).fixedSize()
                    } else {
                        Text("二进制").font(.system(size: 10.5)).foregroundStyle(Palette.dim).fixedSize()
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if opened {
                if let diff = diffs[file.path] {
                    FileBlock(change: diff, limit: 40)
                } else {
                    ProgressView().controlSize(.small).padding(.leading, 24)
                }
            }
        }
    }

    /// git runs off the main thread; the diff shows when it is ready.
    private func load(_ file: TurnChanges.File, in changes: TurnChanges) {
        Task {
            let diff = await Task.detached(priority: .userInitiated) { Git.diff(of: file, in: changes) }.value
            diffs[file.path] = diff ?? FileChange(path: file.path, kind: .edit, lines: [], added: file.added, removed: file.removed)
        }
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}
