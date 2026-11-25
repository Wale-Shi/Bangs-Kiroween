import AppKit
import BangsCore
import ServiceManagement
import SwiftUI
import Translation

struct ClipboardPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    let toolbox: Toolbox

    var body: some View {
        Pane(model: model) {
            Hero(pane: .clipboard, preferences: preferences)
            Section {
                Picker("保留", selection: $preferences.clipboardLimit) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0) 条").tag($0) }
                }
                Picker("保存时长", selection: $preferences.clipboardDays) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("一直").tag(0)
                }
                Toggle(isOn: $preferences.autoPaste) {
                    Text("回车直接粘贴到前台 App")
                    note(model.accessibility ? "已获得辅助功能权限。" : "需要辅助功能权限；没有时只复制，再自己按 ⌘V。")
                }
                LabeledContent {
                    Button("清空历史") { toolbox.clipboard.clear() }
                } label: {
                    Text("历史记录")
                    note("置顶的内容不会被清掉。")
                }
            } header: {
                Text("历史")
            } footer: {
                footer("只保存在本机（~/Library/Application Support/Bangs）。1Password 等密码管理器标记为隐藏或临时的内容不会保存。")
            }
            Section {
                Toggle(isOn: $preferences.transforms) {
                    Text("识别内容并提供转换")
                    note("选中一条文字时，下方按内容给出能做的转换；也可以在条目上右键。")
                }
                if preferences.transforms {
                    ForEach(Transform.Kind.allCases, id: \.self) { kind in
                        Toggle(isOn: Binding(get: { preferences.transformKinds.contains(kind) },
                                             set: { if $0 { preferences.transformKinds.insert(kind) } else { preferences.transformKinds.remove(kind) } })) {
                            Text(kind.title)
                            note(kind.example)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 10)
                    }
                    Picker("时间戳按", selection: $preferences.transformsInUTC) {
                        Text("本地时区（\(TimeZone.current.abbreviation() ?? TimeZone.current.identifier)）").tag(false)
                        Text("UTC").tag(true)
                    }
                    Picker(selection: $preferences.transformKeepsResult) {
                        Text("作为新条目并复制").tag(true)
                        Text("只复制，不进历史").tag(false)
                    } label: {
                        Text("转换结果")
                        note("原来那条保留不动。")
                    }
                }
            } header: {
                Text("开发者转换")
            }
            ShortcutRows(model: model, preferences: preferences, tool: .clipboard)
        }
    }
}

