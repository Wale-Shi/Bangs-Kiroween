import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// A focus timer: focus, a short break, focus again, and a long break after every fourth focus.
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: String, Codable {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: "专注"
            case .shortBreak: "短休息"
            case .longBreak: "长休息"
            }
        }

        var isBreak: Bool { self != .focus }
    }

    /// The phase under way. Paused, `left` holds the time still to go and `end` means nothing.
    struct Run: Equatable {
        var phase: Phase
        var end: Date
        var length: TimeInterval
        var left: TimeInterval?

        var paused: Bool { left != nil }
        func remaining(at now: Date = Date()) -> TimeInterval { left ?? max(0, end.timeIntervalSince(now)) }
    }

    /// Today's focus, kept across launches until the date changes.
    struct Day: Codable, Equatable {
        var date: String
        var rounds = 0
        var seconds: TimeInterval = 0
        /// Agents that finished a turn while you were focusing.
        var agents = 0
    }

    /// Focus rounds before a long break.
    static let roundsPerCycle = 4

    @Published private(set) var run: Run?
    /// What the start button begins when nothing runs: a break after a focus that did not start one by itself.
    @Published private(set) var next: Phase = .focus
    @Published private(set) var day: Day
    /// Agents that finished during the focus under way, told when it ends.
    @Published private(set) var agentsThisRound = 0
    /// A phase ended: the one that ended, and the one that started after it (nil when nothing started by itself).
    var onEnded: (Phase, Phase?) -> Void = { _, _ in }

    private let preferences: Preferences
    private var cycle = 0
    private var timer: Timer?
    /// The minutes left at the last tick: the menu bar shows them, so it is told when they change.
    private var minutesShown = -1
    private var assertion: IOPMAssertionID = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        let today = Self.today()
        let stored = Storage.load(Day.self, from: "focus.json")
        day = stored?.date == today ? stored! : Day(date: today)
    }

    var focusing: Bool { run?.phase == .focus && run?.paused == false }

    func length(of phase: Phase) -> TimeInterval {
        TimeInterval(60 * {
            switch phase {
            case .focus: preferences.focusMinutes
            case .shortBreak: preferences.shortBreakMinutes
            case .longBreak: preferences.longBreakMinutes
            }
        }())
    }

    // MARK: Controls

    /// The shortcut and the island's main button: start, pause, or carry on.
    func toggle() {
        if let run { run.paused ? resume() : pause() } else { start(next) }
    }

    func start(_ phase: Phase) {
        let length = length(of: phase)
        if phase == .focus { agentsThisRound = 0 }
        run = Run(phase: phase, end: Date().addingTimeInterval(length), length: length)
        tick()
        updateAssertion()
    }

    func pause() {
        guard var run, !run.paused else { return }
        run.left = run.remaining()
        self.run = run
        updateAssertion()
    }

    func resume() {
        guard var run, let left = run.left else { return }
        run.end = Date().addingTimeInterval(left)
        run.left = nil
        self.run = run
        tick()
        updateAssertion()
    }

    /// Ends the phase now, counting a focus only if it ran its course.
    func skip() {
        guard let run else { return }
        finish(run, counted: false)
    }

    func stop() {
        run = nil
        next = .focus
        timer?.invalidate()
        timer = nil
        updateAssertion()
    }

    /// An agent finished a turn: counted while you focus.
    func agentFinished() {
        guard focusing else { return }
        agentsThisRound += 1
        record { $0.agents += 1 }
    }

    // MARK: Running

    private func tick() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let run = self.run, !run.paused else { return }
                guard run.remaining() > 0 else { return self.finish(run, counted: true) }
                let minutes = Int(ceil(run.remaining() / 60))
                if minutes != self.minutesShown {
                    self.minutesShown = minutes
                    self.objectWillChange.send()
                }
            }
        }
    }

    private func finish(_ run: Run, counted: Bool) {
        timer?.invalidate()
        timer = nil
        let following: Phase
        if run.phase == .focus {
            if counted {
                record { $0.rounds += 1; $0.seconds += run.length }
                cycle += 1
            }
            // Only a full fourth round earns the long break.
            following = counted && cycle % Self.roundsPerCycle == 0 ? .longBreak : .shortBreak
        } else {
            if run.phase == .longBreak { cycle = 0 }
            following = .focus
        }
        let starts = run.phase == .focus ? preferences.focusStartsBreak : preferences.breakStartsFocus
        self.run = nil
        next = following
        if starts { start(following) } else { updateAssertion() }
        if counted { onEnded(run.phase, starts ? following : nil) }
    }

    /// Focusing keeps the Mac awake, if you asked for that.
    private func updateAssertion() {
        let wanted = preferences.focusKeepsAwake && focusing
        if wanted && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Bangs 专注计时" as CFString, &assertion)
        } else if !wanted && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func record(_ change: (inout Day) -> Void) {
        let today = Self.today()
        if day.date != today { day = Day(date: today) }
        change(&day)
        Storage.save(day, to: "focus.json")
    }

    private static func today() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// "1:15" for an hour and a quarter.
    static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// The sounds the settings offer, by their system names.
    static let sounds: [(name: String, title: String)] = [("", "无"), ("Glass", "玻璃"), ("Ping", "乒"), ("Hero", "英雄"), ("Submarine", "潜水艇")]

    func playSound() {
        guard !preferences.focusSound.isEmpty else { return }
        NSSound(named: NSSound.Name(preferences.focusSound))?.play()
    }
}

