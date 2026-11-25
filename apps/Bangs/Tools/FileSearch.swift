import AppKit
import Combine
import SwiftUI

/// The files tab: a name typed, the files that have it, from an index kept up to date in the background.
@MainActor
final class FileSearch: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selection = 0; notice = nil; schedule() } } }
    /// Only one kind of file; nil for all.
    @Published var kind: FileKind? { didSet { if kind != oldValue { selection = 0; schedule(delay: 0) } } }
    @Published var selection = 0
    @Published private(set) var results = FileIndex.Results()
    @Published private(set) var status = FileIndex.Status()
    /// Bumped to give the search field the keyboard.
    @Published var focusRequest = 0
    /// A word for a moment after an action ("已复制路径").
    @Published var notice: String?
    @Published private(set) var fullDiskAccess = FileSearch.hasFullDiskAccess()

    let index: FileIndex
    let preferences: Preferences
    /// What to index for the settings; snapshots point it at sample folders.
    var scope: (_ wholeDisk: Bool, _ exclusions: [String]) -> FileIndex.Scope = { FileIndex.Scope.make(wholeDisk: $0, exclusions: $1) }
    private var generation = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(preferences: Preferences, index: FileIndex = FileIndex()) {
        self.preferences = preferences
        self.index = index
        index.onStatus = { [weak self] status in
            guard let self else { return }
            let became = status.state == .ready && self.status.state != .ready
            let changed = status.count != self.status.count
            self.status = status
            // A search typed while the index was still being built, or files that came or went since.
            if active && (became || changed) { schedule(delay: 0) }
        }
        preferences.$fileSearch.combineLatest(preferences.$fileSearchWholeDisk, preferences.$fileExclusions)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] on, wholeDisk, exclusions in
                guard let self else { return }
                if on {
                    index.start(scope(wholeDisk, exclusions))
                } else {
                    index.stop()
                    clear()
                }
            }
            .store(in: &subscriptions)
    }

    var active: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func clear() {
        query = ""
        kind = nil
    }

    /// Starts the index for the first time.
    func enable() {
        preferences.fileSearch = true
        focusRequest += 1
    }

    func rebuild() { index.rebuild() }

    /// Whether Bangs may read every folder: the system's own privacy database is readable only then.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Checks again (the settings window opening, the island opening on this tab); rebuilds once access comes, so the
    /// folders it opens are read.
    func refreshAccess() {
        let granted = Self.hasFullDiskAccess()
        guard granted != fullDiskAccess else { return }
        fullDiskAccess = granted
        if granted, preferences.fileSearch, preferences.fileSearchWholeDisk { rebuild() }
    }

    private func schedule(delay: Int = 60) {
        generation += 1
        let generation = generation
        guard active else { results = FileIndex.Results(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, generation == self.generation else { return }
            index.search(query, kind: kind) { [weak self] results in
                guard let self, generation == self.generation else { return }
                self.results = results
                if selection >= results.hits.count { selection = max(0, results.hits.count - 1) }
            }
        }
    }

    // MARK: Keyboard

    enum KeyResult { case ignored, handled, open(FileIndex.Hit) }

    /// ↑↓ choose, return opens, ⌘return shows it in the Finder, ⇧⌘C copies its path, Esc clears.
    func handle(_ event: NSEvent) -> KeyResult {
        guard active else { return .ignored }
        let hits = results.hits
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chosen = hits.indices.contains(selection) ? hits[selection] : nil
        switch event.keyCode {
        case 125: if !hits.isEmpty { selection = min(selection + 1, hits.count - 1) }; return .handled
        case 126: selection = max(selection - 1, 0); return .handled
        case 53: clear(); return .handled
        case 36, 76:
            guard let chosen else { return .handled }
            if flags == .command { reveal(chosen); return .handled }
            return .open(chosen)
        case 8 where flags == [.command, .shift]:
            if let chosen { copyPath(chosen) }
            return .handled
        default: return .ignored
        }
    }

    // MARK: Actions

    /// Opens a file with its app, a folder in the Finder, an app by launching it. False when it is gone.
    @discardableResult
    func open(_ hit: FileIndex.Hit) -> Bool {
        guard FileManager.default.fileExists(atPath: hit.path) else { say("找不到这个文件了，可能刚被移走"); return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
        return true
    }

    func reveal(_ hit: FileIndex.Hit) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
    }

    func copyPath(_ hit: FileIndex.Hit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.path, forType: .string)
        say("已复制路径")
    }

    func copyFile(_ hit: FileIndex.Hit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: hit.path) as NSURL])
        say("已复制文件，可以粘贴到访达或聊天窗口")
    }

    func say(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.notice == text { self?.notice = nil }
        }
    }

    /// A folder as people know it: ~ for home, iCloud Drive by its name.
    static func display(_ folder: String) -> String {
        let home = NSHomeDirectory()
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if folder == drive || folder.hasPrefix(drive + "/") { return "iCloud 云盘" + folder.dropFirst(drive.count) }
        if folder == home || folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// "14.4 万", "8,213".
    static func count(_ number: Int) -> String {
        number >= 10_000 ? String(format: "%.1f 万", Double(number) / 10_000) : number.formatted()
    }
}

