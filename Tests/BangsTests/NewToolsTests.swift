import AppKit
import XCTest
@testable import Bangs

final class TransformTests: XCTestCase {
    private let all = Set(Transform.Kind.allCases)

    private func titles(_ text: String, utc: Bool = true) -> [String] {
        Transform.offers(for: text, kinds: all, utc: utc).map(\.title)
    }

    private func result(_ text: String, _ title: String, utc: Bool = true) -> String? {
        Transform.offers(for: text, kinds: all, utc: utc).first { $0.title == title }?.result
    }

    func testJSONKeepsKeyOrderAndEmptyContainers() {
        let compact = #"{"z":1,"a":[1,2],"empty":{},"list":[],"s":"a, b: {c}"}"#
        XCTAssertEqual(result(compact, "格式化"), """
        {
          "z": 1,
          "a": [
            1,
            2
          ],
          "empty": {},
          "list": [],
          "s": "a, b: {c}"
        }
        """)
        XCTAssertEqual(result(result(compact, "格式化")!, "压缩"), compact)
        XCTAssertFalse(titles(compact).contains("压缩"), "already compact")
        XCTAssertFalse(titles(#"{"broken":"#).contains { $0 == "格式化" || $0 == "压缩" }, "invalid JSON is left alone")
    }

    func testTimestampsBothWays() {
        XCTAssertEqual(result("1762311600", "→ 2025-11-05 03:00:00 UTC"), "2025-11-05 03:00:00 UTC")
        XCTAssertEqual(result("1762311600123", "→ 2025-11-05 03:00:00.123 UTC"), "2025-11-05 03:00:00.123 UTC")
        XCTAssertEqual(result("2025-11-05 03:00:00", "→ 1762311600"), "1762311600")
        XCTAssertEqual(result("2025-11-05T03:00:00Z", "→ 1762311600"), "1762311600")
        // A phone number or an order number is just a number.
        XCTAssertFalse(titles("13812345678").contains { $0.hasPrefix("→") })
        XCTAssertFalse(titles("1234567890123456").contains { $0.hasPrefix("→") })
    }

    func testBase64OnlyDecodesToText() {
        XCTAssertEqual(result("aGVsbG8gYmFuZ3M=", "Base64 解码"), "hello bangs")
        XCTAssertEqual(result("5YiY5rW3", "Base64 解码"), "刘海")
        XCTAssertNil(result("HelloWorld", "Base64 解码"), "words decode to bytes that are not text")
        XCTAssertEqual(result("刘海", "Base64 编码"), "5YiY5rW3")
    }

    func testURLEncoding() {
        XCTAssertEqual(result("%E5%88%98%E6%B5%B7", "URL 解码"), "刘海")
        XCTAssertEqual(result("a b&c", "URL 编码"), "a%20b%26c")
        XCTAssertEqual(result("https://example.com/搜索?q=a b", "URL 编码"), "https://example.com/%E6%90%9C%E7%B4%A2?q=a%20b")
    }

    func testNamingStyles() {
        XCTAssertEqual(Transform.words(of: "userName"), ["user", "name"])
        XCTAssertEqual(Transform.words(of: "HTTPServerError"), ["http", "server", "error"])
        XCTAssertEqual(Transform.words(of: "user_name-id"), ["user", "name", "id"])
        XCTAssertNil(Transform.words(of: "hello"), "one word has no style to change")
        XCTAssertNil(Transform.words(of: "hello world"))
        let offers = titles("user_name")
        XCTAssertTrue(offers.contains("userName") && offers.contains("UserName") && offers.contains("user-name"))
        XCTAssertFalse(offers.contains("user_name"), "the style it already has is not offered")
    }

    func testOnlyChosenKindsAndMostSpecificFirst() {
        let offers = Transform.offers(for: #"{"a":1}"#, kinds: [.json], utc: true).map(\.title)
        XCTAssertEqual(offers, ["格式化"])
        XCTAssertTrue(Transform.offers(for: "1762311600", kinds: [.naming], utc: true).isEmpty)
        XCTAssertEqual(titles("1762311600").first, "→ 2025-11-05 03:00:00 UTC")
    }
}

final class TextRecognitionTests: XCTestCase {
    private func line(_ text: String, x: CGFloat = 0.05, y: CGFloat, width: CGFloat = 0.9) -> TextRecognition.Line {
        TextRecognition.Line(text: text, box: CGRect(x: x, y: y, width: width, height: 0.05))
    }

    func testWrappedLinesJoinIntoAParagraph() {
        let lines = [
            line("Bangs lives in the notch and keeps an eye on every", y: 0.1),
            line("coding agent on your Mac.", y: 0.16, width: 0.4),
            line("刘海里能看到每一个正在跑的", y: 0.3),
            line("编码 Agent。", y: 0.36, width: 0.2),
        ]
        XCTAssertEqual(TextRecognition.text(of: lines, joinLines: true),
                       "Bangs lives in the notch and keeps an eye on every coding agent on your Mac.\n刘海里能看到每一个正在跑的编码 Agent。")
        XCTAssertEqual(TextRecognition.text(of: lines, joinLines: false).split(separator: "\n").count, 4)
    }

    func testShortLinesKeepTheirBreaks() {
        // Code: no line reaches the block's right edge except the longest, and it ends the block.
        let lines = [
            line("func greet() {", y: 0.1, width: 0.3),
            line("print(\"hi\")", x: 0.1, y: 0.16, width: 0.25),
            line("}", y: 0.22, width: 0.02),
        ]
        XCTAssertEqual(TextRecognition.text(of: lines, joinLines: true), "func greet() {\nprint(\"hi\")\n}")
    }

    func testRowsReadLeftToRight() {
        let lines = [
            line("值 2", x: 0.5, y: 0.31, width: 0.2),
            line("名称", y: 0.1, width: 0.2),
            line("键 2", y: 0.3, width: 0.2),
            line("值", x: 0.5, y: 0.11, width: 0.2),
        ]
        XCTAssertEqual(TextRecognition.reading(lines).map(\.text), ["名称", "值", "键 2", "值 2"])
    }

    func testLinks() {
        XCTAssertEqual(TextRecognition.link(in: " https://github.com/Wale-Shi/Bangs \n")?.absoluteString, "https://github.com/Wale-Shi/Bangs")
        XCTAssertEqual(TextRecognition.link(in: "www.apple.com")?.host, "www.apple.com")
        XCTAssertNil(TextRecognition.link(in: "notes.txt"))
        XCTAssertNil(TextRecognition.link(in: "see https://a.com and https://b.com"))
    }

    /// The real recognizer, on text drawn the way a screen would show it.
    func testRecognizesChineseAndEnglish() async throws {
        let size = NSSize(width: 900, height: 140)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]
            ("刘海里的编码助手" as NSString).draw(at: NSPoint(x: 30, y: 80), withAttributes: attributes)
            ("Bangs watches your agents" as NSString).draw(at: NSPoint(x: 30, y: 20), withAttributes: attributes)
            return true
        }
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let text = try await TextRecognition.recognize(cgImage, language: .auto, joinLines: true)
        XCTAssertTrue(text.contains("刘海里的编码助手"), text)
        XCTAssertTrue(text.contains("Bangs watches your agents"), text)
    }
}

/// Tests that touch Bangs' storage keep it in a folder of their own, never your history or today's focus.
enum TestData {
    static let isolate: Void = {
        Storage.custom = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-tests-\(getpid())")
    }()
}

@MainActor
final class FocusTimerTests: XCTestCase {
    override class func setUp() { TestData.isolate }

