import AppKit
import SwiftUI

/// The island's tools, one tab each.
enum Tool: String, CaseIterable {
    case sessions, files, clipboard, shelf, screenshot, focus, calendar, system

    var title: String {
        switch self {
        case .sessions: "会话"
        case .files: "文件"
        case .clipboard: "剪贴板"
        case .shelf: "中转站"
        case .screenshot: "截图"
        case .focus: "专注"
        case .calendar: "日历"
        case .system: "状态"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "terminal"
        case .files: "doc.text.magnifyingglass"
        case .clipboard: "doc.on.clipboard"
        case .shelf: "tray"
        case .screenshot: "camera.viewfinder"
        case .focus: "timer"
        case .calendar: "calendar"
        case .system: "cpu"
        }
    }
}

/// Everything the island can do besides watching agents.
@MainActor
final class Toolbox {
    let clipboard: ClipboardHistory
    let keepAwake = KeepAwake()
    let system = SystemMonitor()
    let agenda = Agenda()
    let shelf: Shelf
    let screenshots = Screenshots()
    let updater: Updater
    let focus: FocusTimer
    let history: SessionHistory
    let sessionSearch: SessionSearch
    let files: FileSearch
    let charge: ChargeLimiter
    let translator: Translator

    init(preferences: Preferences) {
        clipboard = ClipboardHistory(preferences: preferences)
        focus = FocusTimer(preferences: preferences)
        history = SessionHistory(preferences: preferences)
        sessionSearch = SessionSearch(history: history)
        files = FileSearch(preferences: preferences)
        charge = ChargeLimiter(preferences: preferences)
        translator = Translator(preferences: preferences)
        // Read past sessions in the background soon after launch, so the first search finds them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [history] in history.refresh() }
        updater = Updater(preferences: preferences)
        shelf = Shelf(preferences: preferences)
        screenshots.keeps = { [shelf] url in shelf.files.contains(url) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [screenshots] in screenshots.prune() }
        // So the first table read after an update does not wait half a minute for macOS to get its reader ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if preferences.ocrTables { TableRecognition.prepareOnce(language: preferences.ocrLanguage) } }
    }
}

/// The open island: the tabs, then the chosen tool.
struct ToolboxView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TabBar(model: model, store: store, keepAwake: model.toolbox.keepAwake)
            if model.showsAwakeOptions {
                AwakeOptions(model: model, keepAwake: model.toolbox.keepAwake, store: store)
            }
            switch model.tool {
            case .sessions: SessionList(model: model, store: store, search: model.toolbox.sessionSearch)
            case .files: FileSearchView(search: model.toolbox.files, model: model)
            case .clipboard: ClipboardView(history: model.toolbox.clipboard) { item, copyOnly in model.paste(item, copyOnly: copyOnly) }
            case .shelf: ShelfView(shelf: model.toolbox.shelf, targeted: model.dropTargeted)
            case .screenshot: ScreenshotView(shoot: { model.shoot($0) }, preferences: model.preferences)
            case .focus: FocusView(timer: model.toolbox.focus, preferences: model.preferences)
            case .calendar: AgendaView(agenda: model.toolbox.agenda)
            case .system: SystemView(monitor: model.toolbox.system, store: store)
            }
        }
    }
}

