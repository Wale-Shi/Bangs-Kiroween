import Foundation
import XCTest
@testable import BangsCore

final class HookInstallerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testInstallKeepsOtherHooksAndUninstallRestoresThem() throws {
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let other: [String: Any] = ["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "rex session-start", "timeout": 5]]]],
            "PermissionRequest": [["hooks": [["type": "command", "command": "orca hook", "timeout": 10]]]],
        ]]
        let file = codex.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: other).write(to: file)
        let installer = HookInstaller(harness: .codex, hookBinary: "/Applications/Bangs.app/Contents/Helpers/bangs-hook", user: home)
        XCTAssertEqual(installer.state(), .notInstalled)

        try installer.install()
        XCTAssertEqual(installer.state(), .installed)
        let hooks = try json(file)["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(Harness.codex.events.map(\.native)))
        let permission = hooks["PermissionRequest"] as! [[String: Any]]
        // Existing groups keep their position, so Codex's per-entry trust stays valid.
        XCTAssertEqual(((permission[0]["hooks"] as! [[String: Any]])[0]["command"] as! String), "orca hook")
        let ours = (permission[1]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(ours["command"] as! String, "'/Applications/Bangs.app/Contents/Helpers/bangs-hook' codex PermissionRequest")
        XCTAssertEqual(ours["timeout"] as! Int, HookInstaller.permissionTimeout)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: codex.path).contains { $0.hasPrefix("hooks.json.bangs-") })

        // Installing twice does not duplicate entries.
        try installer.install()
        XCTAssertEqual(((try json(file)["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]).count, 2)

        try installer.uninstall()
        XCTAssertEqual(installer.state(), .notInstalled)
        let restored = try json(file)["hooks"] as! [String: Any]
        XCTAssertEqual(Set(restored.keys), ["SessionStart", "PermissionRequest"])
    }

    func testMovedAppIsReportedAsOutdated() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try HookInstaller(harness: .claude, hookBinary: "/old/bangs-hook", user: home).install()
        XCTAssertEqual(HookInstaller(harness: .claude, hookBinary: "/new/bangs-hook", user: home).state(), .outdated)
    }

    func testMissingCLIIsNotDetected() {
        XCTAssertEqual(HookInstaller(harness: .qoder, hookBinary: "/x", user: home).state(), .notDetected)
    }
}

final class WireTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let envelope = HookEnvelope(harness: .claude, native: "PermissionRequest", pid: 42, payload: ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash"])
        var line = try envelope.encoded()
        XCTAssertEqual(line.removeLast(), 0x0A)
        let decoded = try XCTUnwrap(HookEnvelope(line: line))
        XCTAssertEqual(decoded.harness, .claude)
        XCTAssertEqual(decoded.pid, 42)
        XCTAssertEqual(decoded.event, .permissionRequest)
        XCTAssertEqual(decoded.sessionId, "s1")
    }

    func testPermissionOutputUsesOnlyPortableFields() throws {
        let allow = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(Harness.codex.permissionOutput(.allow)).utf8)) as! [String: Any]
        let output = allow["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(output["hookEventName"] as! String, "PermissionRequest")
        XCTAssertEqual(output["decision"] as! [String: String], ["behavior": "allow"])
        XCTAssertNil(Harness.claude.permissionOutput(.terminal))
        // Copilot CLI answers at the top level.
        XCTAssertEqual(Harness.copilot.permissionOutput(.allow), #"{"behavior":"allow"}"#)
        var line = PermissionReply.deny.line
        line.removeLast()
        XCTAssertEqual(PermissionReply(line: line), .deny)
    }
}

final class QuestionTests: XCTestCase {
    static let input: [String: Any] = ["questions": [
        ["question": "Which database?", "header": "Storage", "multiSelect": false,
         "options": [["label": "SQLite", "description": "One file"], ["label": "Postgres", "description": "A server"]]],
        ["question": "Which extras?", "header": "Extras", "multiSelect": true,
         "options": [["label": "Auth", "description": ""], ["label": "Search", "description": ""]]],
    ]]