    func testPauseKeepsTheTimeLeftAndSkipDoesNotCount() {
        let timer = FocusTimer(preferences: Preferences())
        timer.start(.focus)
        XCTAssertTrue(timer.focusing)
        timer.pause()
        let left = timer.run?.remaining()
        XCTAssertFalse(timer.focusing)
        XCTAssertEqual(timer.run?.remaining(at: Date().addingTimeInterval(600)), left, "a paused run does not count down")
        timer.resume()
        XCTAssertTrue(timer.focusing)
        let rounds = timer.day.rounds
        timer.skip()
        XCTAssertEqual(timer.day.rounds, rounds, "a skipped focus is not a round")
        timer.stop()
        XCTAssertNil(timer.run)
    }

    func testSkippingNeverEarnsTheLongBreak() {
        let preferences = Preferences()
        preferences.focusStartsBreak = false
        defer { preferences.focusStartsBreak = true }
        let timer = FocusTimer(preferences: preferences)
        for _ in 0..<FocusTimer.roundsPerCycle {
            timer.start(.focus)
            timer.skip()
            XCTAssertEqual(timer.next, .shortBreak)
        }
        timer.stop()
    }

    func testAgentsCountOnlyWhileFocusing() {
        let timer = FocusTimer(preferences: Preferences())
        timer.agentFinished()
        XCTAssertEqual(timer.agentsThisRound, 0)
        timer.start(.focus)
        timer.agentFinished()
        timer.agentFinished()
        XCTAssertEqual(timer.agentsThisRound, 2)
        timer.stop()
    }
}

@MainActor
final class CaptureFocusTests: XCTestCase {
    /// A capture leaves the settings window where it was, so it can be in the screenshot; the island and the
    /// overlays, borderless, never are.
    func testCapturesKeepTheSettingsWindowAndNotTheFloatingOnes() {
        _ = NSApplication.shared
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let floating = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for window in [settings, floating] { window.isReleasedWhenClosed = false; window.orderFront(nil) }
        defer { for window in [settings, floating] { window.orderOut(nil) } }

        let kept = Capture.keptWindows()
        XCTAssertTrue(kept.contains(CGWindowID(settings.windowNumber)))
        XCTAssertFalse(kept.contains(CGWindowID(floating.windowNumber)))

        let focus = CaptureFocus()
        focus.take()
        XCTAssertTrue(settings.isVisible, "not put away: it may be what you are capturing")
        focus.restore()
        XCTAssertTrue(settings.isVisible)
    }
}

@MainActor
final class SessionHistoryTests: XCTestCase {
    override class func setUp() { TestData.isolate }

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    private func claudeLines(_ id: String) -> String {
        line(["type": "user", "sessionId": id, "cwd": "/Users/me/Bangs", "gitBranch": "main", "timestamp": "2026-11-05T01:00:00.000Z",
              "message": ["role": "user", "content": "给刘海加一个会话搜索"]])
        + line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>ignored</local-command-caveat>"]])
        + line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "huge output"]]]])
        + line(["type": "assistant", "cwd": "/Users/me/Bangs", "timestamp": "2026-11-05T01:00:05.000Z",
                "message": ["role": "assistant", "content": [["type": "text", "text": "好的，先读一下 SessionStore。"],
                                                             ["type": "tool_use", "name": "Bash", "input": ["command": "swift build"]]]]])
        + line(["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "sub-agent chatter"]]]])
        + line(["type": "ai-title", "aiTitle": "会话搜索", "sessionId": id])
        + line(["type": "api-request-blob", "message": ["role": "user", "content": "not a prompt"]])
    }

    private func codexLines(_ id: String, source: String = "user") -> String {
        line(["type": "session_meta", "timestamp": "2026-11-04T08:00:00.000Z",
              "payload": ["id": id, "cwd": "/Users/me/Muster", "thread_source": source, "base_instructions": "…"]])
        + line(["type": "response_item", "timestamp": "2026-11-04T08:00:01.000Z",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]])
        + line(["type": "response_item", "timestamp": "2026-11-04T08:00:02.000Z",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "登录测试在 CI 上偶尔失败"]]]])
        + line(["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "arguments": #"{"cmd":"npm test -- login"}"#]])
        + line(["type": "response_item", "timestamp": "2026-11-04T08:03:00.000Z",
                "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "是超时太短，改成 30 秒了"]]]])
    }

    func testReadingClaudeAndCodexRecords() {
        var claude = PastSession(harness: .claude, sessionId: "c1")
        HistoryReader.readClaude(claudeLines("c1").split(separator: "\n").map { Data($0.utf8) }, into: &claude)
        XCTAssertEqual(claude.prompts, ["给刘海加一个会话搜索"])
        XCTAssertEqual(claude.texts, ["好的，先读一下 SessionStore。", "$ swift build"])
        XCTAssertEqual(claude.title, "会话搜索")
        XCTAssertEqual(claude.project, "Bangs")
        XCTAssertEqual(claude.branch, "main")
        XCTAssertEqual(claude.updated, ISO8601DateFormatter().date(from: "2026-11-05T01:00:05Z"))

        var codex = PastSession(harness: .codex, sessionId: "")
        HistoryReader.readCodex(codexLines("x1").split(separator: "\n").map { Data($0.utf8) }, into: &codex)
        XCTAssertEqual(codex.sessionId, "x1")
        XCTAssertEqual(codex.prompts, ["登录测试在 CI 上偶尔失败"])
        XCTAssertEqual(codex.texts, ["$ npm test -- login", "是超时太短，改成 30 秒了"])
        XCTAssertFalse(codex.isInternal)
        XCTAssertEqual(codex.resumeCommand, "cd /Users/me/Muster && codex resume x1")

        var guardian = PastSession(harness: .codex, sessionId: "")
        HistoryReader.readCodex(codexLines("g1", source: "guardian_review").split(separator: "\n").map { Data($0.utf8) }, into: &guardian)
        XCTAssertTrue(guardian.isInternal)
    }

    /// A long session keeps its newest replies within the cap, and every prompt; reading it in two goes (as a growing
    /// transcript is) neither repeats nor misses a line.
    func testLongSessionKeepsItsNewestTextsWithinTheCap() throws {
        let reply = String(repeating: "回复", count: 600) // 3600 bytes, under the per-text cut
        func turn(_ index: Int) -> String {
            line(["type": "user", "timestamp": "2026-11-05T01:00:00.000Z", "message": ["role": "user", "content": "问题 \(index)"]])
            + line(["type": "assistant", "timestamp": "2026-11-05T01:00:05.000Z",
                    "message": ["role": "assistant", "content": [["type": "text", "text": "\(index) \(reply)"]]]])
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((0..<60).map(turn).joined().utf8).write(to: file)
        var session = PastSession(harness: .claude, sessionId: "long")
        let first = try XCTUnwrap(HistoryReader.lines(of: file, from: 0))
        HistoryReader.readClaude(first.lines, into: &session)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((60..<120).map(turn).joined().utf8))
        try handle.close()
        let second = try XCTUnwrap(HistoryReader.lines(of: file, from: first.end))
        HistoryReader.readClaude(second.lines, into: &session)

        XCTAssertEqual(session.prompts, (0..<120).map { "问题 \($0)" }, "every prompt, once")
        XCTAssertLessThanOrEqual(session.texts.reduce(0) { $0 + $1.utf8.count }, PastSession.textBytesLimit)
        let kept = session.texts.map { Int($0.prefix { $0 != " " })! }
        XCTAssertEqual(kept, Array((120 - kept.count)..<120), "the newest, in order, none twice")
        XCTAssertGreaterThan(kept.count, 50)
    }

    func testSearchFindsIdsTitlesPromptsAndReplies() {
        var a = PastSession(harness: .claude, sessionId: "a81d03e5-2b7c")
        a.title = "菜单栏模式"; a.prompts = ["没有刘海的 Mac 放进菜单栏"]; a.texts = ["改好了，登录项也加上了"]; a.updated = Date(timeIntervalSince1970: 100)
        var b = PastSession(harness: .codex, sessionId: "01a19f42")
        b.prompts = ["登录测试偶尔失败"]; b.texts = ["$ npm test"]; b.updated = Date(timeIntervalSince1970: 200)
        let index = [a, b].map(HistorySearch.Indexed.init)

        XCTAssertEqual(HistorySearch.search(index, for: "a81d").map(\.field), [.id])
        // A prompt beats a reply, however recent.
        XCTAssertEqual(HistorySearch.search(index, for: "登录").map(\.session.sessionId), ["01a19f42", "a81d03e5-2b7c"])
        XCTAssertEqual(HistorySearch.search(index, for: "登录").map(\.field), [.prompt, .reply])
        // Every word, anywhere in the session.
        XCTAssertEqual(HistorySearch.search(index, for: "刘海 登录项").map(\.session.sessionId), ["a81d03e5-2b7c"])
        XCTAssertTrue(HistorySearch.search(index, for: "刘海 npm").isEmpty)
        // Case does not matter, and the line shows the match.
        let hit = HistorySearch.search(index, for: "NPM").first
        XCTAssertEqual(hit?.snippet, HistorySearch.Snippet(before: "$ ", match: "npm", after: " test"))
    }

    func testHistoryReadsOnlyWhatIsNew() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let claudeFolder = home.appendingPathComponent(".claude/projects/-Users-me-Bangs")
        let codexFolder = home.appendingPathComponent(".codex/sessions/2026/11/04")
        try FileManager.default.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexFolder, withIntermediateDirectories: true)
        let claudeFile = claudeFolder.appendingPathComponent("c1.jsonl")
        try claudeLines("c1").write(to: claudeFile, atomically: true, encoding: .utf8)
        try (codexLines("x1") + #"{"type":"response_item","payload":{"type":"message","role":"user","con"#).write(
            to: codexFolder.appendingPathComponent("rollout-x1.jsonl"), atomically: true, encoding: .utf8)   // a line still being written
        try codexLines("g1", source: "guardian_review").write(to: codexFolder.appendingPathComponent("rollout-g1.jsonl"), atomically: true, encoding: .utf8)

        let preferences = Preferences()
        let history = SessionHistory(preferences: preferences, home: home)
        func reload() async throws {
            history.refresh(force: true)
            let start = Date()
            repeat { try await Task.sleep(nanoseconds: 50_000_000) } while history.sessions.isEmpty && Date().timeIntervalSince(start) < 10
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await reload()
        XCTAssertEqual(Set(history.searchable.map(\.id)), ["claude:c1", "codex:x1"], "Codex's own reviewer threads are left out")

        // The session goes on: the next prompt is found, the earlier ones are not read twice.
        let more = line(["type": "user", "cwd": "/Users/me/Bangs", "timestamp": "2026-11-05T02:00:00.000Z", "message": ["role": "user", "content": "再加上全文搜索"]])
        let handle = try FileHandle(forWritingTo: claudeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()
        try await reload()
        let session = try XCTUnwrap(history.sessions.first { $0.id == "claude:c1" })
        XCTAssertEqual(session.prompts, ["给刘海加一个会话搜索", "再加上全文搜索"])
        XCTAssertEqual(HistorySearch.search(history.searchableIndex, for: "全文").first?.session.id, "claude:c1")
    }
}

final class ScrollKeysTests: XCTestCase {
    func testTheFirstScrollDecidesTheDirection() {
        XCTAssertEqual(ScrollKeys.direction(dx: 12, dy: -3), .horizontal)
        XCTAssertEqual(ScrollKeys.direction(dx: 2, dy: -9), .vertical)
        XCTAssertNil(ScrollKeys.direction(dx: 0, dy: 0))
    }

    /// Kept sideways, a scroll's drift up or down is taken out, and its sideways part left as it was.
    func testLockingTakesOutTheOtherDirection() throws {
        let sideways = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 4, wheel2: -30, wheel3: 0))
        ScrollKeys.keep(sideways, to: .horizontal)
        XCTAssertEqual(sideways.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(sideways.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
        XCTAssertEqual(sideways.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -30)

        let down = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -25, wheel2: 3, wheel3: 0))
        ScrollKeys.keep(down, to: .vertical)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -25)
    }
}

