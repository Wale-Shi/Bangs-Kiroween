import AppKit
import BangsCore
import ServiceManagement
import SwiftUI

/// Where the hook binary lives: inside the app bundle, or next to the executable in a development build.
enum HookBinary {
    static var path: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bangs-hook")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("bangs-hook").path
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    struct Row: Identifiable {
        let harness: Harness
        var state: HookInstaller.State
        var id: Harness { harness }
    }

    @Published var rows: [Row] = []
    /// CLIs whose install or removal is still running (Hermes' takes a few seconds).
    @Published var working: Set<Harness> = []
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Shortcuts another app already holds.
    @Published var takenShortcuts: Set<ShortcutAction> = []
    /// Permissions, refreshed whenever the window opens.
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    /// The pane the window shows.
    @Published var pane: SettingsPane = .general
    /// Whether Claude Code's status line is relayed to Bangs, for its plan limits.
    @Published var statusLine: StatusLineRelay.State = .notDetected

    init() { refresh() }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        rows = Harness.allCases.map { Row(harness: $0, state: installer($0).state()) }
        statusLine = relay.state()
    }

    var relay: StatusLineRelay { StatusLineRelay(hookBinary: HookBinary.path) }

    func setRelay(_ on: Bool) {
        perform { if on { try relay.install() } else { try relay.uninstall() } }
        statusLine = relay.state()
    }

    var anyInstalled: Bool { rows.contains { $0.state == .installed || $0.state == .outdated } }

    func installer(_ harness: Harness) -> HookInstaller { HookInstaller(harness: harness, hookBinary: HookBinary.path) }

    func install(_ harness: Harness) {
        change(harness) { try $0.install() }
    }

    func uninstall(_ harness: Harness) {
        change(harness) { try $0.uninstall() }
    }

    /// Off the main thread: Hermes' plugin is switched on by running the hermes command.
    private func change(_ harness: Harness, _ action: @escaping @Sendable (HookInstaller) throws -> Void) {
        guard !working.contains(harness) else { return }
        working.insert(harness)
        let installer = installer(harness)
        Task.detached {
            let failure: String?
            do { try action(installer); failure = nil } catch { failure = error.localizedDescription }
            await MainActor.run {
                self.working.remove(harness)
                self.error = failure
                self.refresh()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        perform {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
        refresh()
    }
}

/// The settings window's panes, listed in its sidebar in three groups: Bangs itself, its tools, the system.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, agents, files, clipboard, screenshot, translate, focus, calendar, shelf, battery, shortcuts, permissions, about

    var id: Self { self }

    static let groups: [(title: String?, panes: [SettingsPane])] = [
        (nil, [.general, .agents]),
        ("工具", [.files, .clipboard, .screenshot, .translate, .focus, .calendar, .shelf]),
        ("系统", [.battery, .shortcuts, .permissions, .about]),
    ]

    var title: String {
        switch self {
        case .general: "通用"
        case .agents: "Agent"
        case .files: "文件搜索"
        case .clipboard: "剪贴板"
        case .screenshot: "截图与识字"
        case .translate: "翻译"
        case .focus: "专注计时"
        case .calendar: "日程提醒"
        case .shelf: "文件中转站"
        case .battery: "电池"
        case .shortcuts: "快捷键"
        case .permissions: "权限"
        case .about: "关于与更新"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "terminal.fill"
        case .files: "doc.text.magnifyingglass"
        case .clipboard: "doc.on.clipboard.fill"
        case .screenshot: "text.viewfinder"
        case .translate: "character.bubble.fill"
        case .focus: "timer"
        case .calendar: "calendar"
        case .shelf: "tray.fill"
        case .battery: "battery.75percent"
        case .shortcuts: "command"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general, .shortcuts, .about: Color(white: 0.56)
        case .agents: Color(white: 0.16)
        case .files: Color(red: 0.35, green: 0.34, blue: 0.84)
        case .clipboard, .permissions: Color(red: 0.04, green: 0.48, blue: 1)
        case .screenshot: Color(red: 0.56, green: 0.27, blue: 0.84)
        case .translate: Color(red: 0.0, green: 0.6, blue: 0.75)
        case .focus: Color(red: 0.95, green: 0.38, blue: 0.18)
        case .calendar: Color(red: 1, green: 0.23, blue: 0.19)
        case .shelf: Color(red: 0.07, green: 0.64, blue: 0.61)
        case .battery: Color(red: 0.2, green: 0.74, blue: 0.35)
        }
    }

    /// The island tab a tool page switches on and off.
    var tool: Tool? {
        switch self {
        case .files: .files
        case .clipboard: .clipboard
        case .screenshot: .screenshot
        case .focus: .focus
        case .calendar: .calendar
        case .shelf: .shelf
        default: nil
        }
    }

    /// One line under a tool page's title.
    var summary: String? {
        switch self {
        case .files: "像 Everything 一样按文件名找文件：输入几个字，几毫秒出结果。只记文件名，索引只存在这台 Mac 上。"
        case .clipboard: "复制过的文字、链接、图片和文件，随时找回；还能把 JSON、时间戳、Base64 等一键转换。"
        case .screenshot: "选区、窗口、滚动截图；框选一块屏幕，直接把上面的文字复制出来。"
        case .translate: "在任何 App 里选中文字，按快捷键在刘海里看译文：用 macOS 本机翻译，或交给你自己的大模型、本机的 Agent。"
        case .focus: "番茄钟。倒计时显示在刘海里，专注时 Agent 跑完不打扰你。"
        case .calendar: "读取系统日历，开会前倒计时，一键入会。"
        case .shelf: "把文件拖到刘海附近暂存，再从刘海拖到任何地方。"
        case .battery: "给 MacBook 设一个充电上限。长期插着电源用时，电池不总停在 100%，老化得慢一些。"
        default: nil
        }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    let model = SettingsModel()
    let preferences: Preferences
    let toolbox: Toolbox

    init(preferences: Preferences, toolbox: Toolbox) {
        self.preferences = preferences
        self.toolbox = toolbox
    }

    func show(_ pane: SettingsPane? = nil) {
        model.refresh()
        if let pane { model.pane = pane }
        if window == nil {
            // An AppKit split view with a sidebar item, so the sidebar is the system's own and takes its current look.
            let split = NSSplitViewController()
            let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SettingsSidebar(model: model, updater: toolbox.updater)))
            sidebar.canCollapse = false
            sidebar.minimumThickness = 196
            sidebar.maximumThickness = 196
            split.addSplitViewItem(sidebar)
            split.addSplitViewItem(NSSplitViewItem(viewController: NSHostingController(rootView: SettingsDetail(model: model, preferences: preferences, toolbox: toolbox))))
            let window = NSWindow(contentViewController: split)
            window.title = "Bangs 设置"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 740, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            // Back from System Settings with a permission granted: the window says so at once.
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.refresh()
                    self?.toolbox.agenda.refresh()
                    self?.toolbox.files.refreshAccess()
                }
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