    func testParsesQuestions() {
        let questions = AgentQuestion.parse(Self.input)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].header, "Storage")
        XCTAssertEqual(questions[0].options.map(\.label), ["SQLite", "Postgres"])
        XCTAssertEqual(questions[0].options[0].description, "One file")
        XCTAssertTrue(questions[1].multiSelect)
        // Anything it cannot show whole is left to the terminal.
        XCTAssertEqual(AgentQuestion.parse(["questions": [["question": "Free text?", "options": []]]]), [])
        XCTAssertEqual(AgentQuestion.parse(["command": "ls"]), [])
    }

    func testAnswersJoinSeveralChoices() {
        let questions = AgentQuestion.parse(Self.input) + [AgentQuestion(question: "Skipped?", options: [.init(label: "Yes", description: "")])]
        XCTAssertEqual(AgentQuestion.answers(questions, chosen: [0: ["SQLite"], 1: ["Auth", "Search"], 2: []]),
                       ["Which database?": "SQLite", "Which extras?": "Auth, Search"])
    }

    /// Chosen by position: two questions that read the same keep their own choices, and both are sent.
    func testSameQuestionTwiceKeepsBothAnswers() {
        let options: [AgentQuestion.Option] = [.init(label: "Yes", description: ""), .init(label: "No", description: "")]
        let questions = [AgentQuestion(question: "Continue?", options: options), AgentQuestion(question: "Continue?", options: options),
                         AgentQuestion(question: "Deploy?", options: options)]
        XCTAssertEqual(AgentQuestion.answers(questions, chosen: [0: ["Yes"], 1: ["No"], 2: ["No"]]), ["Continue?": "Yes, No", "Deploy?": "No"])
        XCTAssertEqual(AgentQuestion.answers(questions, chosen: [0: ["Yes"], 1: ["Yes"]]), ["Continue?": "Yes"])
    }

    func testAnswersReplyRoundTripsAndIsPrintedForClaude() throws {
        let reply = PermissionReply.answers(["Which database?": "SQLite"])
        var line = reply.line
        XCTAssertEqual(line.removeLast(), 0x0A)
        XCTAssertEqual(PermissionReply(line: line), reply)
        let output = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(Harness.claude.permissionOutput(reply, input: Self.input)).utf8)) as! [String: Any]
        let specific = output["hookSpecificOutput"] as! [String: Any]
        let decision = specific["decision"] as! [String: Any]
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = decision["updatedInput"] as! [String: Any]
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which database?": "SQLite"])
        XCTAssertEqual((updated["questions"] as? [[String: Any]])?.count, 2)
        // Other CLIs do not take answers this way: their own prompt asks.
        XCTAssertNil(Harness.codex.permissionOutput(reply, input: Self.input))
        XCTAssertNil(Harness.claude.permissionOutput(reply, input: nil))
    }
}

/// Runs the real hook binary against a socket standing in for the app.
final class HookBinaryTests: XCTestCase {
    private func hookBinary() throws -> URL {
        var url = Bundle(for: Self.self).bundleURL
        while url.path != "/" {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("bangs-hook")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            url = url.deletingLastPathComponent()
        }
        throw XCTSkip("bangs-hook not built")
    }

