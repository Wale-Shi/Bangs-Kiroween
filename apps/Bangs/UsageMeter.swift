import BangsCore
import Foundation

/// The plans' limits, per CLI, as each last reported them. Kept on disk so they show again after a restart, until the
/// CLI next reports (a window whose reset has passed shows as starting over).
@MainActor
final class UsageMeter: ObservableObject {
    @Published private(set) var limits: [Harness: Limits] = [:]
    private let persisted: Bool
    private static let file = "limits.json"
    /// Limits older than this are left out: the CLI has not been used in a while, and they say little now.
    static let stale: TimeInterval = 8 * 86400

    init(persisted: Bool) {
        self.persisted = persisted
        guard persisted, let stored = Storage.load([String: Limits].self, from: Self.file) else { return }
        limits = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Harness(rawValue: key).map { ($0, value) } })
    }

    /// Only a change redraws anything or touches the disk: Claude Code's status line reports several times a minute.
    func report(_ harness: Harness, _ new: Limits) {
        if let old = limits[harness], old.windows == new.windows, new.updated.timeIntervalSince(old.updated) < 600 { return }
        limits[harness] = new
        guard persisted else { return }
        Storage.save(Dictionary(uniqueKeysWithValues: limits.map { ($0.key.rawValue, $0.value) }), to: Self.file)
    }

    /// The CLIs with limits worth showing at `now`, in the order of `Harness`.
    func shown(at now: Date = Date()) -> [(harness: Harness, windows: [Limits.Window])] {
        Harness.allCases.compactMap { harness in
            guard let limits = limits[harness], now.timeIntervalSince(limits.updated) < Self.stale else { return nil }
            let windows = limits.current(at: now)
            return windows.isEmpty ? nil : (harness, windows)
        }
    }
}
