import BangsCore
import XCTest
@testable import Bangs

final class ApprovalPreviewTests: XCTestCase {
    /// The hooks' ends of each request's connection, kept open until the test is over so answering never writes to a
    /// closed socket. Each request has its own: answering one closes its end.
    private var hooks: [Int32] = []

    override func tearDown() { hooks.forEach { close($0) } }

    @MainActor private func ask(_ store: SessionStore, _ tool: String, _ input: [String: Any], cwd: String = "/Users/me/code/app") {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        hooks.append(pair[1])
        store.receive(HookEnvelope(harness: .claude, native: "PermissionRequest", pid: getpid(),
                                   payload: ["session_id": "s", "cwd": cwd, "tool_name": tool, "tool_input": input]),
                      reply: PendingReply(fd: pair[0], onHangUp: {}))
    }

    /// The risk is there as soon as the request is, before any diff: the keyboard must never see it unflagged.
    @MainActor func testRiskArrivesWithTheRequest() {
        let store = SessionStore()
        ask(store, "Bash", ["command": "git push --force origin main"])
        XCTAssertEqual(store.approvals.first?.risk?.level, .danger)
        XCTAssertEqual(store.approvals.first?.summary, "git push --force origin main")
    }

    /// The diff is worked out off the main thread and lands on the request's card a moment later.
    @MainActor func testDiffArrivesOnTheCard() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "one\ntwo\nthree\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let store = SessionStore()
        ask(store, "Edit", ["file_path": folder.appendingPathComponent("a.txt").path, "old_string": "two", "new_string": "2"], cwd: folder.path)
        XCTAssertNil(store.approvals.first?.risk, "inside the session's folder")
        let arrived = expectation(description: "diff")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { if store.approvals.first?.changes.isEmpty == false { arrived.fulfill() } }
        }
        wait(for: [arrived], timeout: 2)
        poll.invalidate()
        let change = try XCTUnwrap(store.approvals.first?.changes.first)
        XCTAssertEqual(change.path, "a.txt")
        XCTAssertEqual(change.firstLine, 2)
        XCTAssertEqual(change.lines.map(\.kind), [.removed, .added])
    }

    /// CLIs that ask in the terminal only say that one does: the card shows (and flags) the call their PreToolUse reported.
    @MainActor func testTerminalPromptShowsTheCallItIsAbout() {
        let store = SessionStore()
        let payload: [String: Any] = ["session_id": "g", "cwd": "/Users/me/code/app"]
        store.receive(HookEnvelope(harness: .gemini, native: "BeforeTool", pid: getpid(),
                                   payload: payload.merging(["tool_name": "run_shell_command", "tool_input": ["command": "rm -rf ../shared"]]) { $1 }), reply: nil)
        store.receive(HookEnvelope(harness: .gemini, native: "Notification", pid: getpid(),
                                   payload: payload.merging(["notification_type": "permission_prompt", "message": "Action required"]) { $1 }), reply: nil)
        XCTAssertEqual(store.approvals.first?.summary, "rm -rf ../shared")
        XCTAssertEqual(store.approvals.first?.risk?.level, .danger)
        XCTAssertFalse(store.approvals.first?.answerable ?? true)
    }

    /// ⌥⌘↩ answers only what the card shows, and never allows something flagged as dangerous.
    @MainActor func testShortcutsAnswerOnlyWhatIsShown() {
        let preferences = Preferences()
        let store = SessionStore()
        let model = NotchModel(store: store, preferences: preferences, toolbox: Toolbox(preferences: preferences),
                               geometry: NotchGeometry(notchWidth: 185, height: 32, screen: NSScreen.screens[0]))
        XCTAssertFalse(model.answerFromKeyboard(allowing: true), "nothing waiting")
        ask(store, "Bash", ["command": "git push -f"])
        let opened = expectation(description: "the card opens")
        DispatchQueue.main.async { DispatchQueue.main.async { opened.fulfill() } }
        wait(for: [opened], timeout: 2)
        XCTAssertEqual(model.mode, .approval)
        XCTAssertFalse(model.answerFromKeyboard(allowing: true), "a dangerous request takes a click")
        XCTAssertEqual(store.approvals.count, 1)
        XCTAssertTrue(model.answerFromKeyboard(allowing: false), "denying it is fine")
        XCTAssertTrue(store.approvals.isEmpty)

        ask(store, "Bash", ["command": "swift test"])
        model.go(.expanded)
        XCTAssertFalse(model.answerFromKeyboard(allowing: true), "hidden behind the open toolbox")
        model.go(.approval)
        XCTAssertTrue(model.answerFromKeyboard(allowing: true))
        XCTAssertTrue(store.approvals.isEmpty)
    }
}
