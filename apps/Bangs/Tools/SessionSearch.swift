import AppKit
import BangsCore
import Combine
import SwiftUI

/// The search at the top of the sessions tab: the sessions running now, then past ones, matching what you type.
@MainActor
final class SessionSearch: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selection = 0; notice = nil; schedule() } } }
    @Published var selection = 0
    /// Only one CLI's sessions; nil for all.
    @Published var harness: Harness? { didSet { selection = 0 } }
    @Published private(set) var hits: [HistorySearch.Hit] = []
    /// Bumped to give the search field the keyboard.
    @Published var focusRequest = 0
    /// A word for a moment after an action ("已复制恢复命令").
    @Published var notice: String?

    let history: SessionHistory
    private var work: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(history: SessionHistory) {
        self.history = history
        // Newly read sessions join the results under way.
        history.$sessions.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.schedule(delay: 0) } }.store(in: &subscriptions)
    }

    var active: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func clear() {
        query = ""
        harness = nil
    }

    private func schedule(delay: UInt64 = 120_000_000) {
        work?.cancel()
        guard active else { hits = []; return }
        history.refresh()
        let sessions = history.searchableIndex, query = query
        work = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) { HistorySearch.search(sessions, for: query) }.value
            guard !Task.isCancelled else { return }
            self?.hits = hits
        }
    }

    // MARK: What shows

    /// Running sessions matching every word, in their own fields; of one CLI when `only` is set.
    func live(in store: SessionStore, only: Harness?) -> [Session] {
        let words = HistorySearch.words(query)
        return store.sessions.filter { session in
            guard only == nil || session.harness == only else { return false }
            let haystack = [session.project, session.prompt, session.activity, session.lastMessage, session.sessionId, session.cwd].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    /// Past sessions, without those running now (they show above); of one CLI when `only` is set.
    func past(excluding running: Set<String>, only: Harness?) -> [HistorySearch.Hit] {
        hits.filter { !running.contains($0.session.id) && (only == nil || $0.session.harness == only) }
    }

    /// The results as shown: running first, then past, both of the chosen CLI.
    func shown(in store: SessionStore) -> (live: [Session], past: [HistorySearch.Hit]) {
        let running = Set(store.sessions.map(\.id))
        return (live(in: store, only: harness), past(excluding: running, only: harness))
    }

    /// How many sessions each CLI has among the results, for the filter.
    func counts(in store: SessionStore) -> [(harness: Harness, count: Int)] {
        let live = live(in: store, only: nil)
        let all = live.map(\.harness) + past(excluding: Set(store.sessions.map(\.id)), only: nil).map(\.session.harness)
        return Harness.allCases.compactMap { harness in
            let count = all.filter { $0 == harness }.count
            return count > 0 ? (harness, count) : nil
        }
    }

    // MARK: Keyboard

    enum KeyResult { case ignored, handled, jump(Session), resume(PastSession), copy(String) }

    /// ↑↓ choose, return resumes (or jumps to a running session), ⌘return copies the resume command, Esc clears.
    func handle(_ event: NSEvent, store: SessionStore) -> KeyResult {
        guard active else { return .ignored }
        let (live, past) = shown(in: store)
        let count = live.count + past.count
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125: if count > 0 { selection = min(selection + 1, count - 1) }; return .handled
        case 126: selection = max(selection - 1, 0); return .handled
        case 53: clear(); return .handled
        case 36, 76:
            if selection < live.count {
                let session = live[selection]
                return command ? session.resumeCommand.map { .copy($0) } ?? .handled : .jump(session)
            }
            guard past.indices.contains(selection - live.count) else { return .handled }
            let session = past[selection - live.count].session
            return command ? session.resumeCommand.map { .copy($0) } ?? .handled : .resume(session)
        default: return .ignored
        }
    }

    func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        say("已复制恢复命令")
    }

    func say(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.notice == text { self?.notice = nil }
        }
    }
}

// MARK: Views

struct SessionSearchField: View {
    @ObservedObject var search: SessionSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
            TextField("", text: $search.query, prompt: Text("搜索会话：标题、提示词、回复、项目、会话 ID").foregroundColor(Palette.dim))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .focused($focused)
            if search.active {
                Button { search.clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.dim) }.buttonStyle(.plain).help("清空")
            }
        }
        .fieldChrome(focused: focused)
        .onChange(of: search.focusRequest) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

/// The sessions tab while searching: a filter by CLI, the running sessions that match, then past ones.
struct SessionSearchResults: View {
    @ObservedObject var search: SessionSearch
    @ObservedObject var history: SessionHistory
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore
    static let rowHeight: CGFloat = 42

