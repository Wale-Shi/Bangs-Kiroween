import AppKit
import BangsCore
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore(meter: UsageMeter(persisted: true))
    private var server: HookServer?
    private var controller: NotchWindowController?
    private let preferences = Preferences()
    private lazy var settings = SettingsWindow(preferences: preferences, toolbox: toolbox)
    private var hotkeys: Hotkeys?
    private lazy var toolbox = Toolbox(preferences: preferences)
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let server = HookServer(onEvent: { [store] envelope, reply in store.receive(envelope, reply: reply) },
                                      onHangUp: { [store] id in store.hangUp(id) }) else {
            // Another Bangs is already running.
            NSApp.terminate(nil)
            return
        }
        self.server = server
        preferences.$showsUsage.sink { [store] in store.readsUsage = $0 }.store(in: &subscriptions)
        preferences.$turnChanges.sink { [store] in store.tracksChanges = $0 }.store(in: &subscriptions)
        preferences.$sessionAllow.sink { [store] in store.allowsForSession = $0 }.store(in: &subscriptions)
        NSApp.mainMenu = Self.menu()
        let geometry = NotchGeometry.notchScreen.map(NotchGeometry.init(notchScreen:)) ?? NotchGeometry(menuBarItem: nil, screen: NotchGeometry.screen(containing: nil))
        let model = NotchModel(store: store, preferences: preferences, toolbox: toolbox, geometry: geometry)
        model.showSettings = { [settings] pane in settings.show(pane) }
        let controller = NotchWindowController(model: model, store: store)
        self.controller = controller
        let hotkeys = Hotkeys { [weak controller, weak model] action in
            switch action {
            case .toggle: controller?.toggle()
            case .allowRequest, .denyRequest:
                if model?.answerFromKeyboard(allowing: action == .allowRequest) != true { NSSound.beep() }
            case .sessionSearch: controller?.searchSessions()
            case .fileSearch: controller?.searchFiles()
            case .clipboard: controller?.open(.clipboard)
            case .shotRegion, .shotWindow, .shotScroll, .shotText: model?.shoot(action)
            case .focus: model?.toolbox.focus.toggle()
            case .translate: model?.translateSelection()
            }
        }
        self.hotkeys = hotkeys
        // Recording a new shortcut in the settings frees the current ones, so pressing one again can be recorded. The
        // answer shortcuts are held only while a request can be answered from the card, so ⌥⌘↩ and ⌥⌘⌫ stay other
        // apps' the rest of the time.
        let answerable = store.$approvals.map { $0.contains { $0.answerable && $0.questions.isEmpty } }.removeDuplicates()
        preferences.$shortcuts.combineLatest(preferences.$recordingShortcut, answerable).sink { [settings] shortcuts, recording, answerable in
            var active = recording ? [:] : shortcuts
            if !answerable { for action in ShortcutAction.answers { active[action] = nil } }
            let taken = hotkeys.register(active)
            // Unheld, they are not known to be taken: keep what was last found while they were held.
            settings.model.takenShortcuts = answerable ? taken : taken.union(settings.model.takenShortcuts.intersection(ShortcutAction.answers))
        }.store(in: &subscriptions)
        toolbox.screenshots.onFailed = { message in
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        }
        if !settings.model.anyInstalled { settings.show(.agents) }
        repairHooks()
        // For testing: BANGS_STATE_FILE gets the sessions Bangs sees, rewritten on every change.
        if let path = ProcessInfo.processInfo.environment["BANGS_STATE_FILE"] {
            store.$sessions.combineLatest(store.$approvals).sink { sessions, approvals in
                let rows: [[String: Any]] = sessions.map { ["id": $0.id, "pid": Int($0.pid), "status": "\($0.status)", "project": $0.project, "prompt": $0.prompt,
                                                           "activity": $0.activity, "last": $0.lastMessage] }
                let state: [String: Any] = ["sessions": rows, "approvals": approvals.map { "\($0.harness.rawValue) \($0.tool) \($0.summary)" }]
                try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: path))
            }.store(in: &subscriptions)
        }
    }

    /// Moved or updated since the hooks were written: each CLI would run a command that is gone (or out of date) on
    /// every event, so they are rewritten without asking. Only a bundled app does this: a development build, or one on
    /// a socket of its own, must not point your CLIs at itself. Off the main thread: Hermes' takes a command run.
    private func repairHooks() {
        guard Bundle.main.bundleURL.pathExtension == "app", ProcessInfo.processInfo.environment["BANGS_SOCKET"] == nil else { return }
        let binary = HookBinary.path, model = settings.model
        Task.detached {
            let repaired = HookInstaller.repair(hookBinary: binary) { harness, error in
                Log.write("hooks: could not repair \(harness.rawValue): \(error.localizedDescription)")
            }
            do {
                if try StatusLineRelay(hookBinary: binary).repair() { Log.write("hooks: repaired Claude Code's status line for \(binary)") }
            } catch {
                Log.write("hooks: could not repair Claude Code's status line: \(error.localizedDescription)")
            }
            guard !repaired.isEmpty else { return }
            Log.write("hooks: repaired \(repaired.map(\.rawValue).joined(separator: ", ")) for \(binary)")
            await MainActor.run { model.refresh() }
        }
    }

    /// Never shown (Bangs has no menu bar of its own), but its shortcuts are how text fields in the settings window get
    /// copy, paste, select all and undo, and how ⌘W closes it.
    private static func menu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu(title: "Bangs")
        app.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        toolbox.files.index.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }
}

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
        // The sample clipboard and shelf go to a throwaway folder, never your own history.
        if Storage.custom == nil {
            Storage.custom = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-snapshot-\(getpid())")
        }
        Snapshot.render(to: CommandLine.arguments[index + 1])
        exit(0)
    }
    // `Bangs --prepare-ocr <language>`: has macOS prepare its table readers, in this process rather than the app's
    // (see TableRecognition.prepareOnce).
    if let index = CommandLine.arguments.firstIndex(of: "--prepare-ocr") {
        let language = CommandLine.arguments.dropFirst(index + 1).first.flatMap(TextRecognition.Language.init(rawValue:)) ?? .auto
        Task {
            await TableRecognition.prepare(language: language)
            exit(0)
        }
        RunLoop.main.run()
    }
    if CommandLine.arguments.contains("--compare") {
        Snapshot.compare()
        exit(0)
    }
    if CommandLine.arguments.contains("--bench") {
        Snapshot.bench()
        exit(0)
    }
    // `Bangs --check-update`: the latest release on GitHub and whether it is newer, without installing anything.
    if CommandLine.arguments.contains("--check-update") {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        Task {
            do {
                let release = try await Updater.latest()
                print("current \(current), latest \(release.version)\(Version.isNewer(release.version, than: current) ? " (newer)" : "")\n\(release.download)")
                exit(0)
            } catch {
                print("check failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
    // `Bangs --update-from <zip> <version>`: installs a release zip the way the in-app update does, for testing it.
    if let index = CommandLine.arguments.firstIndex(of: "--update-from"), CommandLine.arguments.count > index + 2 {
        do {
            try Updater.install(zip: URL(fileURLWithPath: CommandLine.arguments[index + 1]), expecting: CommandLine.arguments[index + 2])
            print("Installing; Bangs will open once this process exits.")
        } catch {
            print("Update refused: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
    // `Bangs --battery`: the battery and the charging keys this Mac's SMC has, read only, for supporting a new Mac.
    if CommandLine.arguments.contains("--battery") {
        let info = ProcessInfo.processInfo
        var model = [CChar](repeating: 0, count: 64), size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        print("macOS \(info.operatingSystemVersionString), \(String(cString: model))")
        print("battery: \(Battery.current().map { "\($0.level)%, adapter \($0.onPower), charging \($0.charging)" } ?? "none")")
        guard let smc = SMC() else { print("SMC: cannot open"); exit(1) }
        print("mode: \(ChargeLimit.Switch(smc).map { "\($0)" } ?? "none")")
        for key in ["bfF0", "bfD0", "bfE0", "CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "CHWA"] { print("\(key): \(smc.describe(key))") }
        exit(0)
    }
    // `Bangs --hook-status`: whether each CLI's Bangs hooks are installed and current, without changing anything.
    if CommandLine.arguments.contains("--hook-status") {
        for harness in Harness.allCases {
            let installer = HookInstaller(harness: harness, hookBinary: HookBinary.path)
            print("\(harness.rawValue): \(installer.state()) \(installer.file.path)")
        }
        exit(0)
    }
    // `Bangs --install-hooks [cli …]`: what the settings window's Install buttons do, for every CLI found on this Mac or
    // only those named (e.g. `--install-hooks pi omp`). CLIs whose hooks are already up to date are left alone.
    if let index = CommandLine.arguments.firstIndex(of: "--install-hooks") {
        let named = Set(CommandLine.arguments[(index + 1)...].filter { !$0.hasPrefix("-") })
        for harness in Harness.allCases where named.isEmpty || named.contains(harness.rawValue) {
            let installer = HookInstaller(harness: harness, hookBinary: HookBinary.path)
            let state = installer.state()
            guard state != .notDetected else { continue }
            guard state != .installed else { print("\(harness.displayName): up to date"); continue }
            do {
                try installer.install()
                print("\(harness.displayName): \(installer.file.path)")
            } catch {
                print("\(harness.displayName): \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
