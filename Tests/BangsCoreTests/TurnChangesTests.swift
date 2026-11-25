import XCTest
@testable import BangsCore

final class TurnChangesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Git.available, "no git on this Mac")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: String...) -> String? {
        Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"] + arguments, in: folder.path)
    }

    /// Only what the turn wrote counts: a file already changed before it and left alone does not, a new file and a
    /// commit made during it do.
    func testCountsOnlyWhatTheTurnWrote() throws {
        XCTAssertNil(Git.start(in: folder.path), "not a checkout yet")
        git("init", "-q")
        try write("a.txt", "one\ntwo\nthree\n")
        try write("b.txt", "b\n")
        try write(".gitignore", "build/\n")
        git("add", ".")
        git("commit", "-qm", "first")
        try write("b.txt", "b\nbefore the turn\n")
        try write("notes.txt", "mine\n")

        let start = try XCTUnwrap(Git.start(in: folder.path))
        // The stamps are to the second on some file systems: make the turn's writes land after them.
        Thread.sleep(forTimeInterval: 1.1)
        try write("a.txt", "one\n2\nthree\nfour\n")
        try write("Sources/New.swift", "let a = 1\nlet b = 2\n")
        try write("build/out.o", "ignored")
        git("add", "a.txt")
        git("commit", "-qm", "during the turn")

        let changes = try XCTUnwrap(Git.changes(since: start))
        XCTAssertEqual(changes.files.map(\.path), ["Sources/New.swift", "a.txt"])
        XCTAssertEqual(changes.files.map(\.added), [2, 2])
        XCTAssertEqual(changes.files.map(\.removed), [0, 1])
        XCTAssertEqual(changes.commits, 1)
        XCTAssertEqual(changes.summary, "+4 −1 · 2 个文件 · 1 次提交")

        let diff = try XCTUnwrap(Git.diff(of: changes.files[1], in: changes))
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .removed, .added, .context, .added])
        XCTAssertEqual(diff.firstLine, 1)
        let created = try XCTUnwrap(Git.diff(of: changes.files[0], in: changes))
        XCTAssertEqual(created.kind, .create)
        XCTAssertEqual(created.lines.count, 2)
    }

    func testUnifiedDiff() {
        let text = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,5 @@ struct App {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             let d = 5
        @@ -40,2 +41,2 @@ func run() {
        -    old()
        +    new()
        \\ No newline at end of file
        diff --git a/Old.swift b/Old.swift
        deleted file mode 100644
        --- a/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        """
        let files = Git.unified(text)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift", "Old.swift", "logo.png"])
        XCTAssertEqual(files[0].firstLine, 10)
        XCTAssertEqual(files[0].lines.map(\.kind), [.context, .removed, .added, .added, .context, .gap, .removed, .added])
        XCTAssertEqual(files[0].lines.compactMap(\.number), [10, 11, 12, 13, 41])
        XCTAssertEqual(files[0].added, 3)
        XCTAssertEqual(files[0].removed, 2)
        XCTAssertEqual(files[1].kind, .delete)
        XCTAssertEqual(files[2].lines, [])
    }
}

final class SessionRuleTests: XCTestCase {
    private func keys(_ command: String) -> Set<String>? { SessionRule.keys(of: command) }

    func testCommandKeys() {
        XCTAssertEqual(keys("swift build"), ["swift build"])
        XCTAssertEqual(keys("swift test --filter RiskTests 2>&1 | tail -20"), ["swift test", "tail"])
        XCTAssertEqual(keys("CI=1 npm run lint"), ["npm run"])
        XCTAssertEqual(keys("git -C ../x status"), ["git ../x"], "options with values read as the subcommand: narrower, never broader")
        XCTAssertEqual(keys("python3 scripts/gen.py --out x"), ["python3 scripts/gen.py"])
        XCTAssertEqual(keys("ls -la && cat README.md"), ["ls", "cat"])
        // Words that can hide another command, or a write.
        XCTAssertNil(keys("python3 -c 'import os'"))
        XCTAssertNil(keys("bash -lc 'make'"))
        XCTAssertNil(keys("echo $(whoami)"))
        XCTAssertNil(keys("find . -name '*.o' -delete"))
        XCTAssertNil(keys("ls | xargs rm"))
        XCTAssertNil(keys("echo hi > ~/.zshrc"))
        XCTAssertEqual(keys("swift build > /dev/null"), ["swift build"])
    }

    func testRulesCoverOnlyTheirKind() {
        let rule = SessionRule.rule(tool: "Bash", input: ["command": "swift build 2>&1 | tail -5"], risk: nil)
        XCTAssertEqual(rule?.title, "运行 swift build、tail")
        let rules = [rule].compactMap { $0 }
        func covered(_ command: String, tool: String = "Bash") -> Bool {
            SessionRule.covers(rules, tool: tool, input: ["command": command], risk: Risk.of(command: command, cwd: "/Users/me/app", home: "/Users/me"))
        }
        XCTAssertTrue(covered("swift build -c release"))
        XCTAssertTrue(covered("swift build | tail -40"))
        XCTAssertFalse(covered("swift test"))
        XCTAssertFalse(covered("swift build && rm notes.txt"))
        XCTAssertFalse(covered("swift build", tool: "Shell"))
    }

    /// Nothing flagged is answered by a rule, and nothing flagged makes one.
    func testFlaggedRequestsStayYours() {
        let push = Risk.of(command: "git push -f", cwd: "/Users/me/app", home: "/Users/me")
        XCTAssertNil(SessionRule.rule(tool: "Bash", input: ["command": "git push -f"], risk: push))
        let rules = [SessionRule(tool: "Bash", scope: .commands(["git push"]))]
        XCTAssertTrue(SessionRule.covers(rules, tool: "Bash", input: ["command": "git push origin main"], risk: nil))
        XCTAssertFalse(SessionRule.covers(rules, tool: "Bash", input: ["command": "git push -f"], risk: push))
        XCTAssertNil(SessionRule.rule(tool: AgentQuestion.tool, input: ["questions": []], risk: nil))
    }

    func testEditsAndOtherTools() {
        let edit = SessionRule.rule(tool: "Edit", input: ["file_path": "a.swift", "old_string": "a", "new_string": "b"], risk: nil)
        XCTAssertEqual(edit, SessionRule(tool: "Edit", scope: .edits))
        XCTAssertTrue(SessionRule.covers([edit!], tool: "Edit", input: ["file_path": "b.swift", "content": "x"], risk: nil))
        XCTAssertFalse(SessionRule.covers([edit!], tool: "Edit", input: ["file_path": "~/.zshrc", "content": "x"], risk: Risk(.caution, "outside")))
        XCTAssertFalse(SessionRule.covers([edit!], tool: "Write", input: ["file_path": "b.swift", "content": "x"], risk: nil))
        let fetch = SessionRule.rule(tool: "WebFetch", input: ["url": "https://example.dev"], risk: nil)
        XCTAssertEqual(fetch?.title, "所有 WebFetch 请求")
        XCTAssertTrue(SessionRule.covers([fetch!], tool: "WebFetch", input: ["url": "https://other.dev"], risk: nil))
    }
}
