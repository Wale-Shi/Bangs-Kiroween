import CoreGraphics
import XCTest
@testable import Bangs
import BangsCore

final class ToolsTests: XCTestCase {
    override class func setUp() { TestData.isolate }

    /// A "page" of distinct rows, and frames looking at it from different scroll offsets.
    private func page(rows: Int, width: Int = 120) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: rows * width)
        var seed: UInt32 = 7
        for row in 0..<rows {
            // A few rows repeat their neighbour, like blank lines on a real page.
            if row % 9 == 4 { for x in 0..<width { pixels[row * width + x] = pixels[(row - 1) * width + x] }; continue }
            for x in 0..<width {
                // Xorshift: a plain LCG's low bytes repeat every 65,536 pixels, making far-apart rows look alike.
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                pixels[row * width + x] = seed | 0xFF00_0000
            }
        }
        return pixels
    }

    private func frame(_ page: [UInt32], from top: Int, height: Int, width: Int = 120, jitter: UInt32 = 0) -> CGImage {
        var slice = Array(page[(top * width)..<((top + height) * width)])
        if jitter > 0 {
            // Apps redraw text slightly differently after a scroll: nudge every channel a little.
            var seed = UInt32(top) &+ 99
            for i in slice.indices {
                var pixel = slice[i]
                for shift in [0, 8, 16] as [UInt32] {
                    seed = seed &* 1_103_515_245 &+ 12345
                    let channel = Int((pixel >> shift) & 0xFF) + Int((seed >> 16) % (jitter * 2 + 1)) - Int(jitter)
                    pixel = (pixel & ~(0xFF << shift)) | (UInt32(max(0, min(255, channel))) << shift)
                }
                slice[i] = pixel
            }
        }
        let context = CGContext(data: &slice, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testStitcherJoinsScrolledFramesIntoThePage() {
        let page = page(rows: 400)
        let stitcher = Stitcher()
        for top in [0, 37, 37, 90, 151, 200] { stitcher.add(frame(page, from: top, height: 200)) }
        XCTAssertEqual(stitcher.height, 400)
        let image = stitcher.compose()!
        XCTAssertEqual(Stitcher.signatures(image), Stitcher.signatures(frame(page, from: 0, height: 400)))
    }

    func testStitcherToleratesRedrawnText() {
        let page = page(rows: 400)
        let stitcher = Stitcher()
        for top in [0, 37, 37, 90, 151, 200] { stitcher.add(frame(page, from: top, height: 200, jitter: 10)) }
        XCTAssertFalse(stitcher.lost)
        XCTAssertEqual(stitcher.height, 400)
    }

    /// Scrolling back over what was captured adds nothing, however the page is scrolled afterwards.
    func testStitcherScrollingBackAddsNothing() {
        let page = page(rows: 600)
        let stitcher = Stitcher()
        for top in [0, 60, 130, 70, 20, 90, 200, 330, 400] { stitcher.add(frame(page, from: top, height: 200)) }
        XCTAssertFalse(stitcher.lost)
        XCTAssertEqual(stitcher.height, 600)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(frame(page, from: 0, height: 600)))
    }

    /// A list of look-alike rows (a chat, a table): only a small label differs from row to row. Scrolling back up used
    /// to find a false match further down and paste a stretch in twice.
    func testStitcherOnLookAlikeRowsScrolledBackAndForth() {
        let width = 160, rows = 900
        var page = [UInt32](repeating: 0xFFFF_FFFF, count: rows * width)
        for row in 0..<rows {
            let item = row / 30, inItem = row % 30
            for x in 0..<width {
                var gray: UInt32 = 255
                if inItem == 0 { gray = 200 }                                               // divider
                else if (8...20).contains(inItem) && (10..<80).contains(x) { gray = 60 }    // the same text block on every row
                else if (8...20).contains(inItem) && (80..<112).contains(x) {               // a label that differs:
                    gray = ((x / 8) * 3 + item) % 7 < 3 ? 40 : 240                          // words of other lengths
                }
                page[row * width + x] = 0xFF00_0000 | gray << 16 | gray << 8 | gray
            }
        }
        let stitcher = Stitcher()
        for top in [0, 20, 45, 70, 50, 25, 40, 75, 110, 150, 120, 160, 200, 240, 280, 320, 360, 400, 440, 480, 520, 560, 600, 640, 700] {
            stitcher.add(frame(page, from: top, height: 200, width: width))
        }
        XCTAssertEqual(stitcher.height, 900)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(frame(page, from: 0, height: 900, width: width)))
    }

    /// Started mid-page and scrolled up: what lies above joins the top.
    func testStitcherExtendsAboveWhereItStarted() {
        let page = page(rows: 400)
        let stitcher = Stitcher()
        for top in [200, 140, 60, 100] { stitcher.add(frame(page, from: top, height: 200)) }
        XCTAssertEqual(stitcher.height, 340)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(frame(page, from: 60, height: 340)))
    }

    /// A wide table or timeline scrolled to the right.
    func testStitcherScrollsSideways() {
        let wide = page(rows: 160, width: 700)
        let stitcher = Stitcher()
        for left in [0, 45, 120, 80, 200, 320, 430, 500] { stitcher.add(columns(wide, width: 700, from: left, count: 200)) }
        XCTAssertEqual(stitcher.axis, .horizontal)
        XCTAssertFalse(stitcher.lost)
        XCTAssertEqual(stitcher.length, 700)
        let image = stitcher.compose()!
        XCTAssertEqual(image.width, 700)
        XCTAssertEqual(image.height, 160)
        XCTAssertEqual(Stitcher.signatures(image), Stitcher.signatures(columns(wide, width: 700, from: 0, count: 700)))
    }

    /// A frame of a window whose toolbar and input bar stay put while the page between them scrolls.
    private func framed(_ page: [UInt32], from top: Int, height: Int, header: [UInt32], footer: [UInt32], width: Int = 120) -> CGImage {
        var slice = header + Array(page[(top * width)..<((top + height) * width)]) + footer
        let rows = slice.count / width
        let context = CGContext(data: &slice, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func stacked(_ parts: [UInt32]..., width: Int = 120) -> CGImage {
        var slice = parts.flatMap { $0 }
        let context = CGContext(data: &slice, width: width, height: slice.count / width, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// A chat or a web page with a bar at the bottom: the bar used to be taken with every frame's new rows, so it came
    /// out repeated down the image, over the page that was under it. It belongs once, at the end; the header once, at
    /// the top.
    func testStitcherKeepsAFixedHeaderAndFooterOutOfThePage() {
        let width = 120
        let page = page(rows: 700), bars = self.page(rows: 70)
        let header = Array(bars[0..<(30 * width)]), footer = Array(bars[(30 * width)...])
        let stitcher = Stitcher()
        for top in [0, 40, 95, 150, 150, 230, 300, 380, 440] { stitcher.add(framed(page, from: top, height: 200, header: header, footer: footer)) }
        XCTAssertFalse(stitcher.lost)
        XCTAssertEqual(stitcher.axis, .vertical)
        XCTAssertEqual(stitcher.fixed.lead, 30)
        XCTAssertEqual(stitcher.fixed.trail, 40)
        XCTAssertEqual(stitcher.height, 30 + 640 + 40)
        let whole = stacked(header, Array(page[0..<(640 * width)]), footer)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(whole))
    }

    /// Bars that take up more of the frame than the page does: the rows that stay put used to outvote the ones that
    /// moved, and the capture said it had lost its place from the first scroll.
    func testStitcherFollowsAPageUnderTallBars() {
        let width = 120
        let page = page(rows: 500), bars = self.page(rows: 220)
        let header = Array(bars[0..<(120 * width)]), footer = Array(bars[(120 * width)...])
        let stitcher = Stitcher()
        for top in [0, 30, 70, 120, 160, 210, 260, 300] { stitcher.add(framed(page, from: top, height: 180, header: header, footer: footer)) }
        XCTAssertFalse(stitcher.lost)
        let whole = stacked(header, Array(page[0..<(480 * width)]), footer)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(whole))
    }

    /// Started mid-page and scrolled both ways between the bars: the header stays at the top, the footer at the bottom.
    func testStitcherWithFixedBarsExtendsBothWays() {
        let width = 120
        let page = page(rows: 700), bars = self.page(rows: 70)
        let header = Array(bars[0..<(30 * width)]), footer = Array(bars[(30 * width)...])
        let stitcher = Stitcher()
        for top in [300, 350, 410, 350, 280, 220, 160, 100, 180] { stitcher.add(framed(page, from: top, height: 200, header: header, footer: footer)) }
        XCTAssertFalse(stitcher.lost)
        let whole = stacked(header, Array(page[(100 * width)..<(610 * width)]), footer)
        XCTAssertEqual(stitcher.height, 30 + 510 + 40)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(whole))
    }

    /// A blank margin at the bottom of the frame looks fixed from one frame to the next, and is not: the page it
    /// belongs to still comes out whole.
    func testStitcherIsNotFooledByABlankMargin() {
        let width = 120
        var page = page(rows: 600)
        // Blank bands, as between sections of a page.
        for row in 0..<600 where (row / 50) % 3 == 2 { for x in 0..<width { page[row * width + x] = 0xFFFF_FFFF } }
        let stitcher = Stitcher()
        for top in stride(from: 0, through: 400, by: 25) { stitcher.add(frame(page, from: top, height: 200)) }
        XCTAssertFalse(stitcher.lost)
        XCTAssertEqual(stitcher.height, 600)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(frame(page, from: 0, height: 600)))
    }

    /// Many pages, with blank bands and with or without bars, scrolled to and fro by random amounts: the image is always
    /// the bars around exactly the part of the page that was seen.
    func testStitcherOnRandomScrolls() {
        let width = 120
        var seed: UInt64 = 42
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        for round in 0..<30 {
            var page = page(rows: 1200)
            if round % 2 == 0 {
                let period = random(60...200), blank = random(10...period / 4)
                for row in 0..<1200 where row % period < blank { for x in 0..<width { page[row * width + x] = 0xFFFF_FFFF } }
            }
            let bars = self.page(rows: 120)
            let lead = round % 4 < 2 ? 0 : random(1...50), trail = round % 3 == 0 ? 0 : random(1...60)
            let header = Array(bars[0..<(lead * width)]), footer = Array(bars[(60 * width)..<((60 + trail) * width)])
            let height = random(120...260)
            var top = random(300...600)
            var low = top, high = top
            let stitcher = Stitcher()
            stitcher.add(framed(page, from: top, height: height, header: header, footer: footer))
            // The first move is one way and far enough to count; after it, anything that leaves two thirds of the page in
            // view, which is more than a blank band of it: with less, there may be nothing to line the frames up by.
            let first = random(20...40) * (round % 5 == 0 ? -1 : 1)
            for step in 0..<30 {
                let move = step < 2 ? first : random(-height / 3...height / 3)
                top = min(max(top + move, 0), 1200 - height)
                low = min(low, top)
                high = max(high, top)
                stitcher.add(framed(page, from: top, height: height, header: header, footer: footer))
                XCTAssertFalse(stitcher.lost, "round \(round) step \(step)")
            }
            let whole = stacked(header, Array(page[(low * width)..<((high + height) * width)]), footer)
            XCTAssertEqual(stitcher.height, whole.height, "round \(round)")
            XCTAssertTrue(Stitcher.signatures(stitcher.compose()!) == Stitcher.signatures(whole), "round \(round)")
        }
    }

    /// Framed but never scrolled: the screenshot is the frame itself.
    func testStitcherWithoutScrollingKeepsTheFrame() {
        let page = page(rows: 300)
        let stitcher = Stitcher()
        stitcher.add(frame(page, from: 0, height: 200))
        stitcher.add(frame(page, from: 0, height: 200))
        XCTAssertNil(stitcher.axis)
        XCTAssertEqual(stitcher.compose()?.height, 200)
    }

    private func columns(_ page: [UInt32], width: Int, from left: Int, count: Int) -> CGImage {
        let rows = page.count / width
        var slice = [UInt32]()
        for row in 0..<rows { slice += page[(row * width + left)..<(row * width + left + count)] }
        let context = CGContext(data: &slice, width: count, height: rows, bitsPerComponent: 8, bytesPerRow: count * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testStitcherRecoversAfterScrollingTooFast() {
        let page = page(rows: 600)
        let stitcher = Stitcher()
        stitcher.add(frame(page, from: 0, height: 200))
        stitcher.add(frame(page, from: 250, height: 200))   // no overlap with the first frame
        XCTAssertTrue(stitcher.lost)
        XCTAssertEqual(stitcher.height, 200)
        stitcher.add(frame(page, from: 120, height: 200))   // scrolled back: overlaps again
        XCTAssertFalse(stitcher.lost)
        stitcher.add(frame(page, from: 300, height: 200))
        XCTAssertEqual(stitcher.height, 500)
        XCTAssertEqual(Stitcher.signatures(stitcher.compose()!), Stitcher.signatures(frame(page, from: 0, height: 500)))
    }

    @MainActor func testClipboardKinds() {
        XCTAssertEqual(ClipboardHistory.kind(of: "https://github.com/Wale-Shi/Bangs"), .link)
        XCTAssertEqual(ClipboardHistory.kind(of: "#E08A6A"), .color)
        XCTAssertEqual(ClipboardHistory.kind(of: "rgb(10, 20, 30)"), .color)
        XCTAssertEqual(ClipboardHistory.kind(of: "func toggle() {\n    go(.expanded)\n}"), .code)
        XCTAssertEqual(ClipboardHistory.kind(of: "把剪贴板暂存区的功能做进去"), .text)
        XCTAssertEqual(ClipboardHistory.kind(of: "see https://example.com for details"), .text)
    }

    @MainActor func testMeetingLinks() {
        let notes = "议程见文档\n加入会议：https://vc.feishu.cn/j/123456789\n"
        XCTAssertEqual(Agenda.joinLink(in: [notes])?.absoluteString, "https://vc.feishu.cn/j/123456789")
        XCTAssertEqual(Agenda.joinLink(in: ["<https://us02web.zoom.us/j/8765?pwd=abc>"]).flatMap(Agenda.service), "Zoom")
        XCTAssertEqual(Agenda.joinLink(in: ["https://meeting.tencent.com/dm/AbC"]).flatMap(Agenda.service), "腾讯会议")
        XCTAssertNil(Agenda.joinLink(in: ["3F 会议室"]))
    }
}

final class SessionFilterTests: XCTestCase {
    @MainActor func testCodexTitleRequestsAreNotSessions() {
        let store = SessionStore()
        let title = "You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task."
        store.receive(HookEnvelope(harness: .codex, native: "UserPromptSubmit", pid: getpid(), payload: ["session_id": "t", "cwd": "/tmp/bang-2", "prompt": title]), reply: nil)
        store.receive(HookEnvelope(harness: .codex, native: "Stop", pid: getpid(), payload: ["session_id": "t", "cwd": "/tmp/bang-2", "last_assistant_message": #"{"title":"扫描电脑"}"#]), reply: nil)
        store.receive(HookEnvelope(harness: .codex, native: "UserPromptSubmit", pid: getpid(), payload: ["session_id": "real", "cwd": "/tmp/bang-2", "prompt": "帮我扫描一下这台电脑"]), reply: nil)
        XCTAssertEqual(store.sessions.map(\.id), ["codex:real"])
    }

    /// Threads the Codex app runs for itself: its approval reviewer, sub-agents, and requests that say they are
    /// app-generated. Your own conversations and automations still show.
    @MainActor func testCodexAppThreadsAreNotSessions() throws {
        let store = SessionStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func transcript(_ id: String, _ source: String) throws -> String {
            let file = folder.appendingPathComponent("\(id).jsonl")
            let instructions = String(repeating: "base instructions ", count: 2000)   // the real first record is ~20 KB
            try Data((#"{"type":"session_meta","payload":{"id":"\#(id)","base_instructions":"\#(instructions)","#
                      + source + "}}\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n").utf8).write(to: file)
            return file.path
        }
        let threads = [
            ("guardian", try transcript("guardian", #""source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review""#), "Review this approval request"),
            ("explorer", try transcript("explorer", #""source":{"subagent":{"thread_spawn":{"depth":1}}}"#), "Explore the repo"),
            ("mine", try transcript("mine", #""source":"vscode","thread_source":"user""#), "修一下登录"),
            ("auto", try transcript("auto", #""source":"vscode","thread_source":"automation""#), "Automation: 美股盘前短报"),
            ("generated", try transcript("generated", #""source":"vscode""#), "This is an app-generated request to summarise the thread."),
        ]
        for (id, path, prompt) in threads {
            store.receive(HookEnvelope(harness: .codex, native: "UserPromptSubmit", pid: getpid(),
                                       payload: ["session_id": id, "cwd": "/tmp/app", "prompt": prompt, "transcript_path": path]), reply: nil)
            store.receive(HookEnvelope(harness: .codex, native: "Stop", pid: getpid(), payload: ["session_id": id, "cwd": "/tmp/app", "transcript_path": path]), reply: nil)
        }
        XCTAssertEqual(Set(store.sessions.map(\.id)), ["codex:mine", "codex:auto"])
    }
}

final class ApprovalSyncTests: XCTestCase {
    /// A request answered in the terminal: the CLI carries on but leaves Bangs' hook waiting.
    @MainActor func testApprovalAnsweredElsewhereLeavesTheNotch() {
        let store = SessionStore()
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let ask = { (tool: String) in
            store.receive(HookEnvelope(harness: .claude, native: "PermissionRequest", pid: getpid(),
                                       payload: ["session_id": "s", "cwd": "/tmp", "tool_name": tool, "tool_input": ["command": "rm -rf build"]]),
                          reply: PendingReply(fd: pair[0], onHangUp: {}))
        }
        ask("Bash")
        XCTAssertEqual(store.approvals.count, 1)
        XCTAssertEqual(store.sessions.first?.status, .approval)

        // Another tool finishing says nothing about this request.
        store.receive(HookEnvelope(harness: .claude, native: "PostToolUse", pid: getpid(), payload: ["session_id": "s", "tool_name": "Read"]), reply: nil)
        XCTAssertEqual(store.approvals.count, 1)

        // The command ran: it was allowed in the terminal.
        store.receive(HookEnvelope(harness: .claude, native: "PostToolUse", pid: getpid(), payload: ["session_id": "s", "tool_name": "Bash"]), reply: nil)
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.sessions.first?.status, .working)
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertGreaterThan(read(pair[1], &buffer, buffer.count), 0, "the waiting hook is told to stand down")
    }

    /// Switched to running without approvals mid-turn (Codex's full access, Claude Code's bypass mode): the request
    /// showing goes, and later ones are not asked.
    @MainActor func testRunningWithoutApprovalsAsksNothing() {
        let store = SessionStore()
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        func event(_ native: String, mode: String, reply: PendingReply? = nil) {
            store.receive(HookEnvelope(harness: .codex, native: native, pid: getpid(),
                                       payload: ["session_id": "s", "cwd": "/tmp", "tool_name": "Bash", "tool_input": ["command": "npm test"],
                                                 "permission_mode": mode]), reply: reply)
        }
        event("PermissionRequest", mode: "default", reply: PendingReply(fd: pair[0], onHangUp: {}))
        XCTAssertEqual(store.approvals.count, 1)

        event("PreToolUse", mode: "bypassPermissions")
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.sessions.first?.status, .working)
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertGreaterThan(read(pair[1], &buffer, buffer.count), 0, "the waiting hook is told to stand down")

        var second: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &second), 0)
        defer { close(second[1]) }
        event("PermissionRequest", mode: "dontAsk", reply: PendingReply(fd: second[0], onHangUp: {}))
        XCTAssertTrue(store.approvals.isEmpty, "nothing is asked while the CLI approves everything")
        XCTAssertEqual(store.sessions.first?.status, .working)
        XCTAssertGreaterThan(read(second[1], &buffer, buffer.count), 0, "and the hook is answered at once")
    }

    /// Two calls of one tool wait at once (parallel calls, or a sub-agent's): the one that ran takes only its own
    /// request away.
    @MainActor func testSameToolRunningSettlesOnlyItsOwnRequest() {
        let store = SessionStore()
        var pairs: [[Int32]] = []
        defer { for pair in pairs { close(pair[1]) } }
        func ask(_ payload: [String: Any]) {
            var pair: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            pairs.append(pair)
            store.receive(HookEnvelope(harness: .claude, native: "PermissionRequest", pid: getpid(),
                                       payload: ["session_id": "s", "cwd": "/tmp", "tool_name": "Bash"].merging(payload) { $1 }),
                          reply: PendingReply(fd: pair[0], onHangUp: {}))
        }
        func ran(_ payload: [String: Any]) {
            store.receive(HookEnvelope(harness: .claude, native: "PostToolUse", pid: getpid(),
                                       payload: ["session_id": "s", "tool_name": "Bash"].merging(payload) { $1 }), reply: nil)
        }

        // Told apart by input.
        ask(["tool_input": ["command": "make build"]])
        ask(["tool_input": ["command": "rm -rf build"]])
        ran(["tool_input": ["command": "make build", "description": "Build"], "tool_use_id": "toolu_1"])
        XCTAssertEqual(store.approvals.map(\.summary), ["rm -rf build"])
        XCTAssertEqual(store.sessions.first?.status, .approval)
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertGreaterThan(read(pairs[0][1], &buffer, buffer.count), 0, "the request that ran is handed back")
        var flags = fcntl(pairs[1][1], F_GETFL)
        XCTAssertNotEqual(fcntl(pairs[1][1], F_SETFL, flags | O_NONBLOCK), -1)
        XCTAssertEqual(read(pairs[1][1], &buffer, buffer.count), -1, "the other is still waiting")
        ran(["tool_input": ["command": "rm -rf build"]])
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.sessions.first?.status, .working)

        // Told apart by the CLI's call id, when both carry one.
        ask(["tool_input": ["command": "npm test"], "tool_use_id": "toolu_a"])
        ask(["tool_input": ["command": "npm test"], "tool_use_id": "toolu_b"])
        ran(["tool_input": ["command": "npm test"], "tool_use_id": "toolu_b"])
        XCTAssertEqual(store.approvals.map(\.toolUseId), ["toolu_a"])
        flags = fcntl(pairs[2][1], F_GETFL)
        XCTAssertNotEqual(fcntl(pairs[2][1], F_SETFL, flags | O_NONBLOCK), -1)
        XCTAssertEqual(read(pairs[2][1], &buffer, buffer.count), -1, "toolu_a is still waiting")

        // Nothing to compare: the name still settles it, rather than leaving it up for good.
        ran([:])
        XCTAssertTrue(store.approvals.isEmpty)
    }

    @MainActor func testTurnEndClearsADeniedRequest() {
        let store = SessionStore()
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        store.receive(HookEnvelope(harness: .codex, native: "PermissionRequest", pid: getpid(), payload: ["session_id": "s", "cwd": "/tmp", "tool_name": "shell"]),
                      reply: PendingReply(fd: pair[0], onHangUp: {}))
        store.receive(HookEnvelope(harness: .codex, native: "Stop", pid: getpid(), payload: ["session_id": "s", "last_assistant_message": "OK, I won't."]), reply: nil)
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.sessions.first?.status, .finished)
    }
}

final class NotchStyleTests: XCTestCase {
    @MainActor func testHiddenKeepsToTheNotchUntilADecision() {
        let preferences = Preferences()
        let saved = preferences.notchStyle
        defer { preferences.notchStyle = saved }
        preferences.notchStyle = .hidden
        let store = SessionStore()
        let model = NotchModel(store: store, preferences: preferences, toolbox: Toolbox(preferences: preferences),
                               geometry: NotchGeometry(notchWidth: 185, height: 32, screen: NSScreen.screens[0]))
        store.receive(HookEnvelope(harness: .claude, native: "UserPromptSubmit", pid: getpid(), payload: ["session_id": "s", "cwd": "/tmp", "prompt": "go"]), reply: nil)
        model.hovered = true
        XCTAssertTrue(model.retracted, "a running session keeps the hidden island in the notch")
        XCTAssertEqual(model.width, 185)
        XCTAssertEqual(model.ear, 0)
        XCTAssertFalse(model.swells)

        store.receive(HookEnvelope(harness: .gemini, native: "Notification", pid: getpid(), payload: ["session_id": "g", "notification_type": "permission_prompt", "message": "rm -rf build"]), reply: nil)
        let opened = expectation(description: "approval opens the island")
        DispatchQueue.main.async { DispatchQueue.main.async { opened.fulfill() } }
        wait(for: [opened], timeout: 2)
        XCTAssertEqual(model.mode, .approval)
        XCTAssertFalse(model.retracted)
        XCTAssertGreaterThan(model.width, 185)

        // Always shown: the same running session sits beside the notch.
        preferences.notchStyle = .always
        let shown = NotchModel(store: SessionStore(), preferences: preferences, toolbox: Toolbox(preferences: preferences),
                               geometry: NotchGeometry(notchWidth: 185, height: 32, screen: NSScreen.screens[0]))
        XCTAssertFalse(shown.retracted)
        XCTAssertEqual(shown.width, 185 + shown.sideWidth * 2)
    }
}

final class InterruptTests: XCTestCase {
    @MainActor func testInterruptedTurnStopsLookingBusy() throws {
        let store = SessionStore()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        try Data((#"{"type":"user","timestamp":"\#(old)","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8).write(to: file)
        store.receive(HookEnvelope(harness: .claude, native: "PreToolUse", pid: getpid(),
                                   payload: ["session_id": "s", "cwd": "/tmp", "tool_name": "Bash", "tool_input": ["command": "ping"], "transcript_path": file.path]), reply: nil)
        // An interruption from an earlier turn changes nothing.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .working)

        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"user","timestamp":"\#(now)","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"# + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .idle)
        XCTAssertEqual(store.sessions.first?.lastMessage, "已中断")
    }
}


/// Codex's desktop app runs every conversation in one long-lived app-server, so a turn that dies takes no process with it.
final class DeadTurnTests: XCTestCase {
    private func codexEvent(_ native: String, _ extra: [String: Any] = [:], transcript: URL? = nil) -> HookEnvelope {
        var payload: [String: Any] = ["session_id": "t", "cwd": "/tmp/app"]
        if let transcript { payload["transcript_path"] = transcript.path }
        return HookEnvelope(harness: .codex, native: native, pid: getpid(), payload: payload.merging(extra) { $1 })
    }

    private func write(_ lines: [String], to file: URL, modified: Date) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @MainActor func testATurnTheTranscriptEndsIsToldOnce() throws {
        let store = SessionStore()
        store.watching = { _ in false }
        var told = 0
        store.onFinished = { _ in told += 1 }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date()
        store.now = { start }
        store.receive(codexEvent("UserPromptSubmit", ["prompt": "修一下"], transcript: file), reply: nil)
        let end = start.addingTimeInterval(5)
        try write([#"{"timestamp":"\#(stamp(end))","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"修好了"}}"#], to: file, modified: end)

        // The Stop hook usually follows at once: give it a moment.
        store.now = { end.addingTimeInterval(2) }
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .working)

        store.now = { end.addingTimeInterval(20) }
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .finished)
        XCTAssertEqual(store.sessions.first?.lastMessage, "修好了")
        XCTAssertEqual(told, 1)

        // A Stop hook arriving after all does not tell you twice.
        store.receive(codexEvent("Stop", ["last_assistant_message": "修好了"]), reply: nil)
        XCTAssertEqual(told, 1)
        XCTAssertEqual(store.sessions.first?.status, .finished)
    }

    @MainActor func testAFailedTurnSaysSo() throws {
        let store = SessionStore()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date()
        store.now = { start }
        store.receive(codexEvent("UserPromptSubmit", ["prompt": "跑测试"], transcript: file), reply: nil)
        let end = start.addingTimeInterval(3)
        try write([#"{"timestamp":"\#(stamp(end))","type":"event_msg","payload":{"type":"error","message":"stream disconnected before completion"}}"#], to: file, modified: end)
        store.now = { end.addingTimeInterval(1) }
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .finished)
        XCTAssertEqual(store.sessions.first?.lastMessage, "出错：stream disconnected before completion")
    }

    @MainActor func testLongIdleSessionsLeaveTheListButUnseenResultsStay() {
        let store = SessionStore()
        let start = Date()
        store.now = { start }
        store.receive(codexEvent("SessionStart"), reply: nil)
        var other = codexEvent("Stop", ["last_assistant_message": "好了"])
        other.payload["session_id"] = "u"
        store.receive(other, reply: nil)
        let unseen = store.sessions.first { $0.id.hasSuffix(":u") }?.unseen ?? false

        store.now = { start.addingTimeInterval(SessionStore.forgotten + 60) }
        store.reap()
        XCTAssertNil(store.sessions.first { $0.id.hasSuffix(":t") }, "idle for half a day")
        XCTAssertEqual(store.sessions.contains { $0.id.hasSuffix(":u") }, unseen, "a result you have not seen stays")
    }

    @MainActor func testASilentTurnInASharedProcessEnds() {
        let store = SessionStore()
        // Bangs hears of the session well after its process (this test runner, standing in for the app-server) started.
        let start = Date().addingTimeInterval(300)
        store.now = { start }
        store.receive(codexEvent("UserPromptSubmit", ["prompt": "重构一下"]), reply: nil)
        store.receive(codexEvent("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "swift build"]]), reply: nil)

        store.now = { start.addingTimeInterval(SessionStore.silence - 30) }
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .working, "quiet for a while is not dead")

        store.now = { start.addingTimeInterval(SessionStore.silence + 30) }
        store.reap()
        XCTAssertEqual(store.sessions.first?.status, .idle)
        XCTAssertEqual(store.sessions.first?.lastMessage, "很久没有动静，可能已异常结束")
        XCTAssertFalse(store.active)

        // It was only quiet after all: the next event brings it back.
        store.receive(codexEvent("PostToolUse", ["tool_name": "Bash"]), reply: nil)
        XCTAssertEqual(store.sessions.first?.status, .working)
    }
}

final class AutoHideTests: XCTestCase {
    @MainActor func testTheLoadAloneDoesNotKeepTheIslandOut() {
        let preferences = Preferences()
        let (style, usage) = (preferences.notchStyle, preferences.usageInNotch)
        defer { preferences.notchStyle = style; preferences.usageInNotch = usage }
        preferences.notchStyle = .autoHide
        preferences.usageInNotch = .cpu
        let store = SessionStore()
        let model = NotchModel(store: store, preferences: preferences, toolbox: Toolbox(preferences: preferences),
                               geometry: NotchGeometry(notchWidth: 185, height: 32, screen: NSScreen.screens[0]))
        XCTAssertTrue(model.retracted, "nothing running: tucked into the notch, CPU or not")
        model.hovered = true
        XCTAssertFalse(model.retracted, "the pointer brings it out")
        model.hovered = false
        store.receive(HookEnvelope(harness: .claude, native: "UserPromptSubmit", pid: getpid(), payload: ["session_id": "s", "cwd": "/tmp", "prompt": "go"]), reply: nil)
        XCTAssertFalse(model.retracted, "an agent at work brings it out")
    }
}

final class NotchStatusTests: XCTestCase {
    func testOneThingIsSpelledOutAndSeveralNest() {
        let soon = Date().addingTimeInterval(120)
        XCTAssertFalse(NotchStatus(activity: .working).spelled, "the bars are shown as they are")
        XCTAssertTrue(NotchStatus(meeting: soon).spelled)
        XCTAssertTrue(NotchStatus(usage: 0.6).spelled)
        XCTAssertFalse(NotchStatus(activity: .working, meeting: soon).spelled)
        XCTAssertEqual(NotchStatus(activity: .working, meeting: soon, usage: 0.3).count, 3)
        XCTAssertTrue(NotchStatus().isEmpty)
        // Nested, the right side keeps its size; a spelled-out time needs room for its digits.
        XCTAssertEqual(NotchStatus(activity: .working, meeting: soon, usage: 0.3).width(), NotchGeometry.side)
        // Written out, a value takes the room its digits need now: two-digit percentages less than 100%.
        XCTAssertLessThan(NotchStatus(usage: 0.62).width(), NotchStatus(usage: 1).width())
        XCTAssertLessThanOrEqual(NotchStatus(meeting: Date().addingTimeInterval(272)).width(), NotchStatus(meeting: Date().addingTimeInterval(600)).width())
    }

    func testLoadDotsAndColours() {
        XCTAssertEqual(NotchStatus.lit(0.1), 0)
        XCTAssertEqual(NotchStatus.lit(0.25), 1)
        XCTAssertEqual(NotchStatus.lit(0.74), 2)
        XCTAssertEqual(NotchStatus.lit(0.75), 3)
        XCTAssertEqual(NotchStatus.lit(1), 4)
        XCTAssertEqual(NotchStatus.clock(272), "4:32")
        XCTAssertEqual(NotchStatus.clock(0.2), "0:01")
    }
}


final class PointerTests: XCTestCase {
    @MainActor func testEyesTurnTowardsThePointer() throws {
        // With Reduce motion on (as on CI's Macs) the eyes stay still by design.
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce motion is on")
        let pointer = Pointer()
        let face = CGPoint(x: 500, y: 1000)
        pointer.moved(to: CGPoint(x: 1300, y: 1000), face: face)
        XCTAssertEqual(pointer.look.width, 5, "far to the right: fully turned right")
        XCTAssertEqual(pointer.look.height, 0)
        pointer.moved(to: CGPoint(x: 500, y: 200), face: face)
        XCTAssertEqual(pointer.look.height, 3, "far below: looking down")
        pointer.moved(to: CGPoint(x: 400, y: 1000), face: face)
        XCTAssertLessThan(pointer.look.width, 0)
        XCTAssertGreaterThan(pointer.look.width, -5, "close by the eyes only turn a little")
        XCTAssertFalse(pointer.asleep)
    }
}

final class PendingReplyTests: XCTestCase {
    /// Reads until the other end is closed, which the reply does only once its source is cancelled.
    private func drain(_ fd: Int32) -> Data {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { XCTAssertEqual(count, 0, "closed, not timed out"); return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    func testAnswerIsWrittenThenTheConnectionClosed() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let hungUp = expectation(description: "no hang-up")
        hungUp.isInverted = true
        let reply = PendingReply(fd: pair[0]) { hungUp.fulfill() }
        reply.answer(.allow)
        reply.answer(.deny)
        XCTAssertEqual(drain(pair[1]), PermissionReply.allow.line, "one answer, then EOF")
        wait(for: [hungUp], timeout: 0.3)
    }

    func testHangUpIsToldOnceAndAnswersNothing() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let hungUp = expectation(description: "hang-up")
        hungUp.assertForOverFulfill = true
        let reply = PendingReply(fd: pair[0]) { hungUp.fulfill() }
        close(pair[1])
        wait(for: [hungUp], timeout: 2)
        reply.answer(.allow)
        // The descriptor went with the cancelled source: it is not open any more.
        let closed = expectation(description: "closed")
        DispatchQueue.global().async {
            for _ in 0..<200 {
                if fcntl(pair[0], F_GETFD) == -1 { closed.fulfill(); return }
                usleep(5000)
            }
        }
        wait(for: [closed], timeout: 2)
    }
}

/// Nothing wakes Bangs on a timer while there is nothing to watch.
final class IdleWakeTests: XCTestCase {
    @MainActor func testReaperRunsOnlyWithSessions() {
        let store = SessionStore()
        XCTAssertFalse(store.reaping)
        store.receive(HookEnvelope(harness: .claude, native: "UserPromptSubmit", pid: getpid(), payload: ["session_id": "s", "cwd": "/tmp", "prompt": "go"]), reply: nil)
        XCTAssertTrue(store.reaping)
        store.reap()
        store.receive(HookEnvelope(harness: .claude, native: "SessionEnd", pid: getpid(), payload: ["session_id": "s"]), reply: nil)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.reaping)
    }

    @MainActor func testSystemSamplingOnlyWhileShown() {
        let monitor = SystemMonitor()
        XCTAssertFalse(monitor.sampling)
        monitor.inNotch = true
        XCTAssertTrue(monitor.sampling)
        XCTAssertGreaterThan(monitor.memoryUsed, 0, "a first sample at once")
        monitor.watchingProcesses = true
        monitor.inNotch = false
        XCTAssertTrue(monitor.sampling, "the status tab still shows it")
        monitor.watchingProcesses = false
        XCTAssertFalse(monitor.sampling)
    }

    @MainActor func testAgendaWithoutMeetingsWakesOnlyToRefresh() {
        let agenda = Agenda()
        guard agenda.meetings.isEmpty else { return } // a test Mac with today's meetings and calendar access
        let now = Date()
        XCTAssertGreaterThan(agenda.nextWake(after: now).timeIntervalSince(now), Agenda.refreshInterval - 5)
    }
}
