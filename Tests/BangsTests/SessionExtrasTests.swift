import BangsCore
import XCTest
@testable import Bangs

final class SessionExtrasTests: XCTestCase {
    /// The hooks' ends of the requests' connections, read for the answers and closed when the test is over.
    private var hooks: [Int32] = []
    private var folder: URL?

    override func tearDown() {
        hooks.forEach { close($0) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Sends a permission request and returns the hook's end, where the answer arrives.
    @MainActor @discardableResult
    private func ask(_ store: SessionStore, _ command: String, session: String = "s") -> Int32 {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        hooks.append(pair[1])
        store.receive(HookEnvelope(harness: .claude, native: "PermissionRequest", pid: getpid(),
                                   payload: ["session_id": session, "cwd": "/Users/me/code/app", "tool_name": "Bash", "tool_input": ["command": command]]),
                      reply: PendingReply(fd: pair[0], onHangUp: {}))
        return pair[1]
    }

    private func answer(on fd: Int32) -> PermissionReply? { UnixSocket.readLine(fd).flatMap(PermissionReply.init(line:)) }

    /// "本会话都允许" answers this request and those like it, now and later, in that session only; anything flagged
    /// still asks, and clearing the rules makes it ask again.
    @MainActor func testAllowingForTheSession() {
        let store = SessionStore()
        store.allowsForSession = true
        let first = ask(store, "swift build 2>&1 | tail -5")
        let waiting = ask(store, "swift build -c release")
        let other = ask(store, "swift test")
        XCTAssertEqual(store.approvals.count, 3)
        XCTAssertEqual(store.approvals[0].sessionRule?.title, "运行 swift build、tail")

        store.allowForSession(store.approvals[0])
        XCTAssertEqual(answer(on: first), .allow)
        XCTAssertEqual(answer(on: waiting), .allow, "one waiting already that the rule covers")
        XCTAssertEqual(store.approvals.map(\.summary), ["swift test"])
        store.answer(store.approvals[0], with: .deny)
        XCTAssertEqual(answer(on: other), .deny)

        let later = ask(store, "swift build")
        XCTAssertEqual(answer(on: later), .allow)
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertTrue(store.sessions[0].activity.hasPrefix("本会话已允许"))

        ask(store, "swift build && rm -rf /")
        XCTAssertEqual(store.approvals.count, 1, "flagged: asks")
        store.answer(store.approvals[0], with: .deny)
        ask(store, "swift build", session: "another")
        XCTAssertEqual(store.approvals.count, 1, "another session: asks")
        store.answer(store.approvals[0], with: .deny)

        store.clearRules(of: store.sessions.first { $0.sessionId == "s" }!)
        ask(store, "swift build")
        XCTAssertEqual(store.approvals.count, 1, "rules cleared: asks again")
        store.answer(store.approvals[0], with: .deny)

        // Turned off in the settings, rules given before do nothing.
        ask(store, "ls")
        store.allowForSession(store.approvals[0])
        store.allowsForSession = false
        ask(store, "ls -la")
        XCTAssertEqual(store.approvals.count, 1)
    }

    /// Claude Code's status line, relayed, fills the meter and the session's context; it never makes a session.
    @MainActor func testStatusLine() {
        let store = SessionStore()
        store.readsUsage = true
        let status: [String: Any] = ["session_id": "s", "cwd": "/Users/me/code/app",
                                     "rate_limits": ["five_hour": ["used_percentage": 42, "resets_at": 4_000_000_000]],
                                     "context_window": ["total_input_tokens": 50_000, "context_window_size": 200_000]]
        store.receive(HookEnvelope(harness: .claude, native: StatusLineRelay.event, pid: getpid(), payload: status), reply: nil)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.meter.limits[.claude]?.windows.first?.used, 0.42)

        store.receive(HookEnvelope(harness: .claude, native: "UserPromptSubmit", pid: getpid(), payload: ["session_id": "s", "cwd": "/Users/me/code/app", "prompt": "hi"]), reply: nil)
        store.receive(HookEnvelope(harness: .claude, native: StatusLineRelay.event, pid: getpid(), payload: status), reply: nil)
        XCTAssertEqual(store.sessions.first?.context?.fraction, 0.25)
        XCTAssertEqual(store.meter.shown().first?.harness, .claude)
    }

    /// A turn in a git checkout shows what it changed once it ends.
    @MainActor func testTurnChanges() throws {
        try XCTSkipUnless(Git.available, "no git on this Mac")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-turn-\(UUID().uuidString)")
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "first"]] {
            XCTAssertNotNil(Git.run(arguments, in: folder.path))
        }
        let store = SessionStore()
        store.tracksChanges = true
        store.watching = { _ in true }
        let payload: [String: Any] = ["session_id": "t", "cwd": folder.path]
        store.receive(HookEnvelope(harness: .claude, native: "UserPromptSubmit", pid: getpid(), payload: payload.merging(["prompt": "edit"]) { $1 }), reply: nil)
        // Wait for the start to be noted before writing, as an agent's first edit comes well after the prompt.
        let started = expectation(description: "start noted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { started.fulfill() }
        wait(for: [started], timeout: 3)
        try "one\ntwo\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        store.receive(HookEnvelope(harness: .claude, native: "Stop", pid: getpid(), payload: payload), reply: nil)

        let arrived = expectation(description: "changes")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { if store.sessions.first?.changes != nil { arrived.fulfill() } }
        }
        wait(for: [arrived], timeout: 5)
        poll.invalidate()
        XCTAssertEqual(store.sessions.first?.changes?.summary, "+1 −0 · 1 个文件")

        // The next turn starts clean.
        store.receive(HookEnvelope(harness: .claude, native: "UserPromptSubmit", pid: getpid(), payload: payload.merging(["prompt": "more"]) { $1 }), reply: nil)
        XCTAssertNil(store.sessions.first?.changes)
    }

    func testHandoffText() {
        XCTAssertEqual(Handoff.text(for: .text("hello")), "hello")
        XCTAssertEqual(Handoff.text(for: .files([URL(fileURLWithPath: "/Users/me/Shots/截图 1 (2).png"), URL(fileURLWithPath: "/tmp/a.txt")])),
                       #"/Users/me/Shots/截图\ 1\ \(2\).png /tmp/a.txt "#)
    }
}
