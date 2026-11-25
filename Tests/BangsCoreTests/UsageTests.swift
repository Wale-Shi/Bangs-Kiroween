import XCTest
@testable import BangsCore

final class UsageTests: XCTestCase {
    /// Codex's log, as it writes it: the latest token_count has the plan's limits and the context.
    func testCodexLimitsAndContext() {
        let tail = """
        {"timestamp":"2026-11-19T16:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":80.0,"window_minutes":10080,"resets_at":1795314539}}}}
        {"timestamp":"2026-11-19T16:12:16.069Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":78652,"output_tokens":171},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":84.0,"window_minutes":10080,"resets_at":1795314539},"secondary":{"used_percent":12.5,"window_minutes":300,"resets_at":1795200000},"plan_type":"prolite"}}}
        {"timestamp":"2026-11-19T16:12:17.000Z","type":"response_item","payload":{"type":"message"}}
        """
        let (limits, context) = Usage.codex(in: tail)
        XCTAssertEqual(limits?.windows.map(\.minutes), [300, 10080], "shortest first")
        XCTAssertEqual(limits?.windows.map(\.used), [0.125, 0.84])
        XCTAssertEqual(limits?.windows.last?.resetsAt, Date(timeIntervalSince1970: 1795314539))
        XCTAssertEqual(limits?.windows.map(\.name), ["5 小时", "本周"])
        XCTAssertEqual(context, ContextFill(tokens: 78652, window: 258400))
        XCTAssertEqual(context?.fraction ?? 0, 0.3044, accuracy: 0.001)
    }

    /// A model with limits of its own reports them under its id: those are not the plan's.
    func testCodexOtherLimitsAreSkipped() {
        let tail = """
        {"timestamp":"2026-11-19T16:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":30,"window_minutes":300}}}}
        {"timestamp":"2026-11-19T16:11:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_other","primary":{"used_percent":99,"window_minutes":300}}}}
        """
        XCTAssertEqual(Usage.codex(in: tail).limits?.windows.first?.used, 0.3)
        XCTAssertNil(Usage.codex(in: #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#).limits)
    }

    func testClaudeContextFromTheLatestMainReply() {
        let tail = """
        {"type":"assistant","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":2143,"cache_read_input_tokens":98383,"output_tokens":308}}}
        {"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":5,"cache_read_input_tokens":1000}}}
        {"type":"user","message":{"content":"ok"}}
        """
        XCTAssertEqual(Usage.claudeContext(in: tail), ContextFill(tokens: 100_528, window: nil))
        XCTAssertNil(Usage.claudeContext(in: #"{"type":"user"}"#))
    }

    func testStatusLine() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let payload: [String: Any] = [
            "session_id": "abc",
            "rate_limits": ["five_hour": ["used_percentage": 23, "resets_at": 1_795_010_000], "seven_day": ["used_percentage": 41.5, "resets_at": "2026-11-24T08:00:00Z"]],
            "context_window": ["total_input_tokens": 150_000, "context_window_size": 1_000_000, "used_percentage": 15],
        ]
        let (limits, context) = Usage.statusLine(payload, at: now)
        XCTAssertEqual(limits?.windows.map(\.used), [0.23, 0.415])
        XCTAssertEqual(limits?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_795_010_000))
        XCTAssertNotNil(limits?.windows.last?.resetsAt)
        XCTAssertEqual(limits?.updated, now)
        XCTAssertEqual(context, ContextFill(tokens: 150_000, window: 1_000_000))
        // API key sessions have no plan limits.
        XCTAssertNil(Usage.statusLine(["context_window": ["context_window_size": 200_000, "used_percentage": 50]]).limits)
        XCTAssertEqual(Usage.statusLine(["context_window": ["context_window_size": 200_000, "used_percentage": 50]]).context?.tokens, 100_000)
    }

    /// A window whose reset has passed starts from nothing, though the CLI has not reported since.
    func testResetWindowsStartAgain() {
        let reset = Date(timeIntervalSince1970: 1000)
        let limits = Limits(windows: [Limits.Window(minutes: 300, used: 0.9, resetsAt: reset), Limits.Window(minutes: 10080, used: 0.5, resetsAt: Date(timeIntervalSince1970: 9000))], updated: .distantPast)
        XCTAssertEqual(limits.current(at: Date(timeIntervalSince1970: 500)).map(\.used), [0.9, 0.5])
        XCTAssertEqual(limits.current(at: Date(timeIntervalSince1970: 2000)).map(\.used), [0, 0.5])
        XCTAssertEqual(limits.tightest(at: Date(timeIntervalSince1970: 2000))?.minutes, 10080)
    }

    func testTokens() {
        XCTAssertEqual(Usage.tokens(812), "812")
        XCTAssertEqual(Usage.tokens(98_383), "98k")
        XCTAssertEqual(Usage.tokens(1_200_000), "1.2M")
    }
}

final class StatusLineRelayTests: XCTestCase {
    private var home: URL!
    private let binary = "/Applications/Bangs.app/Contents/Helpers/bangs-hook"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))) as? [String: Any] ?? [:]
    }

    /// Your own status line is kept, run by the relay, and put back when it is turned off; nothing else changes.
    func testKeepsAndRestoresYourStatusLine() throws {
        let mine: [String: Any] = ["type": "command", "command": "~/.claude/statusline.sh", "padding": 1]
        let original: [String: Any] = ["model": "opus", "statusLine": mine, "hooks": ["Stop": []]]
        try JSONSerialization.data(withJSONObject: original).write(to: home.appendingPathComponent(".claude/settings.json"))
        let relay = StatusLineRelay(hookBinary: binary, user: home)
        XCTAssertEqual(relay.state(), .off)

        try relay.install()
        XCTAssertEqual(relay.state(), .on)
        let line = try XCTUnwrap(try settings()["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "'\(binary)' claude statusline")
        XCTAssertEqual(line["padding"] as? Int, 1)
        XCTAssertEqual(try settings()["model"] as? String, "opus")
        XCTAssertEqual(StatusLineRelay.originalCommand(user: home), "~/.claude/statusline.sh")

        // Turned on again (or repaired): what is kept is still yours, not the relay.
        try relay.install()
        XCTAssertEqual(StatusLineRelay.originalCommand(user: home), "~/.claude/statusline.sh")

        try relay.uninstall()
        XCTAssertEqual(relay.state(), .off)
        XCTAssertEqual(try settings()["statusLine"] as? NSDictionary, mine as NSDictionary)
        XCTAssertNil(StatusLineRelay.originalCommand(user: home))
    }

    func testWithoutAStatusLineNoneIsLeft() throws {
        let relay = StatusLineRelay(hookBinary: binary, user: home)
        try relay.install()
        XCTAssertNil(StatusLineRelay.originalCommand(user: home))
        try relay.uninstall()
        XCTAssertNil(try settings()["statusLine"])
    }

    func testMovedAppIsRepaired() throws {
        try StatusLineRelay(hookBinary: "/old/bangs-hook", user: home).install()
        let relay = StatusLineRelay(hookBinary: binary, user: home)
        XCTAssertEqual(relay.state(), .outdated)
        XCTAssertTrue(try relay.repair())
        XCTAssertEqual(relay.state(), .on)
        XCTAssertFalse(try relay.repair())
        XCTAssertEqual(StatusLineRelay(hookBinary: binary, user: home.appendingPathComponent("nobody")).state(), .notDetected)
    }
}