struct ScreenshotPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Pane(model: model) {
            Hero(pane: .screenshot, preferences: preferences)
            if !model.screenRecording {
                PermissionBanner(text: "截图和识字需要「屏幕录制」权限，打开后需要重启 Bangs。") {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Section("截图") {
                Toggle(isOn: $preferences.shotAnnotate) {
                    Text("选区截图后先标注")
                    note("框选后原地出现工具栏：矩形、椭圆、箭头、画笔、荧光笔、马赛克、文字、序号，可撤销、钉在屏幕上。回车或双击完成。关掉则框选完立即复制。")
                }
                Picker(selection: $preferences.shotPreview) {
                    Text("复制，并在刘海预览").tag(true)
                    Text("只复制").tag(false)
                } label: {
                    Text("截完之后")
                    note("截图总会复制到剪贴板并进入剪贴板历史；预览里可以再存到桌面或放进中转站。")
                }
                Picker(selection: $preferences.shotFolder) {
                    Text("不保存").tag(Preferences.ShotFolder.none)
                    Text("桌面").tag(Preferences.ShotFolder.desktop)
                    Text("下载").tag(Preferences.ShotFolder.downloads)
                } label: {
                    Text("同时保存到")
                    note("不另存时，截图文件在 Bangs 里保留 7 天（放在中转站里的不删）；剪贴板历史里的那份按剪贴板的设置保留。")
                }
                LabeledContent {
                    HoldKeyRecorder(key: $preferences.scrollLockKey)
                } label: {
                    Text("滚动截图锁定方向")
                    note(model.accessibility
                         ? "滚动时按住这个键，只保留当前的滚动方向，手抖也不会错位。可以是单个键，也可以只按一个修饰键（如 ⌥）。"
                         : "需要辅助功能权限。滚动时按住这个键，只保留当前的滚动方向，手抖也不会错位。")
                }
                if let conflict = preferences.scrollLockKey.conflict {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Section("识字") {
                Picker(selection: $preferences.ocrLanguage) {
                    ForEach(TextRecognition.Language.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("识别语言")
                    note("在本机用 Apple 的文字识别，不联网。")
                }
                Toggle(isOn: $preferences.ocrJoinsLines) {
                    Text("合并段落里的换行")
                    note("截一段文章时，复制出来是整段，而不是一行一行。代码和列表保留换行。")
                }
                Picker(selection: $preferences.ocrShowsResult) {
                    Text("复制文字，并在刘海显示").tag(true)
                    Text("只复制文字").tag(false)
                } label: {
                    Text("识别完之后")
                    note("刘海里显示识别出的文字，可以改一下再复制。")
                }
                Toggle(isOn: $preferences.ocrOpensLinks) {
                    Text("识别出链接时提供「打开」")
                    note("识别出的只有一个链接时。")
                }
                Toggle(isOn: $preferences.ocrTables) {
                    Text("识别到表格时按表格复制")
                    note("粘贴到 Excel、Numbers、WPS、飞书表格时按单元格分开，合并单元格也保留。刘海里可以改回纯文本复制。")
                }
            }
            ShortcutRows(model: model, preferences: preferences, tool: .screenshot, footnote: "选区、窗口、滚动截图默认不设快捷键，保留系统的 ⇧⌘3 / ⇧⌘4；截图识字默认 ⌥⇧⌘T。")
        }
    }
}

struct FocusPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var timer: FocusTimer

    var body: some View {
        Pane(model: model) {
            Hero(pane: .focus, preferences: preferences)
            Section("今天") {
                HStack(spacing: 32) {
                    stat("\(timer.day.rounds) 轮", "完成的专注")
                    stat(FocusTimer.hours(timer.day.seconds), "专注时长")
                    stat("\(timer.day.agents)", "期间跑完的 Agent")
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section("时长") {
                minutes("专注", $preferences.focusMinutes, [15, 20, 25, 30, 45, 50, 60])
                minutes("短休息", $preferences.shortBreakMinutes, [3, 5, 10])
                Picker(selection: $preferences.longBreakMinutes) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
                } label: {
                    Text("长休息")
                    note("每 \(FocusTimer.roundsPerCycle) 轮专注之后一次。")
                }
                Toggle("专注结束后自动开始休息", isOn: $preferences.focusStartsBreak)
                Toggle("休息结束后自动开始下一轮", isOn: $preferences.breakStartsFocus)
            }
            Section("刘海") {
                Toggle(isOn: $preferences.focusInNotch) {
                    Text("收起时显示倒计时")
                    note("和会议用同一种倒计时圈，专注是蓝色、休息是绿色；会议快开始时让给会议。")
                }
                Toggle("结束时展开提醒", isOn: $preferences.focusAlerts)
                Picker("提示音", selection: $preferences.focusSound) {
                    ForEach(FocusTimer.sounds, id: \.name) { Text($0.title).tag($0.name) }
                }
                .onChange(of: preferences.focusSound) { _, _ in timer.playSound() }
            }
            Section("专注期间") {
                Toggle(isOn: $preferences.focusQuiet) {
                    Text("Agent 跑完时不展开刘海")
                    note("只在刘海里亮绿点，休息时再告诉你有几个跑完了。等你审批的请求仍然会弹出。")
                }
                Toggle("防止 Mac 休眠", isOn: $preferences.focusKeepsAwake)
            }
            ShortcutRows(model: model, preferences: preferences, tool: .focus)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
            note(label)
        }
    }

    private func minutes(_ title: String, _ value: Binding<Int>, _ options: [Int]) -> some View {
        Picker(title, selection: value) {
            ForEach(options, id: \.self) { Text("\($0) 分钟").tag($0) }
        }
    }
}

struct CalendarPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var agenda: Agenda

    var body: some View {
        Pane(model: model) {
            Hero(pane: .calendar, preferences: preferences)
            if agenda.access != .granted {
                PermissionBanner(text: "日程提醒需要读取日历的权限。") {
                    agenda.requestAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
            Section("提醒") {
                Picker(selection: $preferences.meetingLead) {
                    ForEach([1, 3, 5, 10, 15], id: \.self) { Text("\($0) 分钟").tag($0) }
                } label: {
                    Text("会议提前提醒")
                    note("提前这么久开始倒计时，并展开提醒一次。")
                }
                Toggle("会议开始时再提醒一次", isOn: $preferences.meetingStartReminder)
                Toggle(isOn: $preferences.meetingsWithLinkOnly) {
                    Text("只提醒带会议链接的日程")
                    note("Zoom、Google Meet、Teams、飞书、腾讯会议。")
                }
            }
        }
    }
}

struct ShelfPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Pane(model: model) {
            Hero(pane: .shelf, preferences: preferences)
            Section {
                Toggle("拖到刘海附近时展开接住", isOn: $preferences.shelfCatchesDrags)
                Toggle("文件拖出后从中转站移除", isOn: $preferences.shelfRemovesOnDragOut)
            } header: {
                Text("中转站")
            } footer: {
                footer("关掉「展开接住」后，仍可以把文件直接拖到刘海上。")
            }
        }
    }
}

struct FilesPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var search: FileSearch
    @State private var newExclusion = ""

    var body: some View {
        Pane(model: model) {
            Hero(pane: .files, preferences: preferences)
            Section {
                Toggle(isOn: $preferences.fileSearch) {
                    Text("建立文件名索引")
                    note(preferences.fileSearch ? status : "关闭时不扫描任何文件夹；关掉会删除已建的索引。")
                }
                if preferences.fileSearch {
                    LabeledContent("重新扫描全部文件夹") {
                        Button("重新扫描") { search.rebuild() }.disabled(search.status.state != .ready || search.status.rebuilding)
                    }
                }
            } header: {
                Text("索引")
            } footer: {
                footer("平时跟着 macOS 的文件变化通知自动更新，不用手动扫描。索引保存在 Bangs 的数据目录里，下次启动直接读取。")
            }
            Section {
                Toggle(isOn: Binding(get: { preferences.fileSearchWholeDisk }, set: { on in
                    preferences.fileSearchWholeDisk = on
                    if on && !search.fullDiskAccess { FileSearchSettings.openFullDiskAccess() }
                })) {
                    Text("整盘搜索")
                    note("加上资源库、/opt、/usr/local 等整个启动磁盘；不含只读的系统卷和外接磁盘。内存会多用一些（通常 30～60 MB）。")
                }
                if preferences.fileSearchWholeDisk && !search.fullDiskAccess {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("需要「完全磁盘访问权限」，否则邮件、信息、Safari 等受保护的位置搜不到。打开后回到这里会自动重新扫描。")
                            .font(.system(size: 12))
                        Spacer()
                        Button("允许…") { FileSearchSettings.openFullDiskAccess() }
                    }
                }
            } header: {
                Text("范围")
            } footer: {
                footer("关闭整盘时，索引家目录（不含资源库和废纸篓）、应用程序和 iCloud 云盘；第一次扫描时 macOS 会问能否访问桌面、文稿和下载。")
            }
            Section {
                FlowLayout(spacing: 6) {
                    ForEach(preferences.fileExclusions, id: \.self) { name in
                        HStack(spacing: 4) {
                            Text(name).font(.system(size: 11.5, design: .monospaced))
                            Button { preferences.fileExclusions.removeAll { $0 == name } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("扫描「\(name)」")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                .padding(.vertical, 2)
                HStack {
                    TextField("", text: $newExclusion, prompt: Text("文件夹名，如 vendor"))
                        .onSubmit(add)
                    Button("添加", action: add).disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                    if preferences.fileExclusions != FileIndex.defaultExclusions {
                        Button("恢复默认") { preferences.fileExclusions = FileIndex.defaultExclusions }
                    }
                }
            } header: {
                Text("不扫描的文件夹")
            } footer: {
                footer("按名字匹配，不管在哪一层，不分大小写。这些文件夹本身搜得到，里面的文件不收录。应用、照片图库这类文件包也不进入内部。")
            }
            ShortcutRows(model: model, preferences: preferences, tool: .files, footnote: "⇧⌘F 也是很多编辑器里「在项目中查找」的快捷键；在编辑器里按会被 Bangs 抢先。常用的话可以换一个。")
        }
        .onAppear { search.refreshAccess() }
    }

    private var status: String {
        let status = search.status
        switch status.state {
        case .off, .loading: return "正在读取索引…"
        case .scanning(let found): return "正在建立索引，已找到 \(FileSearch.count(found)) 个"
        case .ready:
            return "已索引 \(FileSearch.count(status.count)) 个文件和文件夹，内存约 \(max(1, status.bytes / 1_000_000)) MB" + (status.rebuilding ? "，正在重新扫描" : "")
        }
    }

    private func add() {
        let name = newExclusion.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return }
        if !preferences.fileExclusions.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { preferences.fileExclusions.append(name) }
        newExclusion = ""
    }
}

/// Lays its children out in rows, wrapping like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], y: CGFloat, width: CGFloat, height: CGFloat) = ([], 0, 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = ([], current.y + current.height + spacing, 0, 0)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

struct TranslatePane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator
    @State private var key = ""
    /// The language pair macOS is downloading, and what went wrong last time.
    @State private var downloading: [String]?
    @State private var downloadFailure: String?
    /// Bumped when a download ends, so the rows look again.
    @State private var checked = 0

    var body: some View {
        Pane(model: model) {
            Hero(pane: .translate, preferences: preferences)
            if !model.accessibility {
                PermissionBanner(text: "读取别的 App 里选中的文字需要「辅助功能」权限。截图识字后的「翻译」不需要。") {
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
            }
            Section {
                Picker(selection: $preferences.translateEngine) {
                    ForEach(TranslateEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("翻译方式")
                    note(engineNote)
                }
            } footer: {
                footer("选中的文字只在你选「大模型 API」或「本机 Agent」时离开 Bangs，发给你配置的那一个；不保存翻译记录。刘海里点右上角的名字，可以临时换一种方式。")
            }
            switch preferences.translateEngine {
            case .apple: applePacks
            case .model: ModelSettings(preferences: preferences, key: $key, mine: preferences.translateMine)
            case .agent: AgentSettings(preferences: preferences, mine: preferences.translateMine)
            }
            Section {
                Picker(selection: $preferences.translateMine) {
                    ForEach(TranslateLanguage.all, id: \.self) { Text(TranslateLanguage.name($0)).tag($0) }
                } label: {
                    Text("我的语言")
                    note("别的语言都翻译成它。")
                }
                Picker(selection: $preferences.translateOther) {
                    ForEach(TranslateLanguage.all.filter { $0 != preferences.translateMine }, id: \.self) { Text(TranslateLanguage.name($0)).tag($0) }
                } label: {
                    Text("第二语言")
                    note("选中的是我的语言时，翻译成它。刘海里点目标语言可以临时换一种。")
                }
            } header: {
                Text("语言")
            }
            Section {
                Toggle(isOn: $preferences.translateCopies) {
                    Text("读不到时用 ⌘C 复制选中的文字")
                    note("有些 App（如 VS Code、部分网页）不把选中的文字告诉辅助功能。这时 Bangs 替你按一次 ⌘C，取到文字后马上把剪贴板原样放回，也不记进剪贴板历史。密码框里不会这样做。")
                }
            } header: {
                Text("读取选中的文字")
            }
            ShortcutRows(model: model, preferences: preferences, tool: nil, footnote: "在 Finder 里 ⌥⌘T 是显示 / 隐藏工具栏，会被 Bangs 抢先；常用的话可以换一个。", only: [.translate])
        }
        // The download runs from the page rather than its row: macOS shows its sheet on this window, and a row in a form
        // can be redrawn (and its task dropped) while the sheet is up.
        .modifier(PackDownload(pair: $downloading, failure: $downloadFailure) { checked += 1 })
        .onAppear { key = TranslateKey.read() }
    }

    private var engineNote: String {
        switch preferences.translateEngine {
        case .apple: "macOS 自带的翻译，在本机完成，不联网；每两种语言要先下载一次语言包。"
        case .model: "发给你填的 API 地址，由那里的模型翻译：OpenAI 兼容的服务（DeepSeek、通义千问、Kimi、OpenRouter、本机的 Ollama 等）或 Anthropic。"
        case .agent: "交给这台 Mac 上的编码 Agent 翻译，用它自己的登录和额度，通过 Agent Client Protocol（ACP）通信。"
        }
    }

    @ViewBuilder private var applePacks: some View {
        if #available(macOS 15, *) {
            Section {
                ForEach(pairs, id: \.self) { pair in
                    LanguagePackRow(from: pair[0], to: pair[1], checked: checked, downloading: downloading == pair) {
                        downloadFailure = nil
                        NSApp.activate()
                        downloading = pair
                    }
                }
                if let downloadFailure {
                    Label(downloadFailure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
                }
                LabeledContent("也可以在系统设置里下载和删除") {
                    Button("打开系统设置…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!) }
                }
            } header: {
                Text("语言包")
            } footer: {
                footer("语言包由 macOS 下载并管理（「系统设置 › 通用 › 语言与地区 › 翻译语言」）。下载之后翻译完全在本机进行。")
            }
        } else {
            Section { Label("macOS 本机翻译需要 macOS 15 或更新版本；可以改用大模型 API 或本机 Agent。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    /// Your two languages both ways, and the pair the island last found missing.
    private var pairs: [[String]] {
        var pairs = [[preferences.translateOther, preferences.translateMine], [preferences.translateMine, preferences.translateOther]]
        if translator.phase == .needsDownload, let from = translator.from {
            let missing = [from, translator.to]
            if !pairs.contains(missing) { pairs.insert(missing, at: 0) }
        }
        return pairs
    }
}

/// One direction between two languages: downloaded, downloadable, being downloaded, or not offered.
@available(macOS 15, *)
private struct LanguagePackRow: View {
    let from: String
    let to: String
    let checked: Int
    let downloading: Bool
    let download: () -> Void
    @State private var status: LanguageAvailability.Status?

    var body: some View {
        LabeledContent {
            if downloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("下载中…").foregroundStyle(.secondary)
                }
            } else {
                switch status {
                case .installed: Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .supported: Button("下载…", action: download)
                case .unsupported: Text("不支持").foregroundStyle(.secondary)
                case nil: ProgressView().controlSize(.small)
                @unknown default: Text("—").foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("\(TranslateLanguage.name(from)) → \(TranslateLanguage.name(to))")
        }
        .task(id: "\(from)>\(to)#\(checked)") {
            status = await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        }
    }
}

/// Asks macOS to download a pair's language pack (it shows its own sheet to confirm), then waits for the download to
/// finish, which goes on after the sheet closes.
private struct PackDownload: ViewModifier {
    @Binding var pair: [String]?
    @Binding var failure: String?
    let finished: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(Running(pair: $pair, failure: $failure, finished: finished))
        } else {
            content
        }
    }

    @available(macOS 15, *)
    private struct Running: ViewModifier {
        @Binding var pair: [String]?
        @Binding var failure: String?
        let finished: () -> Void
        @State private var configuration: TranslationSession.Configuration?

        func body(content: Content) -> some View {
            content
                .translationTask(configuration) { session in
                    guard let pair, pair.count == 2 else { return }
                    let (from, to) = (Locale.Language(identifier: pair[0]), Locale.Language(identifier: pair[1]))
                    do {
                        try await session.prepareTranslation()
                        // Approved: the pack downloads in the background; the row shows it until it is there (ten minutes at most).
                        for _ in 0..<300 {
                            if await LanguageAvailability().status(from: from, to: to) == .installed { break }
                            try await Task.sleep(for: .seconds(2))
                        }
                    } catch is CancellationError {
                    } catch {
                        failure = "没有下载：\(error.localizedDescription)。可以点下面的按钮，在系统设置里下载。"
                    }
                    self.pair = nil
                    configuration = nil
                    finished()
                }
                .onChange(of: pair) { _, pair in
                    guard let pair, pair.count == 2 else { return }
                    configuration = TranslationSession.Configuration(source: Locale.Language(identifier: pair[0]), target: Locale.Language(identifier: pair[1]))
                }
        }
    }
}

/// The address, key and model of a chat API, filled in by hand or from a common service, and a test translation.
private struct ModelSettings: View {
    @ObservedObject var preferences: Preferences
    @Binding var key: String
    let mine: String

    var body: some View {
        Section {
            LabeledContent("常用服务") {
                Menu("填入…") {
                    ForEach(ModelAPI.presets, id: \.self) { preset in
                        Button(preset.name) {
                            preferences.translateAPIFormat = preset.format
                            preferences.translateAPIURL = preset.url
                            if !preset.model.isEmpty { preferences.translateAPIModel = preset.model }
                        }
                    }
                }
                .fixedSize()
            }
            Picker("接口格式", selection: $preferences.translateAPIFormat) {
                ForEach(ModelAPI.Format.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("API 地址", text: $preferences.translateAPIURL, prompt: Text(preferences.translateAPIFormat == .openAI ? "https://api.openai.com/v1" : "https://api.anthropic.com"))
            SecureField("API Key", text: $key, prompt: Text("本机的 Ollama 等可以不填"))
                .onChange(of: key) { _, key in TranslateKey.write(key) }
            TextField("模型", text: $preferences.translateAPIModel, prompt: Text(preferences.translateAPIFormat == .openAI ? "如 deepseek-chat、qwen-plus" : "如 claude-opus-5-5"))
            TestRow(engine: .model, preferences: preferences, mine: mine)
        } header: {
            Text("大模型 API")
        } footer: {
            footer("OpenAI 兼容的地址写到 /v1 为止（Bangs 会接上 /chat/completions）。API Key 存在「钥匙串」里，不写进设置文件。按用量计费的服务会按它的价格收费。")
        }
    }
}

/// Which agent translates, whether it is installed, and a test translation.
private struct AgentSettings: View {
    @ObservedObject var preferences: Preferences
    let mine: String
    @State private var found: String??

    private var command: String {
        (preferences.translateAgent == "custom" ? preferences.translateAgentCommand : ACPAgent.preset(preferences.translateAgent)?.command ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        Section {
            Picker("Agent", selection: $preferences.translateAgent) {
                ForEach(ACPAgent.presets, id: \.id) { Text($0.name).tag($0.id) }
                Text("自定义命令").tag("custom")
            }
            if preferences.translateAgent == "custom" {
                TextField("启动命令", text: $preferences.translateAgentCommand, prompt: Text("以 ACP 方式启动 Agent 的命令，如 gemini --acp"))
            }
            LabeledContent("命令") {
                Text(command.isEmpty ? "—" : command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            switch found {
            case .some(.some(let path)):
                Label("已找到：\(path)", systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.green)
            case .some(.none):
                if let preset = ACPAgent.preset(preferences.translateAgent) {
                    LabeledContent {
                        Button("复制安装命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(preset.install, forType: .string)
                        }
                    } label: {
                        Text("这台 Mac 上没有找到 \(command.split(separator: " ").first ?? "")")
                        note("在终端里运行 \(preset.install)，装好后再试。")
                    }
                } else {
                    Label("没有找到这个命令。", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
                }
            case .none:
                EmptyView()
            }
            TestRow(engine: .agent, preferences: preferences, mine: mine)
        } header: {
            Text("本机 Agent")
        } footer: {
            footer("Bangs 每次翻译开一个新会话，不给 Agent 读写文件和终端，它要用工具时一律拒绝；这个会话不会出现在 Bangs 的会话列表里。Agent 用它自己的登录和额度；闲置 5 分钟后退出。Claude Code 和 Codex 要先装各自的 ACP 适配器。")
        }
        .task(id: command) {
            found = nil
            let program = command.split(separator: " ").first.map(String.init) ?? ""
            guard !program.isEmpty else { return }
            found = .some(await Task.detached { ShellPath.locate(program) }.value)
        }
    }
}

/// Translates a sentence with what is set up, to show it works (or what is wrong) before it is needed.
private struct TestRow: View {
    let engine: TranslateEngine
    @ObservedObject var preferences: Preferences
    let mine: String
    @State private var result: String?
    @State private var failed = false
    @State private var running = false

    var body: some View {
        LabeledContent {
            Button(running ? "翻译中…" : "测试") { Task { await test() } }.disabled(running)
        } label: {
            Text("试一下")
            if let result {
                Text(result).font(.system(size: 11.5)).foregroundStyle(failed ? .orange : .secondary).textSelection(.enabled)
            }
        }
    }

    private func test() async {
        running = true
        failed = false
        result = nil
        let sample = mine == "en" ? "这一轮改了 3 个文件，测试都通过了。" : "This turn changed 3 files, and all the tests passed."
        let stream: AsyncThrowingStream<String, Error> = switch engine {
        case .model: ModelAPI.stream(text: sample, to: mine, format: preferences.translateAPIFormat, base: preferences.translateAPIURL,
                                     model: preferences.translateAPIModel, key: TranslateKey.read())
        default: ACPAgent.shared.translate(sample, to: mine,
                                           command: preferences.translateAgent == "custom" ? preferences.translateAgentCommand : ACPAgent.preset(preferences.translateAgent)?.command ?? "")
        }
        var text = ""
        do {
            for try await piece in stream { text += piece; result = text }
            result = text.isEmpty ? "没有收到译文。" : "✓ \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            failed = text.isEmpty
        } catch {
            result = error.localizedDescription
            failed = true
        }
        running = false
    }
}
