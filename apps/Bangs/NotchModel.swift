import AppKit
import Combine
import BangsCore
import SwiftUI

/// Where the island sits: in the notch of the built-in display, or hanging under Bangs' menu bar icon on a Mac without one.
struct NotchGeometry {
    enum Placement { case notch, menuBar }

    let screen: NSScreen
    let placement: Placement
    /// Width of the camera housing (0 under the menu bar).
    let notchWidth: CGFloat
    /// Height of the island's top row. Under the menu bar there is none: the menu bar icon is the top row.
    let height: CGFloat
    /// The top centre the island hangs from, in screen coordinates.
    let anchor: CGPoint
    /// Room on each side of the notch: the agent on the left, its status on the right.
    static let side: CGFloat = 26
    /// Half the widest menu bar panel, to keep it on screen under an icon near the edge.
    static let halfWidth: CGFloat = 200

    init(notchScreen screen: NSScreen) {
        self.screen = screen
        placement = .notch
        let left = screen.auxiliaryTopLeftArea?.width ?? 0, right = screen.auxiliaryTopRightArea?.width ?? 0
        notchWidth = screen.frame.width - left - right
        height = screen.safeAreaInsets.top
        anchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
    }

    /// `item` is the menu bar icon's frame, when it is on screen.
    init(menuBarItem item: NSRect?, screen: NSScreen) {
        self.screen = screen
        placement = .menuBar
        notchWidth = 0
        height = 0
        let frame = screen.frame, bar = frame.maxY - screen.visibleFrame.maxY
        // A crowded menu bar hides the icon, which then reports a place outside the menu bar (the screen's bottom left):
        // open at the top right instead.
        let item = item.flatMap { $0.midY > frame.maxY - 60 && frame.minX...frame.maxX ~= $0.midX ? $0 : nil }
        let x = item?.midX ?? frame.maxX - 160
        anchor = CGPoint(x: min(max(x, frame.minX + Self.halfWidth + 8), frame.maxX - Self.halfWidth - 8),
                         y: (item?.minY ?? frame.maxY - (bar > 0 ? bar : NSStatusBar.system.thickness)) - 5)
    }

    /// A notch of the given size at the top of `screen`, for tests and snapshots.
    init(notchWidth: CGFloat, height: CGFloat, screen: NSScreen) {
        self.screen = screen
        placement = .notch
        self.notchWidth = notchWidth
        self.height = height
        anchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
    }

    var hasNotch: Bool { placement == .notch }

