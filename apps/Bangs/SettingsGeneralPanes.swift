import AppKit
import BangsCore
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Pane(model: model) {
            Section("位置") {
                Picker(selection: $preferences.placement) {
                    Text(hasNotch ? "刘海" : "自动（这台 Mac 没有刘海，放在菜单栏）").tag(Preferences.Placement.auto)
                    Text("菜单栏").tag(Preferences.Placement.menuBar)
                } label: {
                    Text("显示在")
                    note("没有刘海的 Mac（或合盖接外接显示器）会自动放进菜单栏。")
                }
                if inNotch {
                    Picker(selection: $preferences.notchStyle) {
                        Text("常显").tag(Preferences.NotchStyle.always)
                        Text("没有任务时藏进刘海").tag(Preferences.NotchStyle.autoHide)
                        Text("隐藏").tag(Preferences.NotchStyle.hidden)
                    } label: {
                        Text("收起时")
                        note(styleNote)
                    }
                }
                Picker(selection: $preferences.usageInNotch) {
                    Text("不显示").tag(Preferences.Usage.off)
                    Text("CPU").tag(Preferences.Usage.cpu)
                    Text("内存").tag(Preferences.Usage.memory)
                } label: {
                    Text("收起时显示占用")
                    note("和 Agent 状态、会议或专注倒计时叠在一起显示。")
                }
            }
            Section {
                HStack {
                    Toggle(isOn: .constant(true)) { Label(Tool.sessions.title, systemImage: Tool.sessions.symbol) }
                        .toggleStyle(.checkbox)
                        .disabled(true)
                    Spacer()
                    Text("固定").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(preferences.toolOrder, id: \.self) { tool in
                    HStack {
                        Toggle(isOn: Binding(get: { preferences.shows(tool) }, set: { preferences.setShows(tool, $0) })) {
                            Label(tool.title, systemImage: tool.symbol)
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        move(tool, by: -1, symbol: "chevron.up")
                        move(tool, by: 1, symbol: "chevron.down")
                    }
                }
                .onMove { preferences.toolOrder.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("刘海里的标签")
            } footer: {
                footer("勾掉不用的工具，用箭头调整顺序。「会话」固定在最前面。")
            }
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
    }

    private func move(_ tool: Tool, by offset: Int, symbol: String) -> some View {
        let index = preferences.toolOrder.firstIndex(of: tool) ?? 0
        let target = index + offset
        return Button {
            preferences.toolOrder.swapAt(index, target)
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .disabled(!preferences.toolOrder.indices.contains(target))
        .help(offset < 0 ? "往前移" : "往后移")
    }

    private var hasNotch: Bool { NotchGeometry.notchScreen != nil }
    private var inNotch: Bool { hasNotch && preferences.placement == .auto }
    private var styleNote: String {
        switch preferences.notchStyle {
        case .always: "刘海两侧一直显示状态图标和正在跑的 Agent。"
        case .autoHide: "没有会话在跑时缩回刘海，鼠标移上去探出来；有会话在跑、待审批或刚完成时自动出现。"
        case .hidden: "平时和系统刘海一样大；只在需要审批或有提醒（完成、会议、截图）时展开，之后收回。点刘海可打开列表。"
        }
    }
}

struct AgentsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var history: SessionHistory
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsMissing = false

    var body: some View {
        Pane(model: model) {
            Section {
                if detected.isEmpty {
                    Text("这台 Mac 上还没有找到支持的 CLI。").foregroundStyle(.secondary)
                }
                ForEach(detected) { row($0) }
            } header: {
                Text("这台 Mac 上的 CLI")
            } footer: {
                footer("「刘海审批」：要权限时在刘海里直接允许或拒绝。「仅状态」：这几个 CLI 的 hooks 没法只在真要问你时介入，刘海只提醒你回终端确认。")
            }
            if !missing.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsMissing) {
                        ForEach(missing) { row($0) }
                    } label: {
                        Text("其他支持的 CLI（\(missing.count) 个，未安装）")
                    }
                }
            }
            Section {
                Toggle(isOn: $preferences.sessionHistory) {
                    Text("在会话标签里搜索历史会话")
                    note("搜标题、你输入过的提示词、Agent 的回复和执行过的命令、项目、分支、会话 ID。只在本机读取各 CLI 自己保存的记录，不复制、不上传。")
                }
                if preferences.sessionHistory {
                    Toggle("包括 Codex 里已归档的对话", isOn: $preferences.historyIncludesArchived)
                    LabeledContent {
                        if let progress = history.progress {
                            Text("正在读取 \(progress.done) / \(progress.total)").foregroundStyle(.secondary)
                        } else {
                            let counts = Harness.allCases.compactMap { harness in history.count(of: harness) > 0 ? "\(harness.displayName) \(history.count(of: harness))" : nil }
                            Text(counts.isEmpty ? "还没有" : counts.joined(separator: " · ")).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    } label: {
                        Text("能搜到的会话")
                        note("读取 Claude Code、Codex、Gemini CLI、CodeBuddy、OpenCode、pi 和 omp 的记录。")
                    }
                    .onAppear { history.refresh(force: true) }
                }
            } header: {
                Text("历史会话")
            } footer: {
                footer("在搜索结果里选中一个历史会话按回车，会新开一个终端窗口，进入它原来的目录再执行恢复命令（用的是默认打开 .command 文件的终端）。")
            }
            Section {
                Toggle(isOn: $preferences.showsUsage) {
                    Text("显示用量上限和上下文")
                    note("会话列表下方显示各 CLI 的 5 小时和每周额度用了多少，每个会话旁显示上下文用了多少。Codex 的从它自己的会话记录里读取。")
                }
                if preferences.showsUsage, model.statusLine != .notDetected {
                    Toggle(isOn: Binding(get: { model.statusLine == .on || model.statusLine == .outdated }, set: { model.setRelay($0) })) {
                        Text("读取 Claude Code 的用量上限")
                        note("Claude Code 只把额度告诉它的状态栏命令。开启后 Bangs 接管状态栏命令：收到的信息转给 Bangs，再运行你原来的状态栏，显示不变。关闭即还原。")
                    }
                }
                Toggle(isOn: $preferences.turnChanges) {
                    Text("每一轮结束后统计改动")
                    note("在 git 仓库里工作的会话，回合结束时显示这一轮改了哪些文件、增删多少行，点开可看 diff。只读，不会写入仓库。")
                }
                Toggle(isOn: $preferences.sessionAllow) {
                    Text("审批时可选「本会话都允许」")
                    note("同一会话里同类请求不再询问，直到会话结束：命令按程序和子命令（如 swift build）、改文件只限项目内、其他工具按名称。标为「注意」「危险」的请求总会询问；会话右键菜单可恢复询问。")
                }
            } header: {
                Text("用量与改动")
            }
            ShortcutRows(model: model, preferences: preferences, tool: .sessions)
            Section("说明") {
                VStack(alignment: .leading, spacing: 6) {
                    note("安装会在对应 CLI 的 hooks 配置里追加 Bangs 的条目，不会改动其他工具的 hooks；写入共享的配置文件前会在同目录留一份 .bak 备份。")
                    note("需要审批的操作会先在刘海里询问；选择「在终端处理」或 30 分钟未处理时回到 CLI 自己的提示。")
                    note("带有 BANGS_IGNORE 环境变量的会话（以及 Muster 运行的 Agent）不会出现在刘海里。")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var detected: [SettingsModel.Row] { model.rows.filter { $0.state != .notDetected } }
    private var missing: [SettingsModel.Row] { model.rows.filter { $0.state == .notDetected } }

    private func row(_ row: SettingsModel.Row) -> some View {
        HStack(spacing: 12) {
            HarnessIcon(harness: row.harness, size: 22, onDark: colorScheme == .dark)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.harness.displayName).font(.system(size: 13, weight: .medium))
                    Text(row.harness.answersPermissions ? "刘海审批" : "仅状态")
                        .font(.system(size: 10))
                        .foregroundStyle(row.harness.answersPermissions ? Color.accentColor : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().strokeBorder(row.harness.answersPermissions ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.35)))
                }
                Text(detail(row)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            if model.working.contains(row.harness) {
                ProgressView().controlSize(.small)
            } else { switch row.state {
            case .notDetected:
                EmptyView()
            case .notInstalled:
                Button("安装") { model.install(row.harness) }
            case .outdated:
                Button("更新") { model.install(row.harness) }
                Button("卸载") { model.uninstall(row.harness) }
            case .installed:
                Label("已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                Button("卸载") { model.uninstall(row.harness) }
            } }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ row: SettingsModel.Row) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = { (path: String) in path.replacingOccurrences(of: home, with: "~") }
        if row.state == .notDetected { return "没有找到 \(short(row.harness.home(in: FileManager.default.homeDirectoryForCurrentUser).path))" }
        var parts = [short(model.installer(row.harness).file.path)]
        if row.state == .outdated { parts.append("需要更新（App 位置或版本变了）") }
        switch row.harness {
        case .cursor: parts = ["使用 Claude Code 的 hooks（Cursor 默认会读取）"] + parts.dropFirst()
        case .codex: parts.append("安装后 Codex 会请你确认一次")
        case .codebuddy: parts.append("安装后在 CodeBuddy 的 /hooks 中确认")
        case .kiro: parts.append("需要 Kiro CLI V3")
        case .opencode: parts.append("以插件方式安装")
        case .pi, .omp: parts.append("以扩展方式安装，重启 \(row.harness.displayName) 后生效")
        case .hermes: parts.append("以插件方式安装，Hermes 会自动加载；只显示终端里的会话")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