/// The island's focus tab: the time left, and what to do with it.
struct FocusView: View {
    @ObservedObject var timer: FocusTimer
    @ObservedObject var preferences: Preferences

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ring(at: context.date)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let run = timer.run {
                    Text(run.paused ? "\(run.phase.title) · 已暂停" : run.phase.title)
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        PillButton(title: run.paused ? "继续" : "暂停", style: .primary) { timer.toggle() }
                        PillButton(title: run.phase.isBreak ? "跳过休息" : "跳过", style: .plain) { timer.skip() }
                        PillButton(title: "结束", style: .plain) { timer.stop() }
                    }
                } else {
                    Text(timer.next == .focus ? "准备好了就开始" : "该休息一下了")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        PillButton(title: "\(timer.next.title) \(Int(timer.length(of: timer.next) / 60)) 分钟", style: .primary) { timer.start(timer.next) }
                        if timer.next != .focus {
                            PillButton(title: "跳过，继续专注", style: .plain) { timer.start(.focus) }
                        }
                    }
                }
                Text(summary).font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let day = timer.day
        var parts = ["今天 \(day.rounds) 轮", "共 \(FocusTimer.hours(day.seconds))"]
        if day.agents > 0 { parts.append("期间 \(day.agents) 个 Agent 跑完") }
        return parts.joined(separator: " · ")
    }

    private func ring(at now: Date) -> some View {
        let run = timer.run
        let length = run?.length ?? timer.length(of: timer.next)
        let left = run?.remaining(at: now) ?? length
        let tint = (run?.phase ?? timer.next).isBreak ? Palette.ok : Palette.meeting
        return ZStack {
            Circle().stroke(Palette.wash(0.12), lineWidth: 5)
            Circle().trim(from: 0, to: max(0, min(1, left / max(length, 1))))
                .stroke(tint.opacity(run?.paused == true ? 0.5 : 1), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: left)
            Text(NotchStatus.clock(left)).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.ink)
        }
        .frame(width: 78, height: 78)
    }
}

/// The island as a phase ends: what ended, what the agents did meanwhile, and what comes next.
struct FocusEndedView: View {
    let ended: FocusTimer.Phase
    let started: FocusTimer.Phase?
    let agents: Int
    @ObservedObject var model: NotchModel

    var body: some View {
        let timer = model.toolbox.focus
        VStack(alignment: .leading, spacing: 0) {
            Text(ended == .focus ? "专注结束，休息一下" : "休息结束").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 6)
            HStack(spacing: 6) {
                Spacer()
                if let started {
                    PillButton(title: started.isBreak ? "跳过休息" : "结束", style: .plain) {
                        started.isBreak ? timer.skip() : timer.stop()
                        model.go(.collapsed)
                    }
                    if agents > 0 {
                        PillButton(title: "看看会话", style: .primary) { model.open(.sessions) }
                    }
                } else {
                    PillButton(title: "稍后", style: .plain) { model.go(.collapsed) }
                    PillButton(title: "开始\(timer.next.title)", style: .primary) {
                        timer.start(timer.next)
                        model.go(.collapsed)
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let started { parts.append("\(started.title) \(Int(model.toolbox.focus.length(of: started) / 60)) 分钟已经开始。") }
        if ended == .focus && agents > 0 { parts.append("专注期间有 \(agents) 个 Agent 跑完了。") }
        if parts.isEmpty { parts.append(ended == .focus ? "今天已完成 \(model.toolbox.focus.day.rounds) 轮。" : "准备好了就开始下一轮。") }
        return parts.joined(separator: "")
    }
}
