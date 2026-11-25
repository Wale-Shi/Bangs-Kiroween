import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idling to sleep (the display may still turn off), for a while, until the agents finish, or until turned off.
/// macOS still sleeps a closed MacBook on battery without an external display; that takes an admin setting Bangs does not change.
@MainActor
final class KeepAwake: ObservableObject {
    enum Mode: Equatable {
        case off
        case until(Date)
        case agents
        case forever
    }

    @Published private(set) var mode: Mode = .off
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    var active: Bool { mode != .off }

    func set(_ mode: Mode) {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        timer?.invalidate()
        timer = nil
        self.mode = mode
        guard mode != .off else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Bangs 防休眠" as CFString, &assertion)
        // Ticks every 30 s, for the remaining time shown in the island and to end on time.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .until(let end) = self.mode, end <= Date() { self.set(.off) } else { self.objectWillChange.send() }
            }
        }
    }

    /// For "until the agents finish": ends once no session is working.
    func agentsChanged(working: Bool) {
        if mode == .agents && !working { set(.off) }
    }

    /// "0:42" left, "Agent" or "∞", for the island.
    var label: String {
        switch mode {
        case .off: return ""
        case .agents: return "Agent"
        case .forever: return "∞"
        case .until(let end):
            let minutes = max(0, Int(ceil(end.timeIntervalSinceNow / 60)))
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
    }
}