    private func run(_ payload: [String: Any], env: [String: String], reply: PermissionReply?) throws -> (sent: HookEnvelope?, output: String) {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("n\(UInt32.random(in: 0...UInt32.max)).sock").path
        let listener = try XCTUnwrap(UnixSocket.listen(at: socket))
        defer { close(listener); unlink(socket) }
        var received: HookEnvelope?
        let served = env.isEmpty ? expectation(description: "served") : nil
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            if let line = UnixSocket.readLine(fd) { received = HookEnvelope(line: line) }
            if let reply { _ = UnixSocket.write(fd, reply.line) }
            close(fd)
            served?.fulfill()
        }
        let process = Process()
        process.executableURL = try hookBinary()
        process.arguments = ["claude"]
        process.environment = ["BANGS_SOCKET": socket].merging(env) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        if let served { wait(for: [served], timeout: 5) }
        return (received, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private let request: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/tmp", "tool_name": "Bash", "tool_input": ["command": "ls"]]

    func testAllowIsPrintedForTheCLI() throws {
        let result = try run(request, env: [:], reply: .allow)
        XCTAssertEqual(result.sent?.event, .permissionRequest)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), Harness.claude.permissionOutput(.allow))
    }

    func testDenyAndTerminal() throws {
        XCTAssertEqual(try run(request, env: [:], reply: .deny).output.trimmingCharacters(in: .whitespacesAndNewlines), Harness.claude.permissionOutput(.deny))
        XCTAssertEqual(try run(request, env: [:], reply: .terminal).output, "")
    }

    func testAnswersArePrintedWithTheQuestionsInput() throws {
        var question = request
        question["tool_name"] = AgentQuestion.tool
        question["tool_input"] = QuestionTests.input
        let reply = PermissionReply.answers(["Which database?": "Postgres", "Which extras?": "Auth"])
        let result = try run(question, env: [:], reply: reply)
        XCTAssertEqual(result.sent?.toolName, AgentQuestion.tool)
        let output = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: Any]
        let decision = (output["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        let updated = decision["updatedInput"] as! [String: Any]
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which database?": "Postgres", "Which extras?": "Auth"])
        XCTAssertEqual(AgentQuestion.parse(updated), AgentQuestion.parse(QuestionTests.input))
    }

    func testOtherEventsPrintNothing() throws {
        let result = try run(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash"], env: [:], reply: nil)
        XCTAssertEqual(result.sent?.event, .preTool)
        XCTAssertEqual(result.output, "")
    }

    func testIgnoredSessionsAreSkipped() throws {
        for env in [["BANGS_IGNORE": "1"], ["MUSTER_AGENT": "1"]] {
            let result = try run(request, env: env, reply: .allow)
            XCTAssertNil(result.sent)
            XCTAssertEqual(result.output, "")
        }
    }

    /// Loads the generated OpenCode plugin in Node, feeds it OpenCode events and checks what reaches the socket.
    func testOpenCodePluginForwardsEvents() throws {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("node not installed")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        try HookInstaller(harness: .opencode, hookBinary: try hookBinary().path, user: home).install()
        let plugin = home.appendingPathComponent(".config/opencode/plugins/bangs.js")
        let module = home.appendingPathComponent("bangs.mjs")
        try FileManager.default.copyItem(at: plugin, to: module)
        let driver = home.appendingPathComponent("driver.mjs")
        try """
        const { BangsPlugin } = await import(process.argv[2]);
        const hooks = await BangsPlugin({ directory: "/tmp/proj" });
        await hooks.event({ event: { type: "session.created", properties: { info: { id: "s1", directory: "/tmp/proj" } } } });
        await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
        await hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1" }, { args: { command: "ls" } });
        await hooks.event({ event: { type: "permission.asked", properties: { sessionID: "s1", title: "rm -rf build" } } });
        await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s1" } } });
        await new Promise((resolve) => setTimeout(resolve, 1500));
        """.write(to: driver, atomically: true, encoding: .utf8)

        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("o\(UInt32.random(in: 0...UInt32.max)).sock").path
        let listener = try XCTUnwrap(UnixSocket.listen(at: socket))
        defer { close(listener); unlink(socket) }
        let lock = NSLock()
        var received: [HookEnvelope] = []
        Thread.detachNewThread {
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { return }
                if let line = UnixSocket.readLine(fd), let envelope = HookEnvelope(line: line) { lock.lock(); received.append(envelope); lock.unlock() }
                close(fd)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [driver.path, module.path]
        process.environment = ["BANGS_SOCKET": socket, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(received.allSatisfy { $0.harness == .opencode && $0.sessionId == "s1" })
        XCTAssertEqual(Set(received.compactMap(\.event)), [.sessionStart, .prompt, .preTool, .notification, .stop])
        XCTAssertEqual(received.first { $0.event == .notification }?.notificationKind, .permission)
        XCTAssertEqual(received.first { $0.event == .preTool }?.toolName, "bash")
    }

    /// Loads the generated pi extension in Node (types stripped), drives it like pi does and checks what reaches the socket.
    func testPiExtensionForwardsEvents() throws {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("node not installed")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".pi/agent"), withIntermediateDirectories: true)
        let installer = HookInstaller(harness: .pi, hookBinary: try hookBinary().path, user: home)
        try installer.install()
        XCTAssertEqual(installer.state(), .installed)
        let module = home.appendingPathComponent("bangs.mts")
        try FileManager.default.copyItem(at: home.appendingPathComponent(".pi/agent/extensions/bangs.ts"), to: module)
        let driver = home.appendingPathComponent("driver.mjs")
        try """
        const { default: extension } = await import(process.argv[2]);
        const handlers = {};
        extension({ on: (name, handler) => { handlers[name] = handler; } });
        extension({ on: () => { throw new Error("loaded twice"); } });
        const ctx = { mode: "tui", cwd: "/tmp/pi-proj", isIdle: () => true, sessionManager: { getSessionId: () => "p1" } };
        handlers.session_start({}, ctx);
        handlers.input({ text: "refactor upload" }, ctx);
        handlers.tool_call({ toolName: "bash", input: { command: "ls" } }, ctx);
        handlers.tool_result({ toolName: "bash" }, ctx);
        handlers.agent_end({ messages: [{ role: "assistant", content: [{ type: "text", text: "All done." }] }] }, ctx);
        handlers.agent_settled({}, ctx);
        await new Promise((resolve) => setTimeout(resolve, 1500));
        """.write(to: driver, atomically: true, encoding: .utf8)

        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("p\(UInt32.random(in: 0...UInt32.max)).sock").path
        let listener = try XCTUnwrap(UnixSocket.listen(at: socket))
        defer { close(listener); unlink(socket) }
        let lock = NSLock()
        var received: [HookEnvelope] = []
        Thread.detachNewThread {
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { return }
                if let line = UnixSocket.readLine(fd), let envelope = HookEnvelope(line: line) { lock.lock(); received.append(envelope); lock.unlock() }
                close(fd)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--experimental-strip-types", "--no-warnings", driver.path, module.path]
        process.environment = ["BANGS_SOCKET": socket, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(received.allSatisfy { $0.harness == .pi && $0.sessionId == "p1" && $0.cwd == "/tmp/pi-proj" })
        XCTAssertEqual(Set(received.compactMap(\.event)), [.sessionStart, .prompt, .preTool, .postTool, .stop])
        XCTAssertEqual(received.first { $0.event == .stop }?.lastMessage, "All done.")
        XCTAssertEqual(received.first { $0.event == .prompt }?.prompt, "refactor upload")
    }

    func testNoAppMeansNoOutput() throws {
        let process = Process()
        process.executableURL = try hookBinary()
        process.arguments = ["codex"]
        process.environment = ["BANGS_SOCKET": "/tmp/does-not-exist-\(UUID().uuidString).sock"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile().count, 0)
    }
}

final class HarnessTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func make(_ path: String) throws { try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true) }
    private func json(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }

    func testGeminiUsesItsEventNamesAndMilliseconds() throws {
        try make(".gemini")
        let installer = HookInstaller(harness: .gemini, hookBinary: "/b/bangs-hook", user: home)
        try installer.install()
        XCTAssertEqual(installer.state(), .installed)
        let hooks = try json(home.appendingPathComponent(".gemini/settings.json"))["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "SessionEnd", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent"])
        let handler = ((hooks["BeforeTool"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(handler["timeout"] as! Int, 5000)
        XCTAssertEqual(handler["command"] as! String, "'/b/bangs-hook' gemini BeforeTool")
        XCTAssertFalse(Harness.gemini.answersPermissions)
    }

    func testCopilotAndKiroGetFilesOfTheirOwn() throws {
        try make(".copilot")
        try make(".kiro")
        for harness in [Harness.copilot, .kiro] {
            let installer = HookInstaller(harness: harness, hookBinary: "/b/bangs-hook", user: home)
            XCTAssertEqual(installer.state(), .notInstalled)
            try installer.install()
            XCTAssertEqual(installer.state(), .installed)
            XCTAssertEqual(installer.file.lastPathComponent, "bangs.json")
        }
        let copilot = try json(home.appendingPathComponent(".copilot/hooks/bangs.json"))
        XCTAssertEqual(copilot["version"] as! Int, 1)
        let permission = ((copilot["hooks"] as! [String: Any])["permissionRequest"] as! [[String: Any]])[0]
        XCTAssertEqual(permission["bash"] as! String, "'/b/bangs-hook' copilot permissionRequest")
        XCTAssertEqual(permission["timeoutSec"] as! Int, HookInstaller.permissionTimeout)
        let kiro = try json(home.appendingPathComponent(".kiro/hooks/bangs.json"))
        XCTAssertEqual((kiro["hooks"] as! [[String: Any]]).compactMap { $0["trigger"] as? String }, Harness.kiro.events.map(\.native))
        try HookInstaller(harness: .copilot, hookBinary: "/b/bangs-hook", user: home).uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/hooks/bangs.json").path))
    }

    func testOpenCodePluginCallsTheHook() throws {
        try make(".config/opencode")
        try HookInstaller(harness: .opencode, hookBinary: "/Applications/Bangs.app/Contents/Helpers/bangs-hook", user: home).install()
        let plugin = try String(contentsOf: home.appendingPathComponent(".config/opencode/plugins/bangs.js"), encoding: .utf8)
        XCTAssertTrue(plugin.contains(#"const HOOK = "/Applications/Bangs.app/Contents/Helpers/bangs-hook";"#))
        XCTAssertTrue(plugin.contains("export const BangsPlugin"))
    }

    func testDroidStandaloneHooksFileKeysEventsAtTheTop() throws {
        try make(".factory")
        try Data(#"{"Stop":[{"hooks":[{"type":"command","command":"other"}]}]}"#.utf8).write(to: home.appendingPathComponent(".factory/hooks.json"))
        let installer = HookInstaller(harness: .droid, hookBinary: "/b/bangs-hook", user: home)
        try installer.install()
        XCTAssertEqual(installer.state(), .installed)
        let root = try json(home.appendingPathComponent(".factory/hooks.json"))
        XCTAssertNil(root["hooks"])
        XCTAssertEqual((root["Stop"] as! [[String: Any]]).count, 2)
        try installer.uninstall()
        XCTAssertEqual((try json(home.appendingPathComponent(".factory/hooks.json"))["Stop"] as! [[String: Any]]).count, 1)
    }

    func testCursorFollowsClaudeHooks() throws {
        try make(".cursor")
        try make(".claude")
        let cursor = HookInstaller(harness: .cursor, hookBinary: "/b/bangs-hook", user: home)
        XCTAssertEqual(cursor.state(), .notInstalled)
        try cursor.install()
        XCTAssertEqual(HookInstaller(harness: .claude, hookBinary: "/b/bangs-hook", user: home).state(), .installed)
        XCTAssertEqual(Harness.resolve(.claude, environment: ["CURSOR_VERSION": "2.4"]), .cursor)
        XCTAssertEqual(Harness.resolve(.claude, environment: [:]), .claude)
    }

    func testEnvelopesReadEachCLIsFieldNames() {
        let copilot = HookEnvelope(harness: .copilot, native: "preToolUse", pid: 1, payload: ["sessionId": "c1", "cwd": "/w", "toolName": "bash", "toolArgs": #"{"command":"ls"}"#])
        XCTAssertEqual(copilot.event, .preTool)
        XCTAssertEqual(copilot.sessionId, "c1")
        XCTAssertEqual(copilot.toolName, "bash")
        XCTAssertEqual((copilot.toolInput as? [String: Any])?["command"] as? String, "ls")
        let gemini = HookEnvelope(harness: .gemini, native: "AfterAgent", pid: 1, payload: ["session_id": "g", "prompt_response": "done"])
        XCTAssertEqual(gemini.event, .stop)
        XCTAssertEqual(gemini.lastMessage, "done")
        let cursor = HookEnvelope(harness: .cursor, native: "Stop", pid: 1, payload: ["conversation_id": "x", "workspace_roots": ["/repo"]])
        XCTAssertEqual(cursor.sessionId, "x")
        XCTAssertEqual(cursor.cwd, "/repo")
        XCTAssertEqual(HookEnvelope(harness: .droid, native: "Notification", pid: 1, payload: ["notification_type": "permission_prompt"]).notificationKind, .permission)
        XCTAssertEqual(HookEnvelope(harness: .gemini, native: "Notification", pid: 1, payload: ["notification_type": "ToolPermission"]).notificationKind, .permission)
        XCTAssertNil(HookEnvelope(harness: .codex, native: "Notification", pid: 1, payload: [:]).event)
    }
}

final class ResumeCommandTests: XCTestCase {
    func testCommandsOpenTheSessionFromItsFolder() {
        let id = "0f9c2a1e-6b1d-4c55-9a7e-2d3f1b8e4c10"
        XCTAssertEqual(Harness.claude.resumeCommand(sessionId: id, cwd: "/Users/me/app"), "cd /Users/me/app && claude --resume \(id)")
        XCTAssertEqual(Harness.codex.resumeCommand(sessionId: id, cwd: ""), "codex resume \(id)")
        XCTAssertEqual(Harness.omp.resumeCommand(sessionId: id, cwd: "/tmp"), "cd /tmp && omp --resume \(id)")
    }

    func testFoldersWithSpacesAndQuotesAreQuoted() {
        XCTAssertEqual(Harness.gemini.resumeCommand(sessionId: "abc", cwd: "/Users/me/My Project's"),
                       #"cd '/Users/me/My Project'\''s' && gemini --resume abc"#)
    }

    func testNoCommandWithoutTheCLIsOwnId() {
        XCTAssertNil(Harness.pi.resumeCommand(sessionId: "pid-4242", cwd: "/tmp"))
        XCTAssertNil(Harness.claude.resumeCommand(sessionId: "", cwd: "/tmp"))
    }
}

final class HermesPluginTests: XCTestCase {
    func testEnabledListIsRead() {
        XCTAssertTrue(HermesPlugin.isEnabled(config: "# notes\nplugins:\n  # keep\n  enabled:\n    - camofox\n    - bangs\n  disabled: []\nmodel:\n  default: x\n"))
        XCTAssertTrue(HermesPlugin.isEnabled(config: "plugins:\n  enabled: [camofox, \"bangs\"]\n"))
        XCTAssertFalse(HermesPlugin.isEnabled(config: "plugins:\n  enabled:\n    - camofox\n  disabled:\n    - bangs\n"))
        XCTAssertFalse(HermesPlugin.isEnabled(config: "model:\n  enabled:\n    - bangs\n"))
    }

    func testStateNeedsTheFilesAndTheConfig() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-hermes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: user) }
        let installer = HookInstaller(harness: .hermes, hookBinary: "/x/bangs-hook", user: user)
        XCTAssertEqual(installer.state(), .notDetected)
        let home = user.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("plugins/bangs"), withIntermediateDirectories: true)
        XCTAssertEqual(installer.state(), .notInstalled)
        try Data(installer.ownFile().utf8).write(to: installer.file)
        try Data(HermesPlugin.manifest.utf8).write(to: installer.hermesManifest)
        XCTAssertEqual(installer.state(), .outdated, "files written but not enabled in config.yaml")
        try Data("plugins:\n  enabled:\n    - bangs\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
        XCTAssertEqual(installer.state(), .installed)
        XCTAssertEqual(Harness.hermes.resumeCommand(sessionId: "20261104_101500_ab12", cwd: "/tmp"), "cd /tmp && hermes --resume 20261104_101500_ab12")
    }
}

final class TranscriptTests: XCTestCase {
    func testClaudeInterruption() {
        let tail = """
        {"type":"assistant","timestamp":"2026-11-04T09:31:10.000Z","message":{"role":"assistant","content":[{"type":"tool_use"}]}}
        {"type":"user","timestamp":"2026-11-04T09:31:12.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"rejected"}]}}
        {"type":"user","timestamp":"2026-11-04T09:31:12.039Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
        {"type":"last-prompt","lastPrompt":"x"}
        {"type":"cost-state","totalCostUSD":0}
        """
        XCTAssertEqual(Transcript.interruption(in: tail)?.timeIntervalSince1970 ?? 0, 1793784672.039, accuracy: 0.01)
        // A new prompt after it: the turn is going again.
        XCTAssertNil(Transcript.interruption(in: tail + "\n" + #"{"type":"user","timestamp":"2026-11-04T09:32:00.000Z","message":{"role":"user","content":"go on"}}"#))
        // A subagent's records say nothing about the main turn.
        XCTAssertNotNil(Transcript.interruption(in: tail + "\n" + #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[]}}"#))
    }

    func testCodexAndCodeBuddyInterruptions() {
        let codex = """
        {"timestamp":"2026-11-04T09:33:20.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-11-04T09:33:26.239Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}
        {"timestamp":"2026-11-04T09:33:26.300Z","type":"response_item","payload":{"type":"message","role":"developer"}}
        """
        XCTAssertNotNil(Transcript.interruption(in: codex))
        XCTAssertNil(Transcript.interruption(in: #"{"timestamp":"2026-11-04T09:33:20.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        let codebuddy = #"""
        {"type":"function_call","name":"REPL","timestamp":1793784980000}
        {"type":"function_call_result","name":"REPL","status":"incomplete","timestamp":1793784990572}
        """#
        XCTAssertEqual(Transcript.interruption(in: codebuddy)?.timeIntervalSince1970 ?? 0, 1793784990.572, accuracy: 0.01)
        XCTAssertNil(Transcript.interruption(in: #"{"type":"function_call_result","name":"REPL","status":"completed","timestamp":1}"#))
    }
}


final class TurnEndTests: XCTestCase {
    func testCodexTurnEnds() {
        let finished = """
        {"timestamp":"2026-11-05T05:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-11-05T05:01:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"改好了，测试都过了"}}
        {"timestamp":"2026-11-05T05:01:00.100Z","type":"event_msg","payload":{"type":"token_count"}}
        """
        XCTAssertEqual(Transcript.end(in: finished), .finished(Date(timeIntervalSince1970: 1793854860), message: "改好了，测试都过了"))
        XCTAssertNil(Transcript.interruption(in: finished), "a finished turn is not an interrupted one")

        let failed = """
        {"timestamp":"2026-11-05T05:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-11-05T05:00:30.000Z","type":"event_msg","payload":{"type":"stream_error","message":"Reconnecting... 1/5"}}
        {"timestamp":"2026-11-05T05:02:00.000Z","type":"event_msg","payload":{"type":"error","message":"stream disconnected before completion"}}
        """
        XCTAssertEqual(Transcript.end(in: failed), .failed(Date(timeIntervalSince1970: 1793854920), message: "stream disconnected before completion"))
        // Retrying is still going.
        XCTAssertNil(Transcript.end(in: String(failed.split(separator: "\n").dropLast().joined(separator: "\n"))))
    }

    func testTheLiveProcessTable() throws {
        let table = Processes.table()
        XCTAssertGreaterThan(table.count, 10)
        let me = try XCTUnwrap(table[getpid()])
        XCTAssertEqual(me.parent, getppid())
        XCTAssertLessThan(abs(me.start.timeIntervalSince(try XCTUnwrap(Processes.startTime(of: getpid())))), 0.001)
        // A command started now is a descendant started after a moment ago.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        let before = Date().addingTimeInterval(-1)
        try child.run()
        defer { child.terminate() }
        XCTAssertTrue(Processes.hasDescendant(of: getpid(), startedAfter: before, in: Processes.table()))
    }

    func testDescendantsStartedSinceAWaitAreCommandsInFlight() {
        let then = Date(timeIntervalSince1970: 1000)
        let table: [pid_t: (parent: pid_t, start: Date)] = [
            10: (1, then.addingTimeInterval(-9000)),     // the Codex app-server
            11: (10, then.addingTimeInterval(-9000)),    // an MCP server it started long ago
            12: (10, then.addingTimeInterval(5)),        // a shell it started for a command
            13: (12, then.addingTimeInterval(6)),        // the command
            20: (1, then.addingTimeInterval(50)),        // something unrelated
        ]
        XCTAssertTrue(Processes.hasDescendant(of: 10, startedAfter: then, in: table))
        XCTAssertFalse(Processes.hasDescendant(of: 10, startedAfter: then.addingTimeInterval(10), in: table))
        XCTAssertFalse(Processes.hasDescendant(of: 11, startedAfter: then, in: table))
    }
}

final class VersionTests: XCTestCase {
    func testNewerReleases() {
        XCTAssertTrue(Version.isNewer("0.5.0", than: "0.4.7"))
        XCTAssertTrue(Version.isNewer("v0.4.10", than: "0.4.9"), "numbers, not text")
        XCTAssertTrue(Version.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(Version.isNewer("0.5.0", than: "0.5.0"))
        XCTAssertFalse(Version.isNewer("0.5", than: "0.5.0"))
        XCTAssertFalse(Version.isNewer("0.4.7", than: "0.5.0"))
    }
}

final class ChargeLimitTests: XCTestCase {
    func testHoldsFromTheLimitAndResumesBelowIt() {
        // Charging up: it goes on until the limit, then holds.
        XCTAssertFalse(ChargeLimit.holds(level: 79, limit: 80, holding: false))
        XCTAssertTrue(ChargeLimit.holds(level: 80, limit: 80, holding: false))
        XCTAssertTrue(ChargeLimit.holds(level: 97, limit: 80, holding: false))
        // Running down from the limit: it stays held until 5 points under, then charges again.
        XCTAssertTrue(ChargeLimit.holds(level: 76, limit: 80, holding: true))
        XCTAssertTrue(ChargeLimit.holds(level: 75, limit: 80, holding: true))
        XCTAssertFalse(ChargeLimit.holds(level: 74, limit: 80, holding: true))
        // No limit: always charges.
        XCTAssertFalse(ChargeLimit.holds(level: 100, limit: nil, holding: true))
    }

    func testFirmwareLimitPercentagesAreLittleEndian() {
        XCTAssertEqual(ChargeLimit.Switch.bytes(80), [0x50, 0, 0, 0])
        XCTAssertEqual(ChargeLimit.Switch.percent([0x4b, 0, 0, 0]), 75)
        XCTAssertNil(ChargeLimit.Switch.percent([0x4b]))
    }

    func testReadsOnlyASensibleLimit() {
        XCTAssertEqual(ChargeLimit.limit(from: "80\n"), 80)
        XCTAssertEqual(ChargeLimit.limit(from: " 50 "), 50)
        XCTAssertNil(ChargeLimit.limit(from: nil))
        XCTAssertNil(ChargeLimit.limit(from: "off"))
        XCTAssertNil(ChargeLimit.limit(from: "100"))
        XCTAssertNil(ChargeLimit.limit(from: "20"))
    }
}