final class HoldKeyTests: XCTestCase {
    private func keyDown(_ code: CGKeyCode, _ characters: String, flags: CGEventFlags = []) -> NSEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        event.keyboardSetUnicodeString(stringLength: characters.utf16.count, unicodeString: Array(characters.utf16))
        return NSEvent(cgEvent: event)!
    }

    private func modifier(_ code: CGKeyCode, _ flags: CGEventFlags) -> NSEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        return NSEvent(cgEvent: event)!
    }

    func testAKeyOnItsOwnOrAModifierAlone() {
        XCTAssertEqual(HoldKey(keyDown: keyDown(49, " ")), .space)
        XCTAssertEqual(HoldKey(keyDown: keyDown(48, "\t"))?.name, "⇥")
        XCTAssertEqual(HoldKey(keyDown: keyDown(7, "x"))?.name, "X")
        XCTAssertNil(HoldKey(keyDown: keyDown(7, "x", flags: .maskCommand)), "a shortcut is not a key to hold")
        XCTAssertNil(HoldKey(keyDown: keyDown(36, "\r")), "return finishes the capture")
        XCTAssertNil(HoldKey(keyDown: keyDown(53, "\u{1b}")), "Esc cancels it")

        let option = HoldKey(flagsChanged: modifier(58, .maskAlternate))
        XCTAssertEqual(option?.name, "⌥ Option")
        XCTAssertNil(option?.keyCode)
        XCTAssertNil(option?.conflict)
        XCTAssertNil(HoldKey(flagsChanged: modifier(58, [.maskAlternate, .maskShift])), "one modifier, not two")
    }

    func testKeysThatGetInTheWayAreNamed() {
        XCTAssertNotNil(HoldKey(flagsChanged: modifier(56, .maskShift))?.conflict, "Shift turns a wheel's scroll sideways")
        XCTAssertNotNil(HoldKey(flagsChanged: modifier(63, .maskSecondaryFn))?.conflict)
        XCTAssertNil(HoldKey.space.conflict)
    }

    func testTheChoiceIsKept() throws {
        let option = try XCTUnwrap(HoldKey(flagsChanged: modifier(58, .maskAlternate)))
        let data = try JSONEncoder().encode(option)
        XCTAssertEqual(try JSONDecoder().decode(HoldKey.self, from: data), option)
    }
}

