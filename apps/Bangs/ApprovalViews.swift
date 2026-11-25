import BangsCore
import SwiftUI

struct ApprovalView: View {
    let approval: Approval
    let more: Int
    let store: SessionStore
    /// The allow and deny shortcuts as shown on their buttons; nil when turned off.
    var allowKey: String?
    var denyKey: String?
    /// Offer "本会话都允许" where the request is one a rule can cover (Settings › Agent).
    var allowsForSession = false

    var body: some View {
        if approval.answerable, !approval.questions.isEmpty {
            QuestionView(approval: approval, more: more, store: store).id(approval.id)
        } else {
            request
        }
    }

    private var danger: Bool { approval.risk?.level == .danger }

    private var request: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(approval.answerable ? "\(approval.harness.displayName) 想\(verb)" : "\(approval.harness.displayName) 在终端等你确认")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(approval.project).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                Spacer()
                if more > 0 { Text("还有 \(more) 个").font(.system(size: 11)).foregroundStyle(Palette.warn) }
            }
            .lineLimit(1)
            if let risk = approval.risk { RiskLine(risk: risk).padding(.top, 9) }
            // The diff names the file itself; until it arrives (a moment after the card), the summary does.
            if !approval.changes.isEmpty {
                ChangesView(changes: approval.changes).id(approval.id).padding(.top, 9)
            } else if !approval.summary.isEmpty { HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isShell { Text("$").foregroundStyle(danger ? Palette.danger : Palette.warn) }
                Text(approval.summary)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.top, 8) }
            HStack(spacing: 6) {
                Spacer()
                if approval.answerable {
                    PillButton(title: "拒绝", style: .plain, hint: denyKey) { store.answer(approval, with: .deny) }
                    PillButton(title: "在终端处理", style: .plain) {
                        store.answer(approval, with: .terminal)
                        // The CLI asks there now: take you to it.
                        Terminal.focus(pid: approval.pid)
                    }
                    // Something flagged as dangerous is allowed only by a click on a button that says so: the shortcut,
                    // pressed out of habit, does nothing.
                    if danger {
                        PillButton(title: "仍要允许", style: .danger) { store.answer(approval, with: .allow) }
                    } else {
                        if allowsForSession, let rule = approval.sessionRule {
                            PillButton(title: "本会话都允许", style: .plain) { store.allowForSession(approval) }
                                .help("允许，并且这个会话结束前不再询问：\(rule.title)。标为「注意」「危险」的请求仍会询问。")
                        }
                        PillButton(title: "允许", style: .warn, hint: allowKey) { store.answer(approval, with: .allow) }
                    }
                } else {
                    PillButton(title: "跳到终端", style: .warn) { Terminal.focus(pid: approval.pid) }
                }
            }
            .padding(.top, 14)
        }
    }

    private var isShell: Bool {
        ["Bash", "shell", "exec_command", "local_shell", "run_shell_command", "Execute", "execute_bash", "bash", "powershell"].contains(approval.tool)
            || approval.tool.lowercased().contains("bash")
    }

    private var verb: String {
        if isShell { return "执行命令" }
        // Each CLI names its edit tools its own way (Qwen's edit and write_file, Gemini's replace…).
        if ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "write", "write_file", "replace", "create", "str_replace",
            "edit_file", "create_file"].contains(approval.tool) { return "修改文件" }
        if approval.tool.hasPrefix("mcp__") { return "调用 \(approval.tool.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " · "))" }
        return "使用 \(approval.tool)"
    }
}

/// Why a request is flagged: 注意 in orange, 危险 in red.
struct RiskLine: View {
    let risk: Risk

    var body: some View {
        let color = risk.level == .danger ? Palette.danger : Palette.warn
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(risk.level == .danger ? "危险" : "注意")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.22)))
            Text(risk.reason)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.12)))
    }
}

