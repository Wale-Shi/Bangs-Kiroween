import BangsCore
import XCTest
@testable import Bangs

@MainActor
final class HistoryCostProbe: XCTestCase {
    func testHistoryCost() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANGS_BENCH"] == "1")
        func resident() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            return Double(info.resident_size) / 1e6
        }
        let before = resident()
        let history = SessionHistory(preferences: Preferences())
        var start = Date()
        history.refresh(force: true)
        while history.sessions.isEmpty, Date().timeIntervalSince(start) < 120 { try await Task.sleep(nanoseconds: 50_000_000) }
        let first = Date().timeIntervalSince(start)
        let text = history.sessions.reduce(0) { $0 + $1.prompts.reduce(0) { $0 + $1.utf8.count } + $1.texts.reduce(0) { $0 + $1.utf8.count } }
        let hay = history.searchableIndex.reduce(0) { $0 + $1.haystack.count }
        print(String(format: "PROBE sessions=%d first read %.2fs text=%.1fMB haystack=%.1fMB resident +%.0fMB", history.sessions.count, first, Double(text) / 1e6, Double(hay) / 1e6, resident() - before))
        for harness in Harness.allCases {
            let mine = history.sessions.filter { $0.harness == harness }
            guard let latest = mine.first else { continue }
            print("PROBE \(harness.rawValue): \(mine.count) sessions, searchable \(history.count(of: harness)); latest \(latest.sessionId) in \(latest.cwd) \"\(latest.shownTitle.prefix(40))\" \(latest.prompts.count) prompts \(latest.texts.count) texts")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (harness, file) in HistoryReader.files(home: home).map({ ($0.1, $0.0) }) where [.codebuddy, .omp, .pi, .gemini].contains(harness) {
            if let tail = Transcript.tail(of: file.path, bytes: 256 * 1024), let context = Usage.context(in: tail, harness: harness) {
                print("PROBE context \(harness.rawValue) \(file.lastPathComponent.prefix(30)): \(Usage.tokens(context.tokens)) window \(context.window.map(Usage.tokens) ?? "?")")
            }
        }
        // A refresh with nothing changed.
        let count = history.sessions.count
        start = Date()
        history.refresh(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        while Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if history.progress == nil, Mirror(reflecting: history).children.first(where: { $0.label == "refreshing" })?.value as? Bool == false { break }
        }
        print(String(format: "PROBE unchanged refresh %.2fs (%d sessions)", Date().timeIntervalSince(start), count))
        start = Date()
        for query in ["登录", "swift build", "a"] { _ = HistorySearch.search(history.searchableIndex, for: query) }
        print(String(format: "PROBE 3 searches %.1f ms", Date().timeIntervalSince(start) * 1000))
    }
}