// MARK: Views

/// The files tab: an introduction until the index is started, then the search.
struct FileSearchView: View {
    @ObservedObject var search: FileSearch
    @ObservedObject var model: NotchModel
    @ObservedObject var preferences: Preferences

    init(search: FileSearch, model: NotchModel) {
        self.search = search
        self.model = model
        preferences = search.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !preferences.fileSearch {
                FileSearchIntro(search: search, model: model)
            } else {
                FileSearchField(search: search).padding(.bottom, 4)
                if search.active && search.status.state == .ready {
                    FileSearchResults(search: search, model: model)
                } else {
                    FileIndexSummary(search: search, model: model)
                }
            }
        }
        .onAppear { search.refreshAccess() }
    }
}

private struct FileSearchIntro: View {
    @ObservedObject var search: FileSearch
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("输入文件名，立刻找到文件").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("像 Windows 上的 Everything：不等 Spotlight，几毫秒出结果").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                bullet("先给家目录、应用程序和 iCloud 云盘建一份文件名索引，通常不到一分钟；之后跟着文件变化自动更新。")
                bullet("只记文件名，不读内容；索引只存在这台 Mac 上。node_modules、编译产物和缓存目录不收录。")
                bullet("macOS 会问能否访问桌面、文稿和下载，允许后才能搜到那里的文件。整盘搜索可以在设置里打开。")
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: "设置…", style: .plain) { model.openSettings() }
                PillButton(title: "开始建立索引", style: .warn) { search.enable() }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.wash(0.06)))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Palette.dim).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FileSearchField: View {
    @ObservedObject var search: FileSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
            TextField("", text: $search.query, prompt: Text("搜索文件名，多个词用空格分开").foregroundColor(Palette.dim))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .focused($focused)
            if search.active {
                Button { search.clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.dim) }.buttonStyle(.plain).help("清空")
            }
        }
        .fieldChrome(focused: focused)
        .onChange(of: search.focusRequest) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }
}