private struct TabBar: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: SessionStore
    @ObservedObject var keepAwake: KeepAwake
    @Environment(\.onGlass) private var onGlass
    @Namespace private var tabs

    var body: some View {
        if model.geometry.hasNotch { pills } else { segments }
    }

    /// Under the menu bar: an icon-only segmented control, like the system's. On Liquid Glass it is a capsule whose
    /// selected pill slides from tab to tab.
    private var segments: some View {
        let track = onGlass ? AnyShape(Capsule(style: .continuous)) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        let knob = onGlass ? AnyShape(Capsule(style: .continuous)) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        return HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(model.preferences.visibleTools, id: \.self) { tool in
                    let selected = model.tool == tool
                    Button { model.select(tool) } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Palette.ink : Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: onGlass ? 26 : 24)
                            .background {
                                if selected {
                                    knob.fill(onGlass ? Palette.knob : Palette.wash(0.16))
                                        .shadow(color: .black.opacity(onGlass ? 0.14 : 0.12), radius: onGlass ? 2 : 1, y: 0.5)
                                        .matchedGeometryEffect(id: "knob", in: tabs)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }
            .padding(2)
            .background(track.fill(Palette.wash(0.07)))
            awakeButton
            settingsButton
        }
    }

    private var awakeButton: some View {
        Button { withAnimation(NotchModel.Motion.tab) { model.showsAwakeOptions.toggle() } } label: {
            Image(systemName: keepAwake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 11.5))
                .foregroundStyle(keepAwake.active ? Palette.warn : Palette.dim)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("防休眠")
    }

    private var settingsButton: some View {
        Button { model.openSettings() } label: {
            Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(Palette.dim).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置")
    }

    /// Beside the notch: labelled pills; when they do not all fit, only the chosen one keeps its label.
    private var pills: some View {
        HStack(spacing: 2) {
            ViewThatFits(in: .horizontal) {
                pillRow(labelled: { _ in true })
                pillRow(labelled: { $0 == model.tool })
            }
            Spacer(minLength: 4)
            awakeButton
            settingsButton
        }
        .padding(.horizontal, -6)
    }

    private func pillRow(labelled: @escaping (Tool) -> Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(model.preferences.visibleTools, id: \.self) { tool in
                Button { model.select(tool) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tool.symbol).font(.system(size: 10.5))
                        if labelled(tool) {
                            Text(tool.title).font(.system(size: 11.5, weight: model.tool == tool ? .medium : .regular))
                        }
                        if tool == .sessions, !store.sessions.isEmpty {
                            Text("\(store.sessions.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.dim)
                        }
                    }
                    .foregroundStyle(model.tool == tool ? Palette.ink : Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(model.tool == tool ? Palette.wash(0.13) : .clear))
                    .contentShape(Capsule())
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
        }
    }
}

private struct AwakeOptions: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 12)).foregroundStyle(keepAwake.active ? Palette.warn : Palette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("防休眠").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                Text(status).font(.system(size: 10.5)).foregroundStyle(Palette.dim).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 4)
            option("1 小时", .until(Date().addingTimeInterval(3600)), selected: { if case .until = $0 { true } else { false } })
            if !store.working.isEmpty || keepAwake.mode == .agents {
                option("直到 Agent 跑完", .agents, selected: { $0 == .agents })
            }
            option("一直", .forever, selected: { $0 == .forever })
            if keepAwake.active {
                PillButton(title: "关闭", style: .plain) { keepAwake.set(.off) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.wash(0.06)))
    }

    private var status: String {
        switch keepAwake.mode {
        case .off: "Mac 不睡，屏幕照常熄灭"
        case .until: "还剩 \(keepAwake.label)"
        case .agents: "Agent 都跑完后自动关闭"
        case .forever: "直到你关闭"
        }
    }

    private func option(_ title: String, _ mode: KeepAwake.Mode, selected: (KeepAwake.Mode) -> Bool) -> some View {
        PillButton(title: title, style: selected(keepAwake.mode) ? .warn : .plain) { keepAwake.set(mode) }
    }
}

/// A meeting about to start.
struct ReminderView: View {
    let meeting: Agenda.Meeting
    @ObservedObject var model: NotchModel
    /// Started: a red ring runs down the five seconds before the island closes.
    @State private var running = false

    var body: some View {
        let started = meeting.start <= Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(Agenda.until(meeting, now: context.date)).font(.system(size: 11.5, weight: started ? .semibold : .regular))
                        .foregroundStyle(started ? Palette.danger : Palette.accent)
                }
                if started {
                    Spacer(minLength: 0)
                    Circle().trim(from: 0, to: running ? 0 : 1)
                        .stroke(Palette.danger, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .background(Circle().stroke(Palette.wash(0.15), lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .onAppear { withAnimation(.linear(duration: 5)) { running = true } }
                }
            }
            Text(["\(Agenda.time(meeting.start))–\(Agenda.time(meeting.end))", meeting.service ?? meeting.place].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1).padding(.top, 4)
            HStack(spacing: 6) {
                Spacer()
                PillButton(title: "知道了", style: .plain) { model.go(.collapsed) }
                if let join = meeting.join {
                    PillButton(title: "加入", style: .warn) {
                        NSWorkspace.shared.open(join)
                        model.go(.collapsed)
                    }
                }
            }
            .padding(.top, 12)
        }
    }
}