/// A sideways scroll that starts with the page dragged a pixel or two up or down, as a finger landing on a trackpad does.
final class ScrollDirectionTests: XCTestCase {
    private func wide(width: Int = 2200, height: Int = 400) -> CGImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
            var y: CGFloat = 8, n = 0
            while y < CGFloat(height) - 16 {
                let line = (0..<50).map { i in ["日期", "收入", "Revenue", "2026-11-0\(i % 9)", "\(1200 + (i * 37 + n * 11) % 900)", "合计", "Q\(i % 4 + 1)"][(i + n) % 7] }.joined(separator: "   ")
                (line as NSString).draw(at: NSPoint(x: 6, y: y), withAttributes: attributes)
                y += 22; n += 1
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testJitterBeforeASidewaysScrollDoesNotTurnItVertical() throws {
        let page = wide()
        for jitter in [1, 3, 5] {
            let stitcher = Stitcher()
            stitcher.add(page.cropping(to: CGRect(x: 300, y: 20, width: 900, height: 300))!)
            stitcher.add(page.cropping(to: CGRect(x: 300, y: 20 + jitter, width: 900, height: 300))!)
            for i in 1...8 { stitcher.add(page.cropping(to: CGRect(x: 300 + i * 10, y: 20 + jitter, width: 900, height: 300))!) }
            XCTAssertEqual(stitcher.axis, .horizontal, "jitter \(jitter)")
            XCTAssertFalse(stitcher.lost)
            // It starts from where the jitter left the page, and runs on to the right.
            let image = try XCTUnwrap(stitcher.compose())
            XCTAssertEqual(image.width, 980)
            XCTAssertEqual(Stitcher.signatures(image), Stitcher.signatures(page.cropping(to: CGRect(x: 300, y: 20 + jitter, width: 980, height: 300))!))
        }
    }

    /// Slowly, a pixel or two a frame: nothing is lost while the direction settles.
    func testASlowStartLosesNothing() throws {
        let page = wide()
        let stitcher = Stitcher()
        for i in 0...20 { stitcher.add(page.cropping(to: CGRect(x: 300 + i * 2, y: 20, width: 900, height: 300))!) }
        XCTAssertEqual(stitcher.axis, .horizontal)
        XCTAssertEqual(try XCTUnwrap(stitcher.compose()).width, 940)
    }
}

/// One line of small text, framed tight, the way you would to copy a command: on a Retina screen and on a 1x one.
final class SingleLineRecognitionTests: XCTestCase {
    private func line(_ text: String, size: CGFloat, scale: CGFloat) -> CGImage {
        let height = Int(size * 1.4 * scale)
        let width = Int((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width * scale) + 20
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        (text as NSString).draw(at: NSPoint(x: 5, y: size * 0.1), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
        NSGraphicsContext.current = nil
        return context.makeImage()!
    }

    func testASmallLineReads() async throws {
        for scale in [2.0, 1.0] as [CGFloat] {
            let text = "一行很小的说明文字 small caption"
            let read = try await TextRecognition.recognize(line(text, size: 10, scale: scale), language: .auto, joinLines: true)
            XCTAssertEqual(read, text, "at \(scale)x")
        }
    }
}

final class LogTests: XCTestCase {
    override class func setUp() { TestData.isolate }

    /// A full log is set aside as bangs.log.old, replacing the one before, rather than lost.
    func testFullLogIsKeptAsTheOldOne() throws {
        let log = Storage.root.appendingPathComponent("bangs.log"), old = log.appendingPathExtension("old")
        try FileManager.default.createDirectory(at: Storage.root, withIntermediateDirectories: true)
        try Data("an older old log".utf8).write(to: old)
        let marker = UUID().uuidString
        Log.write("filler " + String(repeating: "x", count: Log.limit))
        Log.write(marker)
        let deadline = Date().addingTimeInterval(5)
        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        while !text(log).contains(marker), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(text(log).contains(marker))
        XCTAssertFalse(text(log).contains("filler"), "a fresh log after the switch")
        XCTAssertTrue(text(old).contains("filler"), "the full one is kept")
        XCTAssertFalse(text(old).contains("an older old log"))
    }
}