/// While nothing is typed, or the index is still being made: what is indexed, and what to type.
private struct FileIndexSummary: View {
    @ObservedObject var search: FileSearch
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch search.status.state {
            case .off, .loading:
                line(Text("正在读取索引…"), busy: true)
            case .scanning(let found):
                line(Text("正在建立索引，已找到 \(FileSearch.count(found)) 个文件和文件夹"), busy: true)
                if search.active { Text("建好后马上显示「\(search.query)」的结果").font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.leading, 4) }
            case .ready:
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    line(Text(summary(now: context.date)), busy: search.status.rebuilding)
                }
            }
            if search.preferences.fileSearchWholeDisk && !search.fullDiskAccess {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                    Text("整盘搜索需要「完全磁盘访问权限」，没有它，邮件、信息等受保护的位置搜不到")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    Spacer(minLength: 4)
                    PillButton(title: "去允许", style: .plain) { FileSearchSettings.openFullDiskAccess() }
                }
                .padding(.leading, 4)
            }
            HStack(spacing: 14) {
                KeyHint(keys: [.text("空格")], title: "多个词都要有")
                KeyHint(keys: [.text("/")], title: "按路径找，如 src/index")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }

    private func summary(now: Date) -> String {
        let status = search.status
        var parts = ["已索引 \(FileSearch.count(status.count)) 个文件和文件夹", "内存约 \(max(1, status.bytes / 1_000_000)) MB"]
        if status.rebuilding {
            parts.append("正在重新扫描")
        } else if let scanned = status.scanned {
            let when = now.timeIntervalSince(scanned) < 60 ? "刚刚" : Self.relative.localizedString(for: scanned, relativeTo: now)
            parts.append("\(when)完整扫描，之后实时更新")
        }
        return parts.joined(separator: " · ")
    }

    private func line(_ text: Text, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            text.font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
        .padding(.leading, 4)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// The matches: a filter by kind, the best of them, and the keys.
private struct FileSearchResults: View {
    @ObservedObject var search: FileSearch
    @ObservedObject var model: NotchModel
    static let rowHeight: CGFloat = 40

    var body: some View {
        let results = search.results
        VStack(alignment: .leading, spacing: 4) {
            let kinds = FileKind.allCases.filter { (results.counts[$0] ?? 0) > 0 }
            if kinds.count > 1 || search.kind != nil {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        chip("全部 \(FileSearch.count(results.counts.values.reduce(0, +)))", selected: search.kind == nil) { search.kind = nil }
                        ForEach(kinds, id: \.self) { kind in
                            chip("\(kind.title) \(FileSearch.count(results.counts[kind] ?? 0))", selected: search.kind == kind) {
                                search.kind = search.kind == kind ? nil : kind
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .padding(.top, 2)
            }
            if results.hits.isEmpty {
                Text(results.query.isEmpty ? "正在搜索…" : "没有找到名字里有「\(search.query)」的文件")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 10).padding(.leading, 4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(results.hits.enumerated()), id: \.element.id) { index, hit in
                                FileRow(hit: hit, words: words, selected: index == search.selection, search: search, model: model)
                                    .id(hit.id)
                            }
                            if results.total > results.hits.count {
                                Text("另有 \(FileSearch.count(results.total - results.hits.count)) 个，多打几个字缩小范围")
                                    .font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.leading, 8).padding(.vertical, 6)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(results.hits.count) * (Self.rowHeight + 1) + (results.total > results.hits.count ? 30 : 6), 7.5 * Self.rowHeight))
                    .onChange(of: search.selection) { _, selection in
                        if results.hits.indices.contains(selection) { proxy.scrollTo(results.hits[selection].id) }
                    }
                }
            }
            HStack(spacing: 14) {
                if let notice = search.notice {
                    Text(notice).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.ok)
                } else {
                    KeyHint(keys: [.returnKey], title: "打开")
                    KeyHint(keys: [.text("⌘"), .returnKey], title: "在访达中显示")
                    KeyHint(keys: [.text("⇧"), .text("⌘"), .text("C")], title: "复制路径")
                    KeyHint(keys: [.text("esc")], title: "清空")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    private var words: [String] {
        search.query.split(whereSeparator: \.isWhitespace).map { String($0.split(separator: "/").last ?? $0[...]) }.filter { !$0.isEmpty }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).foregroundStyle(selected ? Palette.ink : Palette.muted)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Palette.accent.opacity(0.25) : Palette.wash(0.06)))
                .overlay(Capsule().strokeBorder(selected ? Palette.accent.opacity(0.6) : Palette.wash(0.08), lineWidth: 0.75))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// A match: its icon, its name with what matched picked out, where it is; dragged, the file itself.
private struct FileRow: View {
    let hit: FileIndex.Hit
    let words: [String]
    let selected: Bool
    @ObservedObject var search: FileSearch
    @ObservedObject var model: NotchModel
    @State private var hovering = false
    @State private var modified: Date?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: Thumbnails.icon(for: URL(fileURLWithPath: hit.path)))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    Text(FileSearch.display(hit.folder)).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .overlay(DragSource(url: URL(fileURLWithPath: hit.path), onClick: open))
            if selected || hovering {
                button("folder", help: "在访达中显示（⌘ return）") { search.reveal(hit) }
                button("doc.on.doc", help: "复制路径（⇧⌘C）") { search.copyPath(hit) }
            } else if let modified {
                Text(Self.relative.localizedString(for: modified, relativeTo: Date())).font(.system(size: 10.5)).foregroundStyle(Palette.dim).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: FileSearchResults.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.accent.opacity(0.16) : hovering ? Palette.row : .clear))
        .onHover { hovering = $0 }
        .help(hit.path)
        .onAppear {
            modified = (try? FileManager.default.attributesOfItem(atPath: hit.path))?[.modificationDate] as? Date
        }
        .contextMenu {
            Button(hit.kind == .app ? "打开应用" : "打开", action: open)
            Button("在访达中显示") { search.reveal(hit) }
            SendToAgentMenu { .files([URL(fileURLWithPath: hit.path)]) }
            Divider()
            Button("复制路径") { search.copyPath(hit) }
            Button("复制文件") { search.copyFile(hit) }
            Button("复制名称") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.name, forType: .string)
                search.say("已复制名称")
            }
        }
    }

    private func open() {
        if search.open(hit) { model.collapse() }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The name, each word typed picked out where it first appears.
    private var name: AttributedString {
        var text = AttributedString(hit.name)
        for word in words {
            guard let range = text.range(of: word, options: [.caseInsensitive]) else { continue }
            text[range].foregroundColor = Palette.ink
            text[range].backgroundColor = Color(red: 1, green: 0.8, blue: 0).opacity(0.28)
        }
        return text
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}

enum FileSearchSettings {
    @MainActor
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