/// The files a request would change, as diffs. Folded to a few lines in all so the card stays small; one click shows
/// more. The card does not scroll: past the unfolded limit, the rest is counted and the terminal shows it all.
struct ChangesView: View {
    let changes: [FileChange]
    @State private var unfolded = false
    /// Lines shown across all files, folded and unfolded.
    static let folded = 10
    static let unfoldedLimit = 32
    /// Files shown; more are counted.
    static let files = 3

    private var shownFiles: [FileChange] { Array(changes.prefix(Self.files)) }
    private var total: Int { shownFiles.reduce(0) { $0 + $1.lines.count } }
    private var budget: Int { unfolded ? Self.unfoldedLimit : Self.folded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Each file gets what the ones before it left of the budget, but always its header and one line.
            let budgets = shownFiles.reduce(into: (left: budget, each: [Int]())) { state, change in
                let take = max(min(change.lines.count, 1), min(change.lines.count, state.left))
                state.each.append(take)
                state.left -= take
            }.each
            ForEach(Array(zip(shownFiles, budgets).enumerated()), id: \.offset) { _, item in
                FileBlock(change: item.0, limit: item.1)
            }
            let hidden = total - budgets.reduce(0, +)
            HStack(spacing: 10) {
                if hidden > 0 || unfolded, total > Self.folded {
                    Button(unfolded ? "收起" : "展开其余 \(min(hidden, Self.unfoldedLimit - Self.folded)) 行") { unfolded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                if unfolded, hidden > 0 { Text("还有 \(hidden) 行在终端里看").font(.system(size: 11)).foregroundStyle(Palette.dim) }
                if changes.count > Self.files { Text("还有 \(changes.count - Self.files) 个文件").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            }
        }
    }
}

struct FileBlock: View {
    let change: FileChange
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tag { Text(tag).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).fixedSize() }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text("+\(change.added)").foregroundStyle(Palette.ok)
                    Text("−\(change.removed)").foregroundStyle(Palette.danger)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if change.lines.isEmpty, change.added + change.removed > 0 {
                Text("改动太大，这里只计行数").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.bottom, 6)
            } else if !change.lines.isEmpty {
                let lines = Array(change.lines.prefix(limit))
                // Code deep in a function is shown from its common indentation, which the narrow card cannot spare.
                let indent = lines.filter { $0.kind != .gap && !$0.text.allSatisfy(\.isWhitespace) }.map { $0.text.prefix { $0 == " " }.count }.min() ?? 0
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in DiffRow(line: line, indent: indent) }
                }
                .padding(.bottom, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.wash(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var tag: String? {
        switch change.kind {
        case .create: "新文件 · \(change.added) 行"
        case .overwrite: "整个文件重写"
        case .delete: "删除文件"
        case .move(let to): "移到 \(to)"
        case .edit: change.firstLine.map { "第 \($0) 行" }
        }
    }
}

private struct DiffRow: View {
    let line: FileChange.Line
    /// Leading spaces every line shown shares, left out.
    let indent: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(line.kind == .removed ? "" : line.number.map(String.init) ?? "")
                .foregroundStyle(Palette.dim)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 6)
            Text(sign).foregroundStyle(signColor).frame(width: 12, alignment: .leading)
            Text(line.kind == .gap ? "⋯" : line.text.isEmpty ? " " : String(line.text.dropFirst(indent)))
                .foregroundStyle(line.kind == .context || line.kind == .gap ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 0.5)
        .background(background)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context, .gap: ""
        }
    }

    private var signColor: Color { line.kind == .added ? Palette.ok : Palette.danger }

    private var background: Color {
        switch line.kind {
        case .added: Palette.ok.opacity(0.14)
        case .removed: Palette.danger.opacity(0.14)
        case .context, .gap: .clear
        }
    }
}

