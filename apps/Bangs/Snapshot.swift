import AppKit
import BangsCore
import SwiftUI

/// `Bangs --snapshot <file.png>` renders the icons and faces to an image without opening a window, for design review.
@MainActor
enum Snapshot {
    @MainActor
    static func render(to path: String) {
        LayerMotion.usesLayers = false
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("CLI 官方 logo（刘海里 / 设置窗口里）").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(Harness.allCases, id: \.self) { harness in
                    VStack(spacing: 6) {
                        HarnessIcon(harness: harness, size: 32).frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 10).fill(.black))
                        HarnessIcon(harness: harness, size: 22, onDark: false).frame(width: 44, height: 34).background(RoundedRectangle(cornerRadius: 8).fill(.white)).environment(\.colorScheme, .light)
                        Text(harness.displayName).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(width: 58)
                }
            }
            Text("刘海里（实际尺寸）：左边是哪个 Agent，右边它怎么样了").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 10) {
                ForEach(Array(notchSamples.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 0) {
                        ClosedNotch(harness: item.harness, others: item.others, status: item.status, pointer: Pointer(), awake: false,
                                    side: item.status.width())
                            .frame(width: 70 + item.status.width() * 2)
                    }
                    .frame(height: 32)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
                }
            }
            Text("没有刘海时：菜单栏图标（浅色 / 深色菜单栏），展开后挂在图标下").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    menuBar(.light)
                    menuBar(.dark)
                }
                VStack(spacing: 0) {
                    Rectangle().fill(Color(white: 0.85)).frame(height: 24)
                    NotchRoot(model: menuModel, store: menuStore).frame(width: 560, height: 260)
                }
                .frame(width: 560)
            }
        }
        .padding(24)
        .background(Color(white: 0.16))
        NotchRoot.solidPanel = true
        // `--keys`: the return key glyph, beside the font's ↩, on dark and light.
        if CommandLine.arguments.contains("--keys") {
            hosted(keysGallery(), size: NSSize(width: 760, height: 330), to: path)
            return
        }
        // `--new`: the island's newer states, drawn by AppKit since they hold text editors and scroll views.
        if CommandLine.arguments.contains("--new") {
            hosted(newGallery().environment(\.colorScheme, .dark), size: NSSize(width: 1240, height: 900), to: path)
            return
        }
        // `--extras`: limits and context in the session list, a turn's changes, allowing for the session, sending to an agent.
        if CommandLine.arguments.contains("--extras") {
            hosted(extrasGallery().environment(\.colorScheme, .dark), size: NSSize(width: 1160, height: 820), to: path)
            return
        }
        // `--translate`: the translation card done, translating, missing its language pack, and with nothing selected.
        if CommandLine.arguments.contains("--translate") {
            hosted(translateGallery().environment(\.colorScheme, .dark), size: NSSize(width: 1560, height: 510), to: path)
            return
        }
        // `--approvals`: requests on the card: diffs, flagged commands and edits, and a CLI that asks in the terminal.
        if CommandLine.arguments.contains("--approvals") {
            hosted(approvalsGallery().environment(\.colorScheme, .dark), size: NSSize(width: 1010, height: 830), to: path)
            return
        }
        // `--files`: the files tab before it starts, while indexing, idle and searching, over sample folders.
        if CommandLine.arguments.contains("--files") {
            hosted(filesGallery().environment(\.colorScheme, .dark), size: NSSize(width: 1140, height: 900), to: path)
            return
        }
        // `--settings <pane>`: the settings window, drawn by AppKit since ImageRenderer cannot draw forms.
        if let index = CommandLine.arguments.firstIndex(of: "--settings") {
            let pane = CommandLine.arguments.dropFirst(index + 1).first.flatMap(SettingsPane.init(rawValue:)) ?? .general
            settings(pane, to: path)
            return
        }
        let content: AnyView
        if CommandLine.arguments.contains("--states") {
            content = AnyView(statesGallery().environment(\.colorScheme, .dark))
        } else if CommandLine.arguments.contains("--notch") {
            content = AnyView(notchGallery().environment(\.colorScheme, .dark))
        } else if CommandLine.arguments.contains("--menubar") {
            content = AnyView(menuBarGallery())
        } else if CommandLine.arguments.contains("--tools") {
            content = AnyView(tools().padding(24).background(Color(white: 0.16)).environment(\.colorScheme, .dark))
        } else {
            content = AnyView(view.environment(\.colorScheme, .dark))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func settings(_ pane: SettingsPane, to path: String) {
        let settings = SettingsWindow(preferences: Preferences(), toolbox: toolbox)
        settings.show(pane)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Bangs 设置" }), let view = window.contentView?.superview else { return }
        // `--tall`: the whole pane, not just what fits in the window.
        if CommandLine.arguments.contains("--tall") { window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: 2400)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// A view in an offscreen window, cached to a PNG at 2x.
    private static func hosted(_ view: some View, size: NSSize, to path: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `Bangs --bench`: the animations that run while agents work, each on screen for 10 s, and the CPU time Bangs
    /// spent on them (the window server's share comes on top).
    static func bench() {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let status = NotchStatus(activity: .working, meeting: nil, lead: 300, usage: nil)
        let cases: [(String, AnyView)] = [
            ("idle (nothing moving)", AnyView(StatusGlyph(state: .idle(awake: false), dots: []))),
            ("menu bar icon, working", AnyView(StatusGlyph(state: .working, dots: [.running, .running, .finished]))),
            ("menu bar icon, approval", AnyView(StatusGlyph(state: .approval, dots: [.asking, .running]))),
            ("notch bars, working", AnyView(NotchStatusView(status: status).frame(width: 26, height: 32))),
            ("session row spinner", AnyView(Spinner(color: Palette.Shade.accent, size: 11))),
        ]
        for (name, view) in cases {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 60, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view.padding(8).background(Color.black).environment(\.colorScheme, .dark))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let start = cpu()
            RunLoop.main.run(until: Date().addingTimeInterval(10))
            print(String(format: "%-26@ %5.2f%% CPU", name as NSString, (cpu() - start) / 10 * 100))
            window.orderOut(nil)
        }
    }

    /// `Bangs --compare`: each animated state as layers (top) and as the SwiftUI drawing (bottom), side by side, for
    /// 8 s, to check that both move alike.
    static func compare() {
        let states: [(StatusGlyph.State, [StatusGlyph.Dot])] = [(.working, [.running, .running, .finished]), (.approval, [.asking, .running]),
                                                                (.finished, [.finished]), (.idle(awake: false), []), (.meeting(left: 0.4, awake: true), [])]
        let light = CommandLine.arguments.contains("light")
        let view = VStack(spacing: 12) {
            ForEach([true, false], id: \.self) { layers in
                HStack(spacing: 16) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, item in StatusGlyph(state: item.0, dots: item.1, size: 64, layers: layers) }
                    PulseBars(asking: false, running: true, size: 39).frame(width: 39, height: 39)
                    Spinner(color: Palette.Shade.accent, size: 39)
                }
            }
        }
        .padding(16).background(light ? Color.white : Color.black).environment(\.colorScheme, light ? .light : .dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.setFrameTopLeftPoint(NSPoint(x: 0, y: NSScreen.screens[0].frame.maxY - 40))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(8))
    }

    /// The files tab in each state, searching sample folders.
    static func filesGallery() -> some View {
        let root = Storage.directory("sample-files")
        let files = ["Projects/bangs/Sources/Bangs/NotchModel.swift", "Projects/bangs/Sources/Bangs/Tools/FileIndex.swift", "Projects/bangs/Sources/Bangs/Tools/FileSearch.swift",
                     "Projects/bangs/README.md", "Projects/bangs/node_modules/x/index.js", "Projects/notch-site/src/index.ts", "Projects/notch-site/src/NotchHero.tsx",
                     "Documents/合同/租房合同 2026.pdf", "Documents/notch 设计稿 v3.fig", "Downloads/Notchmeister-2.1.dmg", "Pictures/notch-mockup.png",
                     "Desktop/会议纪要 notch 讨论.md", "Movies/notch demo.mov", "Applications/Notch Manager.app/Contents/Info.plist"]
        for file in files {
            let url = root.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        let off = Preferences()
        off.fileSearch = false
        let on = Preferences()
        on.fileSearch = true
        // Only these samples: the next snapshot or run must not start indexing this Mac.
        UserDefaults.standard.removeObject(forKey: "fileSearch")
        let sample: (Bool, [String]) -> FileIndex.Scope = { _, exclusions in
            FileIndex.Scope(roots: [root.path], skipPaths: [], skipNames: Set(exclusions.map { $0.lowercased() }))
        }
        let search = FileSearch(preferences: on, index: FileIndex(file: nil))
        let idle = FileSearch(preferences: on, index: FileIndex(file: nil))
        search.scope = sample
        idle.scope = sample
        let deadline = Date().addingTimeInterval(5)
        while !(search.index.settled && idle.index.settled), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        search.query = "notch"
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        search.selection = 1
        let model = NotchModel(store: menuStore, preferences: on, toolbox: toolbox, geometry: NotchGeometry(menuBarItem: nil, screen: NSScreen.screens[0]))
        func island(_ view: some View) -> some View {
            view.padding(.horizontal, 20).padding(.vertical, 14).frame(width: 540, alignment: .topLeading)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24).fill(.black))
        }
        let notched = NotchModel(store: menuStore, preferences: on, toolbox: toolbox, geometry: NotchGeometry(notchWidth: 200, height: 32, screen: NSScreen.screens[0]))
        notched.tool = .files
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                island(ToolboxView(model: notched, store: menuStore).frame(height: 30, alignment: .top).clipped())
                island(FileSearchView(search: FileSearch(preferences: off, index: FileIndex(file: nil)), model: model))
                island(FileSearchView(search: idle, model: model))
            }
            island(FileSearchView(search: search, model: model))
        }
        .padding(24)
        .background(Color(white: 0.16))
    }

    /// Focus, text recognition and clipboard transforms in the island, and the focus countdown on the closed notch.
    static func approvalsGallery() -> some View {
        let cwd = "/Users/me/code/Bangs"
        // A reply that is never sent: its other end is just left open, so the card shows its buttons.
        func reply() -> PendingReply {
            var pair: [Int32] = [0, 0]
            socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
            return PendingReply(fd: pair[0], onHangUp: {})
        }
        func request(_ harness: Harness, _ project: String, _ tool: String, _ input: [String: Any], answerable: Bool = true,
                     files: [String: String] = [:]) -> Approval {
            let folder = "/Users/me/code/\(project)"
            let edits = RequestPreview.edits(in: input)
            let risk = Risk.gravest([RequestPreview.command(in: input).flatMap { Risk.of(command: $0, cwd: folder) }]
                + RequestPreview.paths(of: edits).map { Risk.of(path: $0, cwd: folder) })
            let changes = RequestPreview.changes(edits, cwd: folder) { files[$0].map(RequestPreview.FileState.text) ?? .missing }
            return Approval(sessionId: "\(harness.rawValue):x", harness: harness, project: project, tool: tool,
                            summary: SessionStore.describe(tool: tool, input: input, verbose: true), reply: answerable ? reply() : nil, pid: 0,
                            risk: risk, changes: changes)
        }
        let source = """
        struct ApprovalView: View {
            var body: some View {
                if !approval.summary.isEmpty { HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isShell { Text("$").foregroundStyle(Palette.warn) }
                    Text(approval.summary)
        """
        let patch = """
        *** Begin Patch
        *** Update File: Sources/BangsCore/Harness.swift
        @@ public func permissionReply(_ decision: Decision) -> String {
        -        // Only fields every Claude-style CLI accepts.
        +        // Only fields every Claude-style CLI accepts: Codex fails closed on
        +        // updatedInput, updatedPermissions or interrupt.
        *** Add File: Tests/BangsCoreTests/RiskTests.swift
        +import XCTest
        +@testable import BangsCore
        +
        +final class RiskTests: XCTestCase {
        +    func testForcePushIsDanger() {
        +        XCTAssertEqual(Risk.of(command: "git push -f", cwd: "/a")?.level, .danger)
        +    }
        +}
        *** End Patch
        """
        let samples: [(String, Approval)] = [
            ("Edit：差异，标出行号", request(.claude, "Bangs", "Edit", ["file_path": "\(cwd)/Sources/Bangs/ApprovalViews.swift",
                "old_string": #"            if isShell { Text("$").foregroundStyle(Palette.warn) }"#,
                "new_string": "            if isShell { Text(\"$\").foregroundStyle(risk?.color ?? Palette.warn) }\n            if let risk { RiskLine(risk) }"],
                files: ["\(cwd)/Sources/Bangs/ApprovalViews.swift": source])),
            ("Codex 的 apply_patch：两个文件", request(.codex, "Bangs", "apply_patch", ["command": ["apply_patch", patch]])),
            ("普通命令", request(.claude, "Bangs", "Bash", ["command": "swift test --filter BangsCoreTests", "description": "Run the core tests"])),
            ("强制推送：危险，快捷键不放行", request(.codex, "web-app", "exec_command", ["command": ["bash", "-lc", "git push --force origin main"]])),
            ("下载即运行：危险", request(.claude, "muster", "Bash", ["command": "curl -fsSL https://get.example.dev/install.sh | sh"])),
            ("改项目之外的文件：注意", request(.qwen, "web-app", "edit", ["file_path": "~/.zshrc", "old_string": "export PATH=\"$HOME/.local/bin:$PATH\"",
                "new_string": "export PATH=\"$HOME/.local/bin:$PATH\"\nexport NODE_OPTIONS=\"--max-old-space-size=8192\""])),
            ("只能在终端确认的 CLI：也标出来", request(.gemini, "web-app", "run_shell_command", ["command": "rm -rf node_modules dist .next"], answerable: false)),
        ]
        let store = SessionStore()
        func card(_ caption: String, _ approval: Approval) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                ApprovalView(approval: approval, more: 0, store: store, allowKey: "⌥⌘↩", denyKey: "⌥⌘⌫")
                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16).frame(width: 460, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 24).fill(.black))
            }
        }
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) { ForEach(Array(samples.prefix(3).enumerated()), id: \.offset) { card($0.element.0, $0.element.1) } }
            VStack(alignment: .leading, spacing: 18) { ForEach(Array(samples.dropFirst(3).enumerated()), id: \.offset) { card($0.element.0, $0.element.1) } }
        }
        .padding(24)
        .background(Color(white: 0.16))
    }

    static func extrasGallery() -> some View {
        let pid = ProcessInfo.processInfo.processIdentifier
        let store = SessionStore()
        let now = Date()
        store.meter.report(.claude, Limits(windows: [Limits.Window(minutes: 300, used: 0.42, resetsAt: now.addingTimeInterval(7200)),
                                                    Limits.Window(minutes: 10080, used: 0.81, resetsAt: now.addingTimeInterval(3 * 86400))], updated: now))
        store.meter.report(.codex, Limits(windows: [Limits.Window(minutes: 10080, used: 0.93, resetsAt: now.addingTimeInterval(86400 + 3600))], updated: now))
        let changes = TurnChanges(files: [TurnChanges.File(path: "Sources/Bangs/SessionStore.swift", added: 96, removed: 21),
                                          TurnChanges.File(path: "Sources/BangsCore/Usage.swift", added: 151, removed: 0, untracked: true),
                                          TurnChanges.File(path: "Tests/BangsCoreTests/UsageTests.swift", added: 88, removed: 0, untracked: true),
                                          TurnChanges.File(path: "README.md", added: 6, removed: 2),
                                          TurnChanges.File(path: "assets/meter.png", added: nil, removed: nil)],
                                  commits: 1, base: "5898167", folder: "/Users/me/code/Bangs")
        var sessions = [
            Session(id: "claude:a", harness: .claude, pid: pid, cwd: "/Users/me/code/Bangs", status: .working, prompt: "加上用量上限的显示",
                    activity: "Bash swift test --filter UsageTests", turnStartedAt: now.addingTimeInterval(-94)),
            Session(id: "codex:b", harness: .codex, pid: pid, cwd: "/Users/me/code/Bangs", status: .finished, prompt: "把统计改动接到会话上",
                    lastMessage: "已完成：回合结束时统计 git 改动，点开能看每个文件的 diff。", unseen: true),
            Session(id: "claude:c", harness: .claude, pid: pid, cwd: "/Users/me/code/muster", status: .idle, prompt: "看看这个崩溃", lastMessage: "原因找到了：空数组时越界。"),
            Session(id: "gemini:d", harness: .gemini, pid: pid, cwd: "/Users/me/code/web-app", status: .approval, prompt: "升级依赖", activity: "run_shell_command npm install"),
            Session(id: "opencode:e", harness: .opencode, pid: pid, cwd: "/Users/me/code/site", status: .finished, prompt: "首页换成新文案",
                    lastMessage: "改好了，顺手修了移动端的折行。", unseen: true),
            Session(id: "claude:f", harness: .claude, pid: pid, cwd: "/Users/me/code/notes", status: .finished, prompt: "整理周报", lastMessage: "周报写在 weekly.md 里了。"),
        ]
        sessions[0].context = ContextFill(tokens: 620_000, window: 1_000_000)
        sessions[1].context = ContextFill(tokens: 231_000, window: 258_400)
        sessions[1].changes = changes
        sessions[1].rules = [SessionRule(tool: "exec_command", scope: .commands(["swift build", "swift test"]))]
        sessions[2].context = ContextFill(tokens: 98_383, window: nil)
        for session in sessions.reversed() { store.seed(session) }
        let preferences = Preferences()
        preferences.showsUsage = true
        let model = NotchModel(store: store, preferences: preferences, toolbox: toolbox, geometry: NotchGeometry(notchWidth: 185, height: 32, screen: NSScreen.screens[0]))
        var pair: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        let input: [String: Any] = ["command": "swift build 2>&1 | tail -5"]
        let approval = Approval(sessionId: "claude:a", harness: .claude, project: "Bangs", tool: "Bash", summary: "swift build 2>&1 | tail -5",
                                reply: PendingReply(fd: pair[0], onHangUp: {}), pid: 0, sessionRule: SessionRule.rule(tool: "Bash", input: input, risk: nil), rawInput: input)
        let diff = Git.unified("""
        diff --git a/Sources/Bangs/SessionStore.swift b/Sources/Bangs/SessionStore.swift
        --- a/Sources/Bangs/SessionStore.swift
        +++ b/Sources/Bangs/SessionStore.swift
        @@ -318,6 +318,9 @@ final class SessionStore: ObservableObject {
                     session.activity = ""
                     session.turnStartedAt = Date()
                     session.endedFromTranscript = false
        +            session.changes = nil
        +            beginTurn(key, cwd: session.cwd)
                 case .preTool:
        -            resolveTerminalWaits(key)
        +            resolveTerminalWaits(key)
        +            readUsage(of: session)
                     begin(&session)
        """).first
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-snapshot-shot.png")
        // A stand-in screenshot: a window's worth of colour.
        let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSGradient(starting: NSColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1), ending: NSColor(red: 0.5, green: 0.2, blue: 0.5, alpha: 1))?.draw(in: rect, angle: 30)
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 50), xRadius: 10, yRadius: 10).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: shot)
        }
        func panel(_ caption: String, width: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                content()
                    .environment(\.handoff, model.handoff)
                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16).frame(width: width, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 24).fill(.black))
            }
        }
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                panel("会话列表：上下文、改动、额度", width: 540) { SessionList(model: model, store: store, search: SessionSearch(history: toolbox.history)) }
                panel("截图后：发给 Agent", width: 560) { CapturedView(url: shot, model: model) }
            }
            VStack(alignment: .leading, spacing: 18) {
                panel("上一轮的改动，点开看 diff", width: 520) {
                    TurnChangesView(sessionId: "codex:b", model: model, store: store, open: changes.files[0].path,
                                    diffs: diff.map { [changes.files[0].path: $0] } ?? [:])
                }
                panel("完成提醒带上改动", width: 420) { FinishedView(session: sessions[1], model: model, store: store) }
                panel("审批：本会话都允许（设置里打开）", width: 460) {
                    ApprovalView(approval: approval, more: 0, store: store, allowKey: "⌥⌘↩", denyKey: "⌥⌘⌫", allowsForSession: true)
                }
            }
        }
        .padding(24)
        .background(Color(white: 0.16))
    }

    static func translateGallery() -> some View {
        let preferences = Preferences()
        preferences.translateAPIURL = "https://api.deepseek.com"
        preferences.translateAPIModel = "deepseek-chat"
        preferences.translateAgent = "gemini"
        let store = SessionStore()
        store.seed(Session(id: "claude:a", harness: .claude, pid: ProcessInfo.processInfo.processIdentifier, cwd: "/Users/me/code/Bangs", status: .idle, prompt: "看看这个"))
        let model = NotchModel(store: store, preferences: preferences, toolbox: toolbox, geometry: NotchGeometry(notchWidth: 185, height: 32, screen: NSScreen.screens[0]))
        let english = """
        The agent couldn't find a matching file in the current directory, so it searched the parent folders instead. \
        It stops at the first folder that holds a Package.swift.

        Run it again with --verbose to see each folder it looked in.
        """
        let chinese = "Agent 在当前目录里找不到匹配的文件，所以改为在上级文件夹里查找。它会在第一个包含 Package.swift 的文件夹处停下。\n\n加上 --verbose 再运行一次，可以看到它查找过的每个文件夹。"
        func card(_ caption: String, _ setUp: (Translator) -> Void) -> some View {
            let translator = Translator(preferences: preferences)
            setUp(translator)
            return VStack(alignment: .leading, spacing: 6) {
                Text(caption).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                TranslationView(translator: translator, model: model)
                    .environment(\.handoff, model.handoff)
                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16).frame(width: 480, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 24).fill(.black))
            }
        }
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                card("译好了（选在可编辑的地方，能替换原文）") { $0.show(english, translated: chinese, from: "en", to: "zh-Hans", app: "Safari", phase: .done, editable: true) }
                card("正在翻译") { $0.show(english, translated: nil, from: "en", to: "zh-Hans", app: "Terminal", phase: .translating) }
            }
            VStack(alignment: .leading, spacing: 18) {
                card("大模型翻译（流式显示，右上角可换方式）") {
                    $0.show("ユーザー設定を保存できませんでした。ディスクの空き容量を確認してください。", translated: "无法保存用户设置。请检查磁盘的可用空间。",
                            from: "ja", to: "zh-Hans", app: "Slack", phase: .done, engine: .model)
                }
                card("Agent 出错时") {
                    $0.show(english, translated: nil, from: "en", to: "zh-Hans", app: "Terminal",
                            phase: .failed("This client is no longer supported for Gemini Code Assist for individuals."), engine: .agent)
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                card("还没下载语言包") { $0.show("ユーザー設定を保存できませんでした。", translated: nil, from: "ja", to: "zh-Hans", app: "Slack", phase: .needsDownload) }
                card("没选中文字") { $0.nothingSelected() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("截图识字后：翻译").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    RecognizedView(text: "Build succeeded. 3 warnings, 0 errors.", model: model)
                        .environment(\.handoff, model.handoff)
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16).frame(width: 480, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 24).fill(.black))
                }
            }
        }
        .padding(24)
        .background(Color(white: 0.16))
    }

    static func newGallery() -> some View {
        let preferences = Preferences()
        let model = NotchModel(store: menuStore, preferences: preferences, toolbox: toolbox, geometry: NotchGeometry(menuBarItem: nil, screen: NSScreen.screens[0]))
        let running = FocusTimer(preferences: preferences)
        running.start(.focus)
        let idle = FocusTimer(preferences: preferences)
        let clipboard = ClipboardHistory(preferences: preferences)
        for text in ["user_name", "1762311600", #"{"id":42,"name":"bangs","tags":["notch","agent"]}"#] {
            clipboard.add(ClipItem(kind: ClipboardHistory.kind(of: text), text: text, app: "Xcode", key: text))
        }
        let now = Date()
        let notches: [(String, NotchStatus)] = [
            ("专注", NotchStatus(meeting: now.addingTimeInterval(24 * 60 + 13), lead: 1500, tint: .focus)),
            ("专注 + Agent", NotchStatus(activity: .working, meeting: now.addingTimeInterval(900), lead: 1500, tint: .focus)),
            ("休息", NotchStatus(meeting: now.addingTimeInterval(200), lead: 300, tint: .rest)),
            ("暂停", NotchStatus(meeting: now.addingTimeInterval(600), lead: 1500, tint: .focus, frozen: now)),
        ]
        func panel(_ content: some View) -> some View {
            content.padding(.horizontal, 20).padding(.vertical, 14).frame(width: 540, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 24).fill(.black))
        }
        func label(_ text: String) -> some View { Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                label("收起时的专注倒计时")
                HStack(spacing: 10) {
                    ForEach(Array(notches.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 4) {
                            ClosedNotch(harness: item.1.activity == nil ? nil : .claude, others: 0, status: item.1, pointer: Pointer(), awake: false, side: item.1.width())
                                .frame(width: 70 + item.1.width() * 2, height: 32)
                                .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
                            Text(item.0).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                label("专注标签：没开始 / 进行中")
                panel(FocusView(timer: idle, preferences: preferences))
                panel(FocusView(timer: running, preferences: preferences))
                label("专注结束的提醒")
                panel(FocusEndedView(ended: .focus, started: .shortBreak, agents: 2, model: model))
                label("截图标签")
                panel(ScreenshotView(shoot: { _ in }, preferences: preferences))
            }
            VStack(alignment: .leading, spacing: 12) {
                label("会话：搜索「登录」，进行中和历史")
                panel(SessionList(model: model, store: menuStore, search: searchSample()))
                label("截图识字之后")
                panel(RecognizedView(text: "Bangs 躲在刘海里，替你盯着本机所有在跑的编码 Agent。Lives in your MacBook's notch.", model: model))
                label("剪贴板：选中 JSON 时的转换")
                panel(ClipboardView(history: clipboard) { _, _ in })
            }
        }
        .padding(24)
        .background(Color(white: 0.16))
    }

    static func keysGallery() -> some View {
        func row(dark: Bool) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原来").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            ForEach([("↩", "粘贴"), ("⌘↩", "只复制")], id: \.0) { key, title in
                                HStack(spacing: 4) {
                                    Text(key).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                                    Text(title).font(.system(size: 10.5)).foregroundStyle(Palette.dim)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("新的").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            KeyHint(keys: [.returnKey], title: "粘贴")
                            KeyHint(keys: [.text("⌘"), .returnKey], title: "只复制")
                            KeyHint(keys: [.text("⌘"), .text("P")], title: "置顶")
                            KeyHint(keys: [.text("esc")], title: "关闭")
                        }
                    }
                }
                HStack(alignment: .center, spacing: 18) {
                    ForEach([10, 13, 18, 28] as [CGFloat], id: \.self) { size in Keycap(key: .returnKey, size: size) }
                    ReturnArrow().stroke(Palette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).frame(width: 44, height: 40)
                }
            }
            .padding(20)
            .frame(width: 720, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(dark ? Color.black : Color(white: 0.96)))
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        return VStack(spacing: 16) { row(dark: true); row(dark: false) }.padding(20).background(Color(white: 0.5))
    }

    /// Past sessions to search, and a query under way.
    private static func searchSample() -> SessionSearch {
        let now = Date()
        func past(_ harness: Harness, _ id: String, _ cwd: String, _ branch: String, _ title: String, _ prompts: [String], _ texts: [String], _ ago: TimeInterval) -> PastSession {
            var session = PastSession(harness: harness, sessionId: id)
            session.cwd = cwd; session.branch = branch; session.title = title; session.prompts = prompts; session.texts = texts
            session.updated = now.addingTimeInterval(-ago)
            return session
        }
        toolbox.history.show([
            past(.claude, "5d1f6093-e8a2-4d7b", "/Users/me/api-server", "auth", "OAuth 登录回调", ["登录回调拿不到 state 参数"], [], 86400 * 8),
            past(.claude, "3c77e2b1-90fd-4c58", "/Users/me/bearich-site", "main", "首页改版", ["首页的登录按钮挪到右上角"], [], 86400 * 3),
            past(.codex, "01a19f42-7c3e-7d21", "/Users/me/Bangs", "main", "滚动截图拼接", ["滚动截图有时候拼接错位"], ["已修复：登录态过期时截图会失败的问题也一起处理了"], 86400 * 2),
        ])
        let search = toolbox.sessionSearch
        search.query = "登录"
        return search
    }

    private static let menuStore: SessionStore = {
        let store = SessionStore()
        let pid = ProcessInfo.processInfo.processIdentifier
        for (harness, session, cwd, prompt, tool) in [(Harness.claude, "a", "/Users/me/Bangs", "加个菜单栏模式", "swift build"), (.codex, "b", "/Users/me/Muster", "修一下测试", "npm test")] {
            store.receive(HookEnvelope(harness: harness, native: "UserPromptSubmit", pid: pid, payload: ["session_id": session, "cwd": cwd, "prompt": prompt]), reply: nil)
            store.receive(HookEnvelope(harness: harness, native: "PreToolUse", pid: pid, payload: ["session_id": session, "cwd": cwd, "tool_name": "Bash", "tool_input": ["command": tool]]), reply: nil)
        }
        return store
    }()

    private static let toolbox: Toolbox = {
        let toolbox = Toolbox(preferences: Preferences())
        let samples: [(ClipItem.Kind, String, String)] = [
            (.text, "ssh wale@devbox.internal -p 2222", "Terminal"), (.link, "https://github.com/Wale-Shi/Bangs/releases/tag/v0.2.0", "Safari"),
            (.code, "func toggle() {\n    model.go(.expanded)\n}", "Xcode"), (.color, "#E08A6A", "Figma"),
            (.file, "/Users/me/Downloads/Bangs-0.2.0-arm64.zip", "访达"),
        ]
        for (kind, text, app) in samples.reversed() { toolbox.clipboard.add(ClipItem(kind: kind, text: text, app: app, key: text)) }
        if let first = toolbox.clipboard.items.first { toolbox.clipboard.togglePin(first) }
        toolbox.keepAwake.set(.until(Date().addingTimeInterval(42 * 60)))
        return toolbox
    }()

    /// The open island on each tool, for design review.
    static func tools() -> some View {
        let preferences = Preferences()
        preferences.usageInNotch = .cpu
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(Tool.allCases, id: \.self) { tool in
                let model = NotchModel(store: menuStore, preferences: preferences, toolbox: toolbox, geometry: NotchGeometry(menuBarItem: nil, screen: NSScreen.screens[0]))
                let _ = model.tool = tool
                let _ = model.showsAwakeOptions = tool == .sessions
                ToolboxView(model: model, store: menuStore)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .frame(width: 540, alignment: .topLeading)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24).fill(.black))
            }
            // ImageRenderer cannot draw scroll views, so the clipboard rows are laid out here directly.
            VStack(spacing: 0) {
                ForEach(Array(toolbox.clipboard.visible.enumerated()), id: \.element.id) { index, item in
                    ClipRow(item: item, index: index, selected: index == 1, history: toolbox.clipboard)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: 24).fill(.black))
            CapturedView(url: URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"),
                         model: NotchModel(store: menuStore, preferences: preferences, toolbox: toolbox, geometry: NotchGeometry(menuBarItem: nil, screen: NSScreen.screens[0])))
                .padding(16).frame(width: 440).background(RoundedRectangle(cornerRadius: 24).fill(.black))
            HStack(alignment: .top, spacing: 12) {
                Header(model: NotchModel(store: menuStore, preferences: preferences, toolbox: toolbox, geometry: NotchGeometry(menuBarItem: nil, screen: NSScreen.screens[0])), store: menuStore)
                    .frame(width: 300, height: 32)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
            }
        }
    }

    /// The status icon's states, for the README.
    static func statesGallery() -> some View {
        let states: [(String, String, StatusGlyph.State, [StatusGlyph.Dot])] = [
            ("空闲", "闭眼睡觉", .idle(awake: false), []),
            ("运行中", "亮弧转圈 · 左右张望", .working, [.running, .running]),
            ("一个跑完", "跑完的点变绿", .working, [.running, .finished]),
            ("待审批", "圆环变橙 · 点在闪", .approval, [.asking, .running]),
            ("完成", "一笔扫满 · 笑眼", .finished, [.finished, .finished]),
            ("快开会了", "圆环倒计时", .meeting(left: 0.45, awake: false), []),
            ("防休眠", "一直睁着眼", .idle(awake: true), []),
        ]
        return HStack(alignment: .top, spacing: 34) {
            ForEach(states, id: \.0) { item in
                VStack(spacing: 10) {
                    StatusGlyph(state: item.2, dots: item.3, size: 76)
                    Text(item.0).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(item.1).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: 104)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 34)
        .foregroundStyle(.white)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }

    /// The notch at work, for the README: collapsed in a few states, magnified.
    static func notchGallery() -> some View {
        let notch: CGFloat = 150
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(notchSamples.enumerated()), id: \.offset) { _, item in
                let empty = item.harness == nil && item.status.isEmpty
                let side: CGFloat = empty ? 0 : item.status.width()
                HStack(spacing: 28) {
                    ClosedNotch(harness: item.harness, others: item.others, status: item.status, pointer: Pointer(), awake: false, side: side)
                        .opacity(empty ? 0 : 1)
                        .frame(width: notch + side * 2, height: 32)
                        .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
                        .scaleEffect(2)
                        .frame(width: (notch + side * 2) * 2, height: 64)
                        // Centred, as on the screen.
                        .frame(width: (notch + 100) * 2)
                    Text(item.caption).font(.system(size: 15, weight: .medium)).foregroundStyle(Color(white: 0.15))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 60).padding(.vertical, 30)
        .background(LinearGradient(colors: [Color(red: 0.80, green: 0.84, blue: 0.91), Color(red: 0.91, green: 0.87, blue: 0.83)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// The menu bar icon in each state, large and at size, and the open panel in light and dark.
    static func menuBarGallery() -> some View {
        let states: [(String, StatusGlyph.State, [StatusGlyph.Dot])] = [
            ("空闲", .idle(awake: false), []), ("防休眠", .idle(awake: true), []), ("运行中", .working, [.running, .running]),
            ("一个跑完", .working, [.running, .finished]), ("待审批", .approval, [.asking, .running]), ("完成", .finished, [.finished, .finished]),
            ("会议", .meeting(left: 0.4, awake: false), []),
        ]
        return VStack(alignment: .leading, spacing: 18) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 22) {
                        ForEach(states, id: \.0) { item in
                            VStack(spacing: 8) {
                                StatusGlyph(state: item.1, dots: item.2, size: 64)
                                StatusGlyph(state: item.1, dots: item.2, size: 17)
                                Text(item.0).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 1) {
                            ForEach(Array(toolbox.clipboard.visible.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, index: index, selected: index == 1, history: toolbox.clipboard)
                            }
                        }
                        .padding(10)
                        .frame(width: 400)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                        ForEach([Tool.sessions], id: \.self) { tool in
                            let model = panelModel(tool)
                            VStack(spacing: 0) {
                                HStack(spacing: 14) {
                                    Spacer()
                                    MenuBarLabel(model: model, store: menuStore)
                                    Text("周二 10:42").font(.system(size: 13))
                                }
                                .padding(.horizontal, 12).frame(height: 24)
                                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
                                NotchRoot(model: model, store: menuStore).frame(width: 420, height: 330).padding(.top, 5)
                            }
                            .frame(width: 440)
                        }
                    }
                }
                .padding(20)
                .foregroundStyle(.primary)
                .background(scheme == .dark ? Color(red: 0.11, green: 0.14, blue: 0.2) : Color(red: 0.79, green: 0.83, blue: 0.89))
                .environment(\.colorScheme, scheme)
            }
        }
    }

    private static func panelModel(_ tool: Tool) -> NotchModel {
        let screen = NSScreen.screens[0]
        let item = NSRect(x: screen.frame.midX - 20, y: screen.frame.maxY - 24, width: 40, height: 24)
        let model = NotchModel(store: menuStore, preferences: Preferences(), toolbox: toolbox, geometry: NotchGeometry(menuBarItem: item, screen: screen))
        model.tool = tool
        model.go(.expanded)
        model.contentHeight = 300
        return model
    }

    private static let menuModel: NotchModel = {
        let screen = NSScreen.screens[0]
        let item = NSRect(x: screen.frame.midX - 20, y: screen.frame.maxY - 24, width: 40, height: 24)
        let model = NotchModel(store: menuStore, preferences: Preferences(), toolbox: toolbox, geometry: NotchGeometry(menuBarItem: item, screen: screen))
        model.go(.expanded)
        model.contentHeight = 150
        return model
    }()

    private static func menuBar(_ scheme: ColorScheme) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            MenuBarLabel(model: menuModel, store: menuStore)
            Image(systemName: "battery.75percent")
            Text("周二 10:42").font(.system(size: 13))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
        .environment(\.colorScheme, scheme)
    }

    private static var notchSamples: [(caption: String, harness: Harness?, others: Int, status: NotchStatus)] {
        let now = Date()
        return [
            ("没事：和实体刘海一样大", nil, 0, NotchStatus()),
            ("Claude Code 在跑", .claude, 0, NotchStatus(activity: .working)),
            ("三个会话在跑", .claude, 2, NotchStatus(activity: .working)),
            ("Codex 等你批准", .codex, 1, NotchStatus(activity: .asking)),
            ("Claude Code 跑完了", .claude, 0, NotchStatus(activity: .done)),
            ("3 分钟后开会，没有 Agent 在跑", nil, 0, NotchStatus(meeting: now.addingTimeInterval(180))),
            ("只显示 CPU（常显时）", nil, 0, NotchStatus(usage: 0.62)),
            ("在跑，会议只剩最后 30%", .claude, 0, NotchStatus(activity: .working, meeting: now.addingTimeInterval(75))),
            ("在跑，CPU 80%", .claude, 0, NotchStatus(activity: .working, usage: 0.8)),
            ("在跑、快开会、CPU 55%", .claude, 1, NotchStatus(activity: .working, meeting: now.addingTimeInterval(210), usage: 0.55)),
        ]
    }
}