    var body: some View {
        let (live, past) = search.shown(in: store)
        VStack(alignment: .leading, spacing: 4) {
            let counts = search.counts(in: store)
            if counts.count > 1 {
                HStack(spacing: 6) {
                    chip("全部 \(counts.reduce(0) { $0 + $1.count })", selected: search.harness == nil) { search.harness = nil }
                    ForEach(counts, id: \.harness) { item in
                        chip("\(item.harness.displayName) \(item.count)", selected: search.harness == item.harness) { search.harness = item.harness }
                    }
                }
                .padding(.top, 2)
            }
            if let progress = history.progress {
                Text("正在读取历史会话 \(progress.done) / \(progress.total)，先显示已读到的")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.leading, 4)
            }
            if live.isEmpty && past.isEmpty {
                Text(history.progress == nil ? "没有找到「\(search.query)」" : "还在读取，稍等…")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 10).padding(.leading, 4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if !live.isEmpty { section("进行中") }
                            ForEach(Array(live.enumerated()), id: \.element.id) { index, session in
                                SessionRow(session: session, dismiss: { store.dismiss(session) }) {
                                    store.markSeen(session)
                                    guard Terminal.focus(pid: session.pid) else { return false }
                                    model.go(.collapsed)
                                    return true
                                }
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(index == search.selection ? Palette.accent.opacity(0.16) : .clear).padding(.horizontal, -8))
                                .id(session.id)
                            }
                            if !past.isEmpty { section("历史 · 找到 \(past.count) 个") }
                            ForEach(Array(past.enumerated()), id: \.element.id) { index, hit in
                                HistoryRow(hit: hit, selected: live.count + index == search.selection, search: search, model: model)
                                    .id(hit.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(live.count + past.count) * (Self.rowHeight + 1) + 52, 7.5 * Self.rowHeight))
                    .onChange(of: search.selection) { _, selection in
                        let ids = live.map(\.id) + past.map(\.id)
                        if ids.indices.contains(selection) { proxy.scrollTo(ids[selection]) }
                    }
                }
            }
            HStack(spacing: 14) {
                if let notice = search.notice {
                    Text(notice).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.ok)
                } else {
                    KeyHint(keys: [.text("↑"), .text("↓")], title: "选择")
                    KeyHint(keys: [.returnKey], title: "恢复")
                    KeyHint(keys: [.text("⌘"), .returnKey], title: "复制恢复命令")
                    KeyHint(keys: [.text("esc")], title: "清空")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.dim)
            .padding(.leading, 8).padding(.top, 6).padding(.bottom, 3)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).foregroundStyle(selected ? Palette.ink : Palette.muted)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Palette.accent.opacity(0.25) : Palette.wash(0.06)))
                .overlay(Capsule().strokeBorder(selected ? Palette.accent.opacity(0.6) : Palette.wash(0.08), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }
}

/// A past session: where and what, the line that matched, and how to pick it up again.
struct HistoryRow: View {
    let hit: HistorySearch.Hit
    let selected: Bool
    @ObservedObject var search: SessionSearch
    @ObservedObject var model: NotchModel
    @State private var hovering = false

    var body: some View {
        let session = hit.session
        HStack(spacing: 11) {
            Button(action: resume) {
                HStack(spacing: 11) {
                    HarnessIcon(harness: session.harness, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.project).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                            Text(session.shownTitle + (session.branch.isEmpty ? "" : " · \(session.branch)"))
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                        .lineLimit(1)
                        Text(snippet).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected || hovering, let command = session.resumeCommand {
                Button { search.copy(command) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("复制恢复命令（⌘ return）：\(command)")
                Button(action: resume) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal").font(.system(size: 10, weight: .semibold))
                        Text("恢复").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 0.77, green: 0.85, blue: 1))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Palette.accent.opacity(0.2)))
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .help("在新的终端窗口里恢复")
            } else {
                Text(Self.relative.localizedString(for: session.updated, relativeTo: Date()))
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SessionSearchResults.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.accent.opacity(0.16) : hovering ? Palette.row : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在终端里恢复", action: resume)
            if let command = session.resumeCommand { Button("复制恢复命令") { search.copy(command) } }
            Button("复制会话 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionId, forType: .string)
            }
            Button("在访达中显示目录") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd) }
                .disabled(session.cwd.isEmpty)
        }
    }

    private func resume() {
        guard let command = hit.session.resumeCommand else { return }
        if Terminal.run(command) {
            model.go(.collapsed)
        } else {
            search.copy(command)
        }
    }

    /// The line that matched, its match picked out.
    private var snippet: AttributedString {
        let label: String = switch hit.snippetField {
        case .id: "会话 ID "
        case .reply: "回复 "
        default: ""
        }
        var text = AttributedString(label + hit.snippet.before)
        var match = AttributedString(hit.snippet.match)
        match.foregroundColor = Palette.ink
        match.backgroundColor = Color(red: 1, green: 0.8, blue: 0).opacity(0.28)
        text += match
        text += AttributedString(hit.snippet.after)
        return text
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}