/// An agent's question with choices (AskUserQuestion), answered here: a choice moves on to the next question; on the
/// last one (or where several choices are allowed) a button moves on or sends, so a slip of the pointer can be undone.
struct QuestionView: View {
    let approval: Approval
    let more: Int
    let store: SessionStore
    @State private var page = 0
    /// By question index: two questions may read the same.
    @State private var chosen: [Int: [String]] = [:]

    private var questions: [AgentQuestion] { approval.questions }
    private var index: Int { min(page, questions.count - 1) }
    private var question: AgentQuestion { questions[index] }
    private var isLast: Bool { page >= questions.count - 1 }
    private var picked: [String] { chosen[index] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(approval.harness.displayName) 想问你").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(approval.project).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                Spacer()
                if questions.count > 1 {
                    Text("\(page + 1)/\(questions.count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Palette.muted)
                }
                if more > 0 { Text("还有 \(more) 个").font(.system(size: 11)).foregroundStyle(Palette.warn) }
            }
            .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.warn.opacity(0.16)))
                }
                Text(question.question)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, 9)
            if question.multiSelect {
                Text("可多选").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 3)
            }
            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    QuestionOption(option: option, multiSelect: question.multiSelect, on: picked.contains(option.label)) { choose(option.label) }
                }
            }
            .padding(.top, 10)
            // Choices only: an answer of your own is typed in the CLI's prompt.
            Text("想自己写答案，点「在终端回答」").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 6)
            HStack(spacing: 6) {
                PillButton(title: "在终端回答", style: .plain) {
                    store.answer(approval, with: .terminal)
                    // The CLI asks there now: take you to it.
                    Terminal.focus(pid: approval.pid)
                }
                Spacer()
                if page > 0 { PillButton(title: "上一题", style: .plain) { page -= 1 } }
                if !picked.isEmpty {
                    PillButton(title: isLast ? "提交" : "下一题", style: .warn) { advance() }
                }
            }
            .padding(.top, 12)
        }
    }

    private func choose(_ label: String) {
        if question.multiSelect {
            var labels = picked
            if let index = labels.firstIndex(of: label) { labels.remove(at: index) } else { labels.append(label) }
            // Kept in the order the options are listed.
            chosen[index] = question.options.map(\.label).filter(labels.contains)
        } else {
            chosen[index] = [label]
            // The last answer is sent with the button, not the click.
            if !isLast { advance() }
        }
    }

    private func advance() {
        if isLast {
            store.answer(approval, with: .answers(AgentQuestion.answers(questions, chosen: chosen)))
        } else {
            page += 1
        }
    }
}

private struct QuestionOption: View {
    let option: AgentQuestion.Option
    let multiSelect: Bool
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Palette.warn : Palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.warn.opacity(0.15) : Palette.wash(hovering ? 0.11 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FinishedView: View {
    let session: Session
    @ObservedObject var model: NotchModel
    let store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(session.harness.displayName) 完成了").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(session.project).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            .lineLimit(1)
            if !session.lastMessage.isEmpty {
                Text(session.lastMessage).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(3).padding(.top, 6)
            }
            HStack {
                // Worked out a moment after the turn ends, so read from the session as it is now.
                if let changes = store.sessions.first(where: { $0.id == session.id })?.changes {
                    ChangesChip(changes: changes) { model.go(.changes(session.id)) }
                    Text(changes.files.isEmpty ? "" : "\(changes.files.count) 个文件").font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                Spacer()
                // Finishing is news, not a request to switch windows: acknowledging is the main answer. Going to the
                // session stays one click away when there is a window to find (none when its terminal closed, or a
                // background service runs it; its resume command stays in the session list's menu).
                if Terminal.app(for: session.pid) != nil {
                    PillButton(title: "打开会话", style: .plain) {
                        store.markSeen(session)
                        Terminal.focus(pid: session.pid)
                        model.go(.collapsed)
                    }
                }
                PillButton(title: "知道了", style: .primary) {
                    store.markSeen(session)
                    model.go(.collapsed)
                }
            }
            .padding(.top, 12)
        }
    }
}
