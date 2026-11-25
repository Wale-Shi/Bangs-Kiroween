import BangsCore
import XCTest
@testable import Bangs

/// The records of the CLIs read besides Claude Code and Codex, in the shapes they write them.
final class HistoryReadersTests: XCTestCase {
    private func lines(_ records: [[String: Any]]) -> [Data] {
        records.map { try! JSONSerialization.data(withJSONObject: $0) }
    }

    func testCodeBuddy() {
        let file = URL(fileURLWithPath: "/Users/me/.codebuddy/projects/Users-me-Muster/01a18387-62d8.jsonl")
        var session = PastSession(harness: .codebuddy, sessionId: HistoryReader.sessionId(of: file, harness: .codebuddy))
        HistoryReader.read(lines([
            ["type": "message", "role": "user", "timestamp": 1793208050497, "sessionId": "01a18387-62d8", "cwd": "/Users/me/Muster",
             "content": [["type": "input_text", "text": "跑一下类型检查"]]],
            ["type": "file-history-snapshot", "timestamp": 1793208050832, "cwd": "/Users/me/Muster"],
            ["type": "function_call", "name": "Bash", "arguments": #"{"command":"npm run typecheck"}"#],
            ["type": "message", "role": "assistant", "timestamp": 1793208060000, "content": [["type": "output_text", "text": "类型检查通过"]],
             "providerData": ["usage": ["inputTokens": 24265]]],
        ]), harness: .codebuddy, into: &session)
        XCTAssertEqual(session.sessionId, "01a18387-62d8")
        XCTAssertEqual(session.cwd, "/Users/me/Muster")
        XCTAssertEqual(session.prompts, ["跑一下类型检查"])
        XCTAssertEqual(session.texts, ["$ npm run typecheck", "类型检查通过"])
        XCTAssertEqual(session.updated, Date(timeIntervalSince1970: 1793208060))
        XCTAssertEqual(session.resumeCommand, "cd /Users/me/Muster && codebuddy --resume 01a18387-62d8")
    }

    func testPiAndOmp() {
        let file = URL(fileURLWithPath: "/Users/me/.omp/agent/sessions/--tmp--/2026-11-03T15-08-40-305Z_01a1a1f4.jsonl")
        var session = PastSession(harness: .omp, sessionId: HistoryReader.sessionId(of: file, harness: .omp))
        XCTAssertEqual(session.sessionId, "01a1a1f4")
        HistoryReader.read(lines([
            ["type": "title", "title": "\u{F0BC3} PROMPT: 升级 omp"],
            ["type": "session", "id": "01a1a1f4", "timestamp": "2026-11-03T15:08:40.305Z", "cwd": "/Users/me/tools"],
            ["type": "message", "timestamp": "2026-11-03T15:08:54.440Z", "message": ["role": "user", "content": [["type": "text", "text": "把 omp 升级到最新"]]]],
            ["type": "message", "timestamp": "2026-11-03T15:10:11.650Z", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "…"], ["type": "toolCall", "name": "bash", "arguments": ["command": "omp update"]], ["type": "text", "text": "升级好了"]]]],
        ]), harness: .omp, into: &session)
        XCTAssertEqual(session.title, "PROMPT: 升级 omp")
        XCTAssertEqual(session.cwd, "/Users/me/tools")
        XCTAssertEqual(session.prompts, ["把 omp 升级到最新"])
        XCTAssertEqual(session.texts, ["$ omp update", "升级好了"])
        XCTAssertEqual(session.updated, Timestamps.date("2026-11-03T15:10:11.650Z"))
    }

    func testGemini() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let chats = home.appendingPathComponent(".gemini/tmp/web-app/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try "/Users/me/web-app\n".write(to: chats.deletingLastPathComponent().appendingPathComponent(".project_root"), atomically: true, encoding: .utf8)
        let chat: [String: Any] = ["sessionId": "0666c074", "lastUpdated": "2026-03-19T15:21:45.737Z", "messages": [
            ["type": "user", "content": [["text": "升级依赖"]]],
            ["type": "gemini", "content": "先看看 package.json", "toolCalls": [["name": "run_shell_command", "args": ["command": "npm outdated"]]],
             "tokens": ["input": 5969, "output": 33], "model": "gemini-3-flash-preview"],
        ]]
        let file = chats.appendingPathComponent("session-2026-03-19T15-21-0666c074.json")
        try JSONSerialization.data(withJSONObject: chat, options: .prettyPrinted).write(to: file)
        XCTAssertEqual(HistoryReader.geminiFiles(home: home).map(\.lastPathComponent), [file.lastPathComponent])
        var session = PastSession(harness: .gemini, sessionId: "")
        HistoryReader.readGemini(try Data(contentsOf: file), cwd: HistoryReader.geminiFolder(of: file), into: &session)
        XCTAssertEqual(session.sessionId, "0666c074")
        XCTAssertEqual(session.cwd, "/Users/me/web-app")
        XCTAssertEqual(session.prompts, ["升级依赖"])
        XCTAssertEqual(session.texts, ["先看看 package.json", "$ npm outdated"])
        // Its context, from the end of the same file.
        XCTAssertEqual(Usage.context(in: try String(contentsOf: file, encoding: .utf8), harness: .gemini), ContextFill(tokens: 5969, window: 1_048_576))
    }

    /// OpenCode keeps its sessions in SQLite: read without writing, sub-agents' sessions left out, unnamed sessions
    /// titled by their first prompt.
    func testOpenCode() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-opencode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let database = HistoryReader.openCodeDatabase(home: home)
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sql = """
        create table session (id text primary key, project_id text, parent_id text, directory text, title text, time_updated integer, time_archived integer);
        create table message (id text primary key, session_id text, time_created integer, data text);
        create table part (id text primary key, message_id text, session_id text, time_created integer, data text);
        insert into session values ('ses_a', 'p', null, '/Users/me/api', 'New session - 2026-10-22T16:15:30.669Z', 1792685730669, null);
        insert into session values ('ses_b', 'p', 'ses_a', '/Users/me/api', 'Explore the code', 1792685730000, null);
        insert into message values ('m1', 'ses_a', 1, '{"role":"user"}');
        insert into message values ('m2', 'ses_a', 2, '{"role":"assistant"}');
        insert into part values ('p1', 'm1', 'ses_a', 1, '{"type":"text","text":"修一下登录接口"}');
        insert into part values ('p2', 'm2', 'ses_a', 2, '{"type":"tool","tool":"bash","state":{"input":{"command":"go test ./auth"}}}');
        insert into part values ('p3', 'm2', 'ses_a', 3, '{"type":"text","text":"测试通过了"}');
        insert into part values ('p4', 'm1', 'ses_a', 4, '{"type":"text","text":"<file>…</file>","synthetic":true}');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let sessions = HistoryReader.readOpenCode(home: home).sorted { $0.sessionId < $1.sessionId }
        XCTAssertEqual(sessions.map(\.sessionId), ["ses_a", "ses_b"])
        XCTAssertEqual(sessions[0].shownTitle, "修一下登录接口")
        XCTAssertEqual(sessions[0].texts, ["$ go test ./auth", "测试通过了"])
        XCTAssertEqual(sessions[0].cwd, "/Users/me/api")
        XCTAssertEqual(sessions[0].resumeCommand, "cd /Users/me/api && opencode --session ses_a")
        XCTAssertTrue(sessions[1].isInternal)
        XCTAssertNotNil(HistoryReader.openCodeModified(home: home))
    }

    func testContextFromTranscripts() {
        let codebuddy = #"{"type":"message","role":"assistant","providerData":{"usage":{"inputTokens":24265,"outputTokens":60}}}"#
        XCTAssertEqual(Usage.context(in: codebuddy, harness: .codebuddy), ContextFill(tokens: 24265, window: nil))
        let pi = #"{"type":"message","message":{"role":"assistant","usage":{"input":10048,"output":1447,"cacheRead":2000,"cacheWrite":10}}}"#
        XCTAssertEqual(Usage.context(in: pi, harness: .pi), ContextFill(tokens: 12058, window: nil))
        XCTAssertNil(Usage.context(in: pi, harness: .hermes))
    }
}
