import AppKit
import BangsCore
import ServiceManagement
import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Pane(model: model) {
            ForEach([nil, Tool.sessions, .files, .clipboard, .screenshot, .focus], id: \.self) { tool in
                Section(tool.map(title) ?? "Bangs") {
                    ForEach(ShortcutAction.allCases.filter { $0.tool == tool && $0 != .translate }, id: \.self, content: recorder)
                }
            }
            Section("翻译") { recorder(.translate) }
            Section {
            } footer: {
                footer("点一下再按新的组合键；Esc 取消，Delete 关闭这个快捷键。允许、拒绝审批请求只在有请求等你时占用这两个组合键，其余时间留给别的 App。每个工具页里也能改自己的快捷键，两处是同一份设置。")
            }
        }
    }

    private func recorder(_ action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            ShortcutRecorder(preferences: preferences, action: action, taken: model.takenShortcuts.contains(action))
        }
    }

    private func title(_ tool: Tool) -> String {
        switch tool {
        case .sessions: "会话"
        case .files: "文件搜索"
        case .screenshot: "截图与识字"
        case .focus: "专注计时"
        default: tool.title
        }
    }
}

struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var agenda: Agenda
    @ObservedObject var files: FileSearch

    var body: some View {
        Pane(model: model) {
            Section {
                permission("辅助功能", detail: "剪贴板回车自动粘贴；读取选中的文字来翻译；滚动截图时按住空格锁定方向、回车完成", granted: model.accessibility,
                           url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
                permission("屏幕录制", detail: model.screenRecording ? "截图、滚动截图、截图识字" : "截图、截图识字 · 打开开关后需要重启 Bangs；更新后需要关掉再打开一次",
                           granted: model.screenRecording, url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    CGRequestScreenCaptureAccess()
                }
                permission("日历", detail: "日程提醒", granted: agenda.access == .granted,
                           url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    agenda.requestAccess()
                }
                permission("完全磁盘访问", detail: "整盘文件搜索：搜到资源库、邮件附件等受保护位置里的文件", granted: files.fullDiskAccess,
                           url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {}
            } header: {
                Text("系统权限")
            } footer: {
                footer("都是可选的：不用对应的工具就不必打开。专注计时不需要权限。")
            }
        }
    }

    private func permission(_ title: String, detail: String, granted: Bool, url: String, request: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("允许…") {
                    request()
                    NSWorkspace.shared.open(URL(string: url)!)
                }
            }
        } label: {
            Text(title)
            note(detail)
        }
    }
}