    static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } }

    static func screen(containing rect: NSRect?) -> NSScreen {
        rect.flatMap { rect in NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case collapsed
        case expanded
        case approval
        case finished(Session)
        case reminder(Agenda.Meeting)
        case captured(URL)
        case screenPermission
        case update(Updater.Release)
        /// Text read off the screen, to look over and copy again.
        case recognized(String)
        /// A table read off the screen, copied as one; its text as plain lines, to copy instead.
        case table(RecognizedTable, text: String)
        /// A focus or a break ended: which, what started after it, and how many agents finished meanwhile.
        case focusEnded(FocusTimer.Phase, FocusTimer.Phase?, agents: Int)
        /// What a session's last turn changed in its git checkout, by session id.
        case changes(String)
        /// Selected text, translated (see Translator, which holds it).
        case translation

        var isOpen: Bool { self != .collapsed }
        var key: String {
            switch self {
            case .collapsed: "collapsed"
            case .expanded: "expanded"
            case .approval: "approval"
            case .finished(let session): "finished-\(session.id)"
            case .reminder(let meeting): "reminder-\(meeting.id)"
            case .captured(let url): "captured-\(url.path)"
            case .screenPermission: "screen-permission"
            case .update(let release): "update-\(release.version)"
            case .recognized(let text): "recognized-\(text.hashValue)"
            case .table(let table, _): "table-\(table.tsv.hashValue)"
            case .focusEnded(let phase, _, _): "focus-\(phase.rawValue)"
            case .changes(let id): "changes-\(id)"
            case .translation: "translation"
            }
        }
    }

    @Published private(set) var mode: Mode = .collapsed
    @Published var hovered = false
    /// A full-screen app owns the top of the screen: stay out of the way unless a decision is needed.
    @Published var fullScreen = false
    @Published var contentHeight: CGFloat = 0
    /// The spring of the transition in progress: bouncy when growing, crisp when shrinking.
    @Published private(set) var motion: Animation = Motion.open
    /// The tool the open island shows.
    @Published var tool: Tool { didSet { preferences.lastTool = tool.rawValue } }
    @Published var showsAwakeOptions = false
    /// Files are being dragged over the island.
    @Published var dropTargeted = false

    let store: SessionStore
    let preferences: Preferences
    let toolbox: Toolbox
    private(set) var geometry: NotchGeometry
    var showSettings: (SettingsPane?) -> Void = { _ in }
    /// The window controller gives the island the keyboard (for the clipboard search) and takes it back.
    /// Where a capture was also saved (the Desktop or Downloads), so the preview shows it rather than saving it twice.
    private(set) var savedCopies: [URL: URL] = [:]
    var focusKeyboard: () -> Void = {}
    var releaseKeyboard: () -> Void = {}
    /// The island has the keyboard: you are typing in it.
    var holdsKeyboard: () -> Bool = { false }
    private var dismiss: DispatchWorkItem?
    private var queued: [Session] = []
    private var subscriptions: Set<AnyCancellable> = []

    enum Motion {
        static let open = Animation.spring(response: 0.45, dampingFraction: 0.78)
        static let close = Animation.spring(response: 0.38, dampingFraction: 1)
        /// Switching tabs: quick and without overshoot, since the island stays open.
        static let tab = Animation.spring(response: 0.28, dampingFraction: 0.9)
    }

    init(store: SessionStore, preferences: Preferences, toolbox: Toolbox, geometry: NotchGeometry) {
        self.store = store
        self.preferences = preferences
        self.toolbox = toolbox
        self.geometry = geometry
        tool = Tool(rawValue: preferences.lastTool) ?? .sessions
        // The closed island shows these, so their changes redraw it.
        for publisher in [toolbox.keepAwake.objectWillChange.eraseToAnyPublisher(), toolbox.agenda.objectWillChange.eraseToAnyPublisher(),
                          toolbox.focus.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &subscriptions)
        }
        toolbox.system.objectWillChange.sink { [weak self] in
            guard let self, self.preferences.usageInNotch != .off else { return }
            DispatchQueue.main.async { self.objectWillChange.send() }
        }.store(in: &subscriptions)
        preferences.$usageInNotch.sink { [weak toolbox] usage in toolbox?.system.inNotch = usage != .off }.store(in: &subscriptions)
        preferences.$meetingLead.sink { [weak toolbox] minutes in toolbox?.agenda.lead = TimeInterval(minutes * 60) }.store(in: &subscriptions)
        preferences.$meetingStartReminder.sink { [weak toolbox] on in toolbox?.agenda.remindsAtStart = on }.store(in: &subscriptions)
        preferences.$meetingsWithLinkOnly.sink { [weak toolbox] on in toolbox?.agenda.linkedOnly = on }.store(in: &subscriptions)
        toolbox.focus.onEnded = { [weak self] ended, started in self?.focusEnded(ended, started) }
        toolbox.screenshots.onRecognized = { [weak self] text in self?.recognized(text) }
        toolbox.screenshots.onTable = { [weak self] table, text in self?.recognized(table, text: text) }
        store.$sessions.sink { [weak toolbox] sessions in
            let working = sessions.contains { $0.status == .working || $0.status == .approval }
            DispatchQueue.main.async { toolbox?.keepAwake.agentsChanged(working: working) }
        }.store(in: &subscriptions)
        toolbox.agenda.onReminder = { [weak self] meeting in self?.remind(meeting) }
        toolbox.updater.onFound = { [weak self] release in
            guard let self, self.mode == .collapsed, self.store.approvals.isEmpty else { return }
            self.go(.update(release))
        }
        toolbox.screenshots.onCaptured = { [weak self] url in self?.captured(url) }
        toolbox.screenshots.onNeedsPermission = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.go(.screenPermission) }
        }
        preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { withAnimation(Motion.close) { self?.objectWillChange.send() } }
        }.store(in: &subscriptions)
        // Deferred, so the mode changes after the session update that caused it has been published.
        store.onFinished = { [weak self] session in DispatchQueue.main.async { self?.finished(session) } }
        // The header and size derive from the sessions, so any session change redraws the island.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        // By id: a request's diff arriving a moment later is the same request, not a new one to open for.
        store.$approvals.removeDuplicates { $0.map(\.id) == $1.map(\.id) }.sink { [weak self] approvals in
            DispatchQueue.main.async { self?.approvalsChanged(approvals) }
        }.store(in: &subscriptions)
    }

    /// A display was added, removed or rescaled: the island takes its new size at once rather than at the next change.
    func update(geometry: NotchGeometry) {
        objectWillChange.send()
        self.geometry = geometry
    }

    /// Over a full-screen app only a decision, or the list you asked for, shows.
    var hidden: Bool { fullScreen && store.approvals.isEmpty && mode != .expanded }
    /// The closed island is no bigger than the notch: with nothing to show it tucks itself in and peeks out under the
    /// pointer; in the hidden style it stays in until a decision or an alert opens it.
    var retracted: Bool {
        guard geometry.hasNotch, !mode.isOpen else { return false }
        switch preferences.notchStyle {
        case .always: return false
        // Only agents at work and a meeting about to start keep it out; the load and keep-awake are always there, so
        // they would never let it tuck in. They show when it peeks out.
        case .autoHide: return !store.active && toolbox.agenda.countdown() == nil && focusCountdown == nil && !hovered
        case .hidden: return true
        }
    }
    /// The closed island swells a little under the pointer, except where it keeps to the notch's size.
    var swells: Bool { hovered && !mode.isOpen && !(retracted && preferences.notchStyle == .hidden) }
    /// Under the menu bar the icon shows the status, so the island is there only while open.
    var invisible: Bool { hidden || (!geometry.hasNotch && !mode.isOpen) }

    // MARK: Size

    var width: CGFloat {
        if !geometry.hasNotch, mode.isOpen { return mode == .expanded ? 400 : 380 }
        return switch mode {
        case .collapsed: retracted ? geometry.notchWidth : collapsedWidth
        case .expanded: 540
        case .approval: 460
        case .finished, .reminder: 420
        case .captured: 560
        case .screenPermission, .update, .focusEnded: 440
        case .recognized, .translation: 480
        case .table, .changes: 520
        }
    }
    /// The notch with its two sides; under the menu bar, a sliver at the icon for the island to grow from.
    var collapsedWidth: CGFloat { geometry.hasNotch ? geometry.notchWidth + sideWidth * 2 : 36 }

    // MARK: Extras on the closed island

    enum Extra: Hashable {
        case awake(String)
        case meeting(String)
        case focus(String)
        case load(Int)
    }

    /// Small readouts beside the status: keep-awake time left, the next meeting, the CPU load.
    var extras: [Extra] {
        var extras: [Extra] = []
        if toolbox.keepAwake.active { extras.append(.awake(toolbox.keepAwake.label)) }
        if let meeting = toolbox.agenda.upcoming {
            let minutes = Int(ceil(meeting.start.timeIntervalSinceNow / 60))
            extras.append(.meeting(minutes > 0 ? "\(minutes)分" : "开会"))
        } else if let run = focusCountdown {
            extras.append(.focus(run.paused ? "暂停" : "\(Int(ceil(run.remaining() / 60)))分"))
        }
        if let load = usage { extras.append(.load(Int((load * 100).rounded()))) }
        return extras
    }

    /// The CPU or memory load the closed island shows, 0 to 1.
    var usage: Double? {
        switch preferences.usageInNotch {
        case .off: nil
        case .cpu: toolbox.system.cpu
        case .memory: Double(toolbox.system.memoryUsed) / Double(max(1, toolbox.system.memoryTotal))
        }
    }

    // MARK: The closed notch

    /// The right of the closed notch.
    var status: NotchStatus {
        let activity: NotchStatus.Activity? = !store.approvals.isEmpty ? .asking : !store.working.isEmpty ? .working
            : store.sessions.contains { $0.unseen && $0.status == .finished } ? .done : nil
        if toolbox.agenda.countdown() == nil, let run = focusCountdown {
            let frozen = run.paused ? Date() : nil
            return NotchStatus(activity: activity, meeting: (frozen ?? Date()).addingTimeInterval(run.remaining()), lead: run.length, usage: usage,
                               tint: run.phase.isBreak ? .rest : .focus, frozen: frozen)
        }
        return NotchStatus(activity: activity, meeting: toolbox.agenda.countdown()?.start, lead: toolbox.agenda.lead, usage: usage)
    }

    /// The focus or break the closed notch counts down; a meeting about to start takes its place.
    var focusCountdown: FocusTimer.Run? { preferences.focusInNotch ? toolbox.focus.run : nil }

    /// The agent on the left of the closed notch, and how many other sessions there are.
    var leadingHarness: Harness? { shownHarnesses.first }
    var otherSessions: Int { max(0, store.sessions.filter { $0.status == .working || $0.status == .approval || $0.unseen }.count - 1) }

    /// Both sides of the closed notch take the width the right needs, so the island stays centred on the notch.
    var sideWidth: CGFloat { status.isEmpty ? NotchGeometry.side : status.width() }
    /// Where Bangs' face on the left looks, when no agent is about.
    let pointer = Pointer()
    /// The face's centre on screen, for its eyes to find the pointer.
    var faceCentre: CGPoint {
        CGPoint(x: geometry.anchor.x - geometry.notchWidth / 2 - sideWidth / 2, y: geometry.anchor.y - geometry.height / 2)
    }
    var size: CGSize {
        CGSize(width: width, height: geometry.height + (mode.isOpen ? contentHeight : 0))
    }
    var ear: CGFloat { !geometry.hasNotch ? 0 : mode.isOpen ? 14 : retracted ? 0 : 6 }
    var radius: CGFloat { mode.isOpen ? 24 : 10 }
    /// The island's frame in screen coordinates, shoulders included, for hit testing.
    /// While retracted it is where the collapsed island would be, so hovering there brings it out; hidden, the notch.
    var screenRect: CGRect {
        let peeks = retracted && preferences.notchStyle != .hidden
        let width = retracted ? (peeks ? collapsedWidth : geometry.notchWidth) + 12 : size.width + ear * 2
        let centre = geometry.anchor.x
        let scale: CGFloat = swells ? 1.06 : 1
        return CGRect(x: centre - width * scale / 2, y: geometry.anchor.y - size.height * scale, width: width * scale, height: size.height * scale)
    }

    // MARK: Transitions

    func toggle() {
        switch mode {
        case .expanded: collapse()
        // The tool it was on last may have been turned off since.
        default: open(preferences.shows(tool) ? tool : .sessions)
        }
    }

    /// Opens the island on a tool; the clipboard and the files take the keyboard for their search.
    func open(_ tool: Tool) {
        self.tool = tool
        go(.expanded)
        takesKeyboard(tool)
    }

    /// Opens the files tab with its search taking the keyboard.
    func searchFiles() {
        open(.files)
    }

    private func takesKeyboard(_ tool: Tool) {
        if tool == .clipboard { focusKeyboard() }
        if tool == .files {
            focusKeyboard()
            toolbox.files.focusRequest += 1
        }
    }

    /// Opens the sessions tab with the search taking the keyboard.
    func searchSessions() {
        open(.sessions)
        focusKeyboard()
        toolbox.sessionSearch.focusRequest += 1
        toolbox.history.refresh()
    }

    func select(_ tool: Tool) {
        guard tool != self.tool else { return }
        motion = Motion.tab
        withAnimation(Motion.tab) { self.tool = tool }
        // Leaving the clipboard keeps the keyboard: handing it back reorders the panel, which flashes. It goes back when
        // the panel closes, or as soon as you click another app.
        takesKeyboard(tool)
    }

    /// ⌥⌘↩ / ⌥⌘⌫: answers the request on the card, from any app. Only one you can see (never one waiting behind the open
    /// toolbox), never a question with choices, and never allows one flagged as dangerous, which takes a click on 仍要允许.
    /// False when nothing was answered, for the caller to beep.
    func answerFromKeyboard(allowing: Bool) -> Bool {
        guard mode == .approval, let approval = store.approvals.first, approval.answerable, approval.questions.isEmpty else { return false }
        if allowing, approval.risk?.level == .danger { return false }
        store.answer(approval, with: allowing ? .allow : .deny)
        return true
    }

    /// Esc closes; the clipboard and the session search handle their own keys.
    func keyDown(_ event: NSEvent) -> Bool {
        if mode == .expanded, tool == .sessions {
            switch toolbox.sessionSearch.handle(event, store: store) {
            case .ignored: break
            case .handled: return true
            case .jump(let session):
                store.markSeen(session)
                if Terminal.focus(pid: session.pid) { collapse() } else if let command = session.resumeCommand { toolbox.sessionSearch.copy(command) }
                return true
            case .resume(let past):
                if let command = past.resumeCommand {
                    if Terminal.run(command) { collapse() } else { toolbox.sessionSearch.copy(command) }
                }
                return true
            case .copy(let command):
                toolbox.sessionSearch.copy(command)
                return true
            }
        }
        if mode == .expanded, tool == .files {
            switch toolbox.files.handle(event) {
            case .ignored: break
            case .handled: return true
            case .open(let hit):
                if toolbox.files.open(hit) { collapse() }
                return true
            }
        }
        if event.keyCode == 53 { collapse(); return true }
        guard mode == .expanded, tool == .clipboard else { return false }
        switch toolbox.clipboard.handle(event) {
        case .ignored: return false
        case .handled: return true
        case .paste(let item, let copyOnly): paste(item, copyOnly: copyOnly); return true
        }
    }

    /// Puts an item back on the pasteboard and, unless only copying, pastes it into the app you were in.
    func paste(_ item: ClipItem, copyOnly: Bool) {
        toolbox.clipboard.write(item)
        toolbox.clipboard.query = ""
        collapse()
        releaseKeyboard()
        guard !copyOnly, preferences.autoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { _ = ClipboardHistory.pasteIntoFrontApp() }
    }

    func shoot(_ action: ShortcutAction) {
        go(.collapsed)
        releaseKeyboard()
        switch action {
        case .shotRegion: toolbox.screenshots.region(annotates: preferences.shotAnnotate)
        case .shotWindow: toolbox.screenshots.window()
        case .shotScroll: toolbox.screenshots.scrolling(lockKey: preferences.scrollLockKey)
        case .shotText: toolbox.screenshots.text(language: preferences.ocrLanguage, joinLines: preferences.ocrJoinsLines, tables: preferences.ocrTables)
        default: break
        }
    }

    private func captured(_ url: URL) {
        toolbox.clipboard.addImage(at: url)
        let folder: FileManager.SearchPathDirectory? = switch preferences.shotFolder {
        case .none: nil
        case .desktop: .desktopDirectory
        case .downloads: .downloadsDirectory
        }
        if let folder, let directory = FileManager.default.urls(for: folder, in: .userDomainMask).first {
            let copy = Storage.unique(url.lastPathComponent, in: directory)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                savedCopies[url] = copy
            } catch {
                Log.write("screenshot: could not save a copy to \(copy.path): \(error)")
            }
        }
        if preferences.shotPreview { go(.captured(url)) }
    }

    /// Text read off the screen goes on the pasteboard and into the history; the island shows it to look over.
    private func recognized(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { toolbox.clipboard.copy(text, app: "截图识字") }
        guard preferences.ocrShowsResult || text.isEmpty else { return }
        // The keyboard stays with your app, where ⌘V is likely next; clicking into the text edits it.
        go(.recognized(text))
    }

    /// A table goes on the pasteboard as tab-separated text, which spreadsheets split into cells, and as HTML, which
    /// keeps merged cells; the island shows it, with the way back to plain text.
    private func recognized(_ table: RecognizedTable, text: String) {
        copy(table)
        guard preferences.ocrShowsResult else { return }
        go(.table(table, text: text))
    }

    func openSettings(_ pane: SettingsPane? = nil) { showSettings(pane) }

    /// Translates the text selected in the app in front (see SelectedText), in the island.
    func translateSelection() {
        let translator = toolbox.translator
        let copying = preferences.translateCopies
        Task {
            if let grab = await SelectedText.read(copying: copying, clipboard: toolbox.clipboard) {
                translator.start(grab.text, app: grab.app, field: grab.field)
            } else {
                translator.nothingSelected()
            }
            go(.translation)
            scheduleDismissForTranslation()
        }
    }

    /// Translates text Bangs already has (read off the screen, a clipboard item).
    func translate(_ text: String, from app: String) {
        toolbox.translator.start(text, app: app)
        go(.translation)
        scheduleDismissForTranslation()
    }

    /// Reading takes longer than a glance; nothing selected is a short note. Set after `go`, which leaves the timer alone
    /// when the island already shows a translation and a second one replaces it.
    private func scheduleDismissForTranslation() {
        scheduleDismiss(after: toolbox.translator.phase == .nothingSelected ? 3 : 30)
    }

    /// Hands something to an agent's terminal (see Handoff); the island gets out of the way first.
    func send(_ payload: Handoff.Payload, to session: Session) {
        go(.collapsed)
        Handoff.send(payload, to: session, clipboard: toolbox.clipboard)
    }

    var handoff: HandoffAction {
        HandoffAction(sessions: { [store] in Handoff.targets(in: store) }, send: { [weak self] payload, session in self?.send(payload, to: session) })
    }

    func copy(_ table: RecognizedTable) {
        toolbox.clipboard.copy(table.tsv, app: "截图识字", rich: [NSPasteboard.PasteboardType.html.rawValue: Data(table.html.utf8)])
    }

    private func focusEnded(_ ended: FocusTimer.Phase, _ started: FocusTimer.Phase?) {
        toolbox.focus.playSound()
        guard preferences.focusAlerts, store.approvals.isEmpty, mode != .expanded else { return }
        go(.focusEnded(ended, started, agents: ended == .focus ? toolbox.focus.agentsThisRound : 0))
    }

    private func remind(_ meeting: Agenda.Meeting) {
        guard mode != .expanded, store.approvals.isEmpty else { return }
        go(.reminder(meeting))
    }

    func collapse() {
        if !store.approvals.isEmpty { go(.approval) } else if let next = queued.popLast() { go(.finished(next)) } else { go(.collapsed) }
    }

    func go(_ next: Mode) {
        dismiss?.cancel()
        guard next != mode else { return }
        let growing = Self.rank(next) >= Self.rank(mode)
        motion = growing ? Motion.open : Motion.close
        withAnimation(motion) { mode = next }
        if next != .expanded { showsAwakeOptions = false; releaseKeyboard() }
        switch next {
        case .finished, .captured: scheduleDismiss()
        // Nothing read: a short note. Read text stays a while, longer under the pointer or while you edit it.
        case .recognized(let text): scheduleDismiss(after: text.isEmpty ? 3 : 15)
        case .table: scheduleDismiss(after: 15)
        case .focusEnded(_, let started, _): scheduleDismiss(after: started == nil ? 30 : 10)
        // The nudge as a meeting starts stays five seconds; the one ahead of it a minute and a half.
        case .reminder(let meeting): scheduleDismiss(after: meeting.start <= Date() ? 5 : 90)
        default: break
        }
    }

    func hoverEnded() {
        switch mode {
        case .finished, .captured, .focusEnded: scheduleDismiss(after: 2.5)
        case .recognized, .table: scheduleDismiss(after: 6)
        case .translation: scheduleDismiss(after: 8)
        default: break
        }
    }

    private func scheduleDismiss(after delay: TimeInterval = 8) {
        dismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hovered || self.holdsKeyboard() { return }
            self.go(self.store.approvals.isEmpty ? .collapsed : .approval)
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finished(_ session: Session) {
        // While you focus a finished agent only lights its dot; the break tells you how many there were.
        let quiet = preferences.focusQuiet && toolbox.focus.focusing
        toolbox.focus.agentFinished()
        guard !fullScreen, !quiet else { return }
        switch mode {
        case .collapsed: go(.finished(session))
        case .finished, .reminder, .captured, .screenPermission, .update, .focusEnded: go(.finished(session))
        case .approval, .recognized, .table, .changes, .translation: queued.insert(session, at: 0)
        case .expanded: break
        }
    }

    private func approvalsChanged(_ approvals: [Approval]) {
        if approvals.isEmpty {
            if mode == .approval { collapse() }
        } else if mode != .expanded {
            go(.approval)
        }
    }

    private static func rank(_ mode: Mode) -> Int {
        switch mode {
        case .collapsed: 0
        case .finished, .reminder, .captured, .screenPermission, .update, .recognized, .table, .focusEnded, .changes, .translation: 1
        case .approval: 2
        case .expanded: 3
        }
    }

    /// What Bangs' status icon shows: approvals first, then running agents, a finished turn, a meeting, else Bangs asleep
    /// (or awake, while keep-awake is on). A dot per session: waiting for you, running, then finished and not yet seen.
    var glyph: (state: StatusGlyph.State, dots: [StatusGlyph.Dot]) {
        let awake = toolbox.keepAwake.active
        let running = store.sessions.filter { $0.status == .working }.count
        let unseen = store.sessions.filter { $0.unseen && $0.status == .finished }.count
        let dots = Array(([StatusGlyph.Dot](repeating: .asking, count: store.approvals.count)
                          + [StatusGlyph.Dot](repeating: .running, count: running)
                          + [StatusGlyph.Dot](repeating: .finished, count: unseen)).prefix(4))
        let state: StatusGlyph.State
        if !store.approvals.isEmpty { state = .approval }
        else if running > 0 { state = .working }
        else if unseen > 0 { state = .finished }
        else if let meeting = toolbox.agenda.upcoming { state = .meeting(left: meeting.start.timeIntervalSinceNow / 600, awake: awake) }
        else if let run = focusCountdown { state = .meeting(left: run.remaining() / max(run.length, 1), awake: awake) }
        else { state = .idle(awake: awake) }
        return (state, dots)
    }

    /// The CLIs shown on the right of the notch: the one an alert is about, else those running (or waiting on you).
    var shownHarnesses: [Harness] {
        switch mode {
        case .finished(let session): return [session.harness]
        case .approval: if let approval = store.approvals.first { return [approval.harness] }
        default: break
        }
        return Array(activeHarnesses.prefix(3))
    }

    /// The CLIs at work: those running now, else those waiting on you.
    var activeHarnesses: [Harness] {
        var seen: [Harness] = []
        let sessions = store.working.isEmpty ? store.sessions.filter { $0.unseen || $0.status == .approval } : store.working
        for session in sessions where !seen.contains(session.harness) { seen.append(session.harness) }
        return Array(seen.prefix(5))
    }
}