/// Click, then press the key to hold: a key on its own, or a modifier alone. Esc cancels; return is taken (it finishes
/// the capture).
struct HoldKeyRecorder: View {
    @Binding var key: HoldKey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "按下要按住的键…" : key.name)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 110)
            }
            if key != .space && !recording {
                Button("恢复为空格") { key = .space }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop(); return nil }
                guard let picked = HoldKey(keyDown: event) else { NSSound.beep(); return nil }
                key = picked
                stop()
            } else if let picked = HoldKey(flagsChanged: event) {
                key = picked
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Click, then press the new shortcut: Esc cancels, Delete turns the shortcut off.
struct ShortcutRecorder: View {
    @ObservedObject var preferences: Preferences
    let action: ShortcutAction
    let taken: Bool
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if taken && !recording {
                Text("已被其他 App 占用").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "按下新的快捷键…" : preferences.shortcuts[action]?.display ?? "未设置")
                    .font(.system(size: 12, weight: .medium))
                    .monospaced(!recording && preferences.shortcuts[action] != nil)
                    .frame(minWidth: 110)
            }
            if preferences.shortcuts[action] != nil && !recording {
                Button { preferences.shortcuts[action] = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("关闭快捷键")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        preferences.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Delete on its own turns the shortcut off; with modifiers (⌥⌘⌫) it is one.
            let clears = [51, 117].contains(event.keyCode) && event.modifierFlags.intersection([.control, .option, .command]).isEmpty
            switch event.keyCode {
            case 53: stop()
            case _ where clears:
                preferences.shortcuts[action] = nil
                stop()
            default:
                guard let shortcut = Shortcut(event: event) else { NSSound.beep(); return nil }
                // One shortcut, one action.
                for (other, existing) in preferences.shortcuts where other != action && existing.keyCode == shortcut.keyCode && existing.modifiers == shortcut.modifiers {
                    preferences.shortcuts[other] = nil
                }
                preferences.shortcuts[action] = shortcut
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        preferences.recordingShortcut = false
    }
}

/// Settings › 电池: the charge limit.
struct BatteryPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var charge: ChargeLimiter
    /// The battery changes slowly; this page reads it again every few seconds while it is open.
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Pane(model: model) {
            Hero(pane: .battery, preferences: preferences)
            switch charge.support {
            case .noBattery:
                Section { note("这台 Mac 没有电池，充电上限只对 MacBook 有用。") }
            case .unsupported:
                if #available(macOS 26.4, *) {
                    Section {
                        LabeledContent {
                            Button("打开电池设置…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                            }
                        } label: {
                            Text("用系统自带的充电上限")
                            note("在「系统设置 › 电池」里找「充电上限」，可以设 80%–100%。由固件执行，睡眠时也有效。")
                        }
                    } footer: {
                        footer("这台 Mac 的系统不允许第三方软件控制充电：macOS 27 起只有 Apple 自己能改，Bangs 和其他同类工具都一样。")
                    }
                } else {
                    Section {
                        note("没在这台 Mac 上找到能控制充电的方式。在终端运行 /Applications/Bangs.app/Contents/MacOS/Bangs --battery，把输出发给开发者可以帮助支持它。")
                    }
                }
            case .supported:
                limit
                status
            }
        }
        .onAppear { charge.refresh() }
        .onReceive(tick) { _ in charge.refresh() }
    }

    private var limit: some View {
        Section {
            Toggle(isOn: Binding(get: { preferences.chargeLimitOn }, set: { $0 ? charge.turnOn() : (preferences.chargeLimitOn = false) })) {
                Text("限制充电上限")
                note(charge.helper == .installed ? "到上限就停止充电，由电源直接给 Mac 供电；降到上限以下 \(ChargeLimit.resumeBelow)% 再充回去。"
                                                 : "第一次打开要输入管理员密码，安装一个以 root 运行的小助手来控制充电。")
            }
            .disabled(charge.busy)
            HStack {
                Text("上限")
                Slider(value: Binding(get: { Double(preferences.chargeLimit) }, set: { preferences.chargeLimit = Int($0) }),
                       in: Double(ChargeLimit.range.lowerBound)...Double(ChargeLimit.range.upperBound), step: 5)
                Text("\(preferences.chargeLimit)%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .disabled(!preferences.chargeLimitOn)
            if let error = charge.error {
                Text(error).foregroundStyle(.red).font(.system(size: 12))
            }
        } footer: {
            footer(charge.mode?.keepsLimit == true
                   ? "上限交给 Mac 的固件执行，睡眠和关机时也有效。"
                   : "合盖睡眠时：电量接近上限就先停充，免得睡着时充过头；离上限还远就照常充电。插着电源、正充向上限时，Mac 不会自己闲置睡眠。")
        }
    }

    private var status: some View {
        Section("状态") {
            if let battery = charge.battery {
                LabeledContent("电量", value: "\(battery.level)%")
                LabeledContent("充电", value: state(battery))
            }
            LabeledContent("充电助手") {
                HStack(spacing: 8) {
                    if charge.busy { ProgressView().controlSize(.small) }
                    switch charge.helper {
                    case .missing:
                        Text("未安装").foregroundStyle(.secondary)
                    case .outdated:
                        Text("需要更新").foregroundStyle(.orange)
                        Button("更新…") { charge.install() }.disabled(charge.busy)
                    case .installed:
                        Text("已安装").foregroundStyle(.secondary)
                        Button("移除…") { charge.uninstall() }.disabled(charge.busy)
                    }
                }
            }
        }
    }

    private func state(_ battery: Battery) -> String {
        if !battery.onPower { return "使用电池" }
        if charge.holding { return preferences.chargeLimitOn ? "已到上限，暂停充电，电源直接供电" : "暂停" }
        if battery.charging { return preferences.chargeLimitOn && battery.level < preferences.chargeLimit ? "正在充到 \(preferences.chargeLimit)%" : "正在充电" }
        return "已接电源，未在充电"
    }
}

/// Settings › 关于与更新: what Bangs is, the version, a check now, and whether to check daily.
struct AboutPane: View {
    @ObservedObject var updater: Updater
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bangs").font(.system(size: 17, weight: .semibold))
                        Text("版本 \(updater.current)").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("躲在刘海里，替你盯着本机所有在跑的编码 Agent。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section {
                HStack {
                    Text(summary).foregroundStyle(color)
                    Spacer()
                    switch updater.state {
                    case .available(let release):
                        Button("查看更新内容") { NSWorkspace.shared.open(release.page) }
                        Button("更新并重启") { Task { await updater.install(release) } }.keyboardShortcut(.defaultAction)
                    case .checking, .installing:
                        ProgressView().controlSize(.small)
                    default:
                        Button("检查更新") { Task { await updater.check() } }
                    }
                }
                Toggle(isOn: $preferences.checkForUpdates) {
                    Text("每天自动检查更新")
                    note("只向 GitHub 请求最新版本号，不上传任何数据；有新版本时刘海会提示一次。")
                }
            } header: {
                Text("更新")
            } footer: {
                footer("新版本必须和当前 Bangs 用同一张证书签名才会安装，所以权限和各 CLI 的 hooks 都会保留，也不用重新信任。")
            }
            Section("隐私") {
                note("所有数据只存在本机。唯一会联网的是上面的「检查更新」。")
            }
        }
        .formStyle(.grouped)
    }

    private var summary: String {
        switch updater.state {
        case .idle: "从 GitHub 获取新版本"
        case .checking: "正在检查…"
        case .upToDate: "已是最新版本"
        case .available(let release): "发现新版本 \(release.version)"
        case .installing: "正在下载并安装…"
        case .failed(let message): message
        }
    }

    private var color: Color {
        switch updater.state {
        case .available: .accentColor
        case .failed: .red
        default: .secondary
        }
    }
}
