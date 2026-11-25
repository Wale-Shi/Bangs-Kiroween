import AppKit
import ScreenCaptureKit
import SwiftUI

/// Screenshots of a region, a window, or a scrolling page, all taken by Bangs through ScreenCaptureKit.
/// Each one lands on the pasteboard and in the clipboard history, with a preview in the island.
@MainActor
final class Screenshots {
    let directory = Storage.directory("Screenshots")
    var onCaptured: (URL) -> Void = { _ in }
    /// Text read off a region: what was read, possibly nothing.
    var onRecognized: (String) -> Void = { _ in }
    /// A table read off a region, with its text as plain lines too.
    var onTable: (RecognizedTable, String) -> Void = { _, _ in }
    var onFailed: (String) -> Void = { _ in }
    /// Screen Recording is off: without it macOS hands over only the wallpaper, so nothing is captured.
    var onNeedsPermission: () -> Void = {}
    /// The capture in progress: one at a time. Asked for another while one is up, it is cancelled instead.
    private var current: ScreenCapture?

    /// Whether to start a capture: no while one is up, which is cancelled instead.
    private func ready() -> Bool {
        if let current {
            current.cancel()
            self.current = nil
            return false
        }
        return permitted()
    }
    /// Screen Recording granted while Bangs runs already passes the check, but captures stay blank (or only the wallpaper)
    /// until Bangs is opened again.
    private let grantedAtLaunch = Screenshots.hasPermission
    /// Captures kept anyway: the ones on the shelf.
    var keeps: (URL) -> Bool = { _ in false }
    /// How long a capture stays in Bangs' folder. The clipboard history keeps its own copy, by its own rules, and a copy
    /// saved to the Desktop or Downloads is yours.
    static let retention: TimeInterval = 7 * 86_400

    /// Older captures go, except those still on the shelf.
    func prune() {
        let now = Date()
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > Self.retention, !keeps(url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func output(_ prefix: String) -> URL { Storage.unique(Storage.stamp(prefix), in: directory) }

    /// `annotates`: the region is annotated in place before it is copied.
    func region(annotates: Bool = false) {
        guard ready() else { return }
        let capture = RegionCapture(output: output("截屏"), annotates: annotates)
        capture.onFinish = { [weak self] url, error in self?.done(url, error) }
        current = capture
        capture.start()
    }

    func window() {
        guard ready() else { return }
        let capture = WindowCapture(output: output("截屏"))
        capture.onFinish = { [weak self] url, error in self?.done(url, error) }
        current = capture
        capture.start()
    }

    /// Drag out a region and its text is read, on this Mac; the image itself is not kept.
    /// `tables`: a region that holds a table comes back as one, to paste into a spreadsheet.
    func text(language: TextRecognition.Language, joinLines: Bool, tables: Bool = true) {
        guard ready() else { return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-ocr-\(UUID().uuidString).png")
        let capture = RegionCapture(output: output, hint: "框选要识别文字的区域 · esc 取消")
        capture.onFinish = { [weak self] url, error in
            self?.current = nil
            guard let url else { if let error { self?.onFailed(error) }; return }
            Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: url) }
                guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                do {
                    let text = try await TextRecognition.recognize(image, language: language, joinLines: joinLines)
                    if tables, let table = await TableRecognition.recognize(image, language: language) {
                        Log.write("ocr: table \(table.rowCount)×\(table.columnCount)")
                        return self?.onTable(table, text) ?? ()
                    }
                    self?.onRecognized(text)
                } catch {
                    Log.write("ocr: failed: \(error)")
                    self?.onFailed("识别失败：\(error.localizedDescription)")
                }
            }
        }
        current = capture
        capture.start()
    }

    private func permitted() -> Bool {
        Log.write("screenshot: screen recording preflight = \(Self.hasPermission), at launch = \(grantedAtLaunch), bundle = \(Bundle.main.bundlePath)")
        if Self.hasPermission && grantedAtLaunch { return true }
        if !Self.hasPermission { CGRequestScreenCaptureAccess() }
        onNeedsPermission()
        return false
    }

    func scrolling(lockKey: HoldKey = .space) {
        guard ready() else { return }
        let capture = ScrollCapture(output: output("滚动截图"), lockKey: lockKey)
        capture.onFinish = { [weak self] url, error in self?.done(url, error) }
        current = capture
        capture.start()
    }

    /// A screenshot already taken, annotated in its own window; the result is a new screenshot, copied like any other.
    func annotate(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return onFailed("无法打开这张截图") }
        // Captures are at the screen's resolution; show them at their size in points.
        let window = AnnotationWindow(image: image, scale: NSScreen.main?.backingScaleFactor ?? 2, title: "标注 · \(url.lastPathComponent)")
        window.onDone = { [weak self] image in
            guard let self else { return }
            let output = self.output("截屏")
            Capture.save(image, to: output) ? self.done(output, nil) : self.done(nil, "无法保存截图")
        }
        window.show()
    }

    /// Esc leaves neither a file nor an error.
    private func done(_ url: URL?, _ error: String?) {
        current = nil
        if let url { onCaptured(url) } else if let error { onFailed(error) }
        prune()
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
}

struct ScreenshotView: View {
    let shoot: (ShortcutAction) -> Void
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                option(.shotRegion, "crop", "选区", "拖一块区域")
                option(.shotWindow, "macwindow", "窗口", "点选一个窗口")
                option(.shotScroll, "arrow.up.and.down.text.horizontal", "滚动截图", "框选后滚动页面")
                option(.shotText, "text.viewfinder", "识字", "框选后复制文字")
            }
            Text("截图和识别出的文字都会复制到剪贴板并进入剪贴板历史。快捷键在设置里录制。")
                .font(.system(size: 10.5)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ action: ShortcutAction, _ symbol: String, _ title: String, _ detail: String) -> some View {
        ShotButton(symbol: symbol, title: title, detail: preferences.shortcuts[action]?.display ?? detail) { shoot(action) }
    }
}

private struct ShotButton: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Palette.ink)
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.wash(hovering ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The island after a screenshot: a preview to drag anywhere, and where to put it.
struct CapturedView: View {
    let url: URL
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: Thumbnails.image(at: url, points: 120) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 120, maxHeight: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(DragSource(url: url))
                .help("拖到任何地方")
            VStack(alignment: .leading, spacing: 8) {
                Text("已复制到剪贴板").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text([url.lastPathComponent, Self.size(of: url)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    PillButton(title: "标注", style: .plain) {
                        model.go(.collapsed)
                        model.toolbox.screenshots.annotate(url)
                    }
                    // Saved already (Settings › 截图与识字 › 同时保存到): show it rather than save it twice.
                    if let copy = model.savedCopies[url] {
                        PillButton(title: "在访达中显示", style: .plain) {
                            NSWorkspace.shared.activateFileViewerSelecting([copy])
                            model.go(.collapsed)
                        }
                    } else {
                        PillButton(title: "存到桌面", style: .plain) {
                            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                            try? FileManager.default.copyItem(at: url, to: Storage.unique(url.lastPathComponent, in: desktop))
                            model.go(.collapsed)
                        }
                    }
                    PillButton(title: "放进中转站", style: .plain) {
                        model.toolbox.shelf.add([url])
                        model.go(.collapsed)
                    }
                    SendToAgentButton { .files([url]) }
                    PillButton(title: "打开", style: .primary) {
                        NSWorkspace.shared.open(url)
                        model.go(.collapsed)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "1600×3990" in pixels.
    static func size(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width)×\(height)"
    }
}

/// Screenshots without Screen Recording would capture only the wallpaper, so the island says how to turn it on.
struct ScreenPermissionView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        // Granted since Bangs started: it only needs opening again.
        let granted = Screenshots.hasPermission
        VStack(alignment: .leading, spacing: 0) {
            Text(granted ? "权限已打开，重启 Bangs 后生效" : "截图需要「屏幕录制」权限").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(granted ? "macOS 要等 Bangs 重新打开后，才真正允许它录制屏幕；在这之前截出来是空白的。"
                         : "在系统设置里打开 Bangs 的开关后重启 Bangs。如果开关已经是开的，先关掉再打开：Bangs 每次更新后，系统会把它当成新的 App。")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            HStack(spacing: 6) {
                Spacer()
                if !granted {
                    PillButton(title: "打开系统设置", style: .plain) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                PillButton(title: "重启 Bangs", style: .warn) { Relaunch.now() }
            }
            .padding(.top, 12)
        }
    }
}

/// Quits and opens Bangs again, which macOS needs before a newly granted Screen Recording permission applies.
enum Relaunch {
    static func now() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// The island after reading text off the screen: the text, already copied, to correct and copy again.
struct RecognizedView: View {
    @ObservedObject var model: NotchModel
    @State private var text: String
    @State private var copied = false
    @FocusState private var editing: Bool
    private let original: String

    init(text: String, model: NotchModel) {
        self.model = model
        original = text
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if original.isEmpty {
                Text("没有识别出文字").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("换一块更清楚的区域，或在设置里换一种识别语言。").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 6)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(copied ? "已复制改好的文字" : "已复制识别出的文字").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(text.count) 字 · 可以直接改").font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
                    .padding(6)
                    .frame(height: min(150, max(48, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 18 + 16)))
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash(0.07)))
                    .padding(.top, 8)
                HStack(spacing: 6) {
                    Spacer()
                    if model.preferences.ocrOpensLinks, let link = TextRecognition.link(in: text) {
                        PillButton(title: "打开链接", style: .plain) {
                            NSWorkspace.shared.open(link)
                            model.go(.collapsed)
                        }
                    }
                    PillButton(title: "翻译", style: .plain) { model.translate(text, from: "截图识字") }
                    SendToAgentButton { .text(text) }
                    PillButton(title: "完成", style: .plain) { model.go(.collapsed) }
                    PillButton(title: "复制", style: .primary) {
                        model.toolbox.clipboard.copy(text, app: "截图识字")
                        model.go(.collapsed)
                    }
                }
                .padding(.top, 12)
            }
        }
        .onChange(of: text) { _, _ in copied = false }
    }
}

/// The island after reading a table: how big it is, a look at it, and the way back to plain text.
struct TableView: View {
    let table: RecognizedTable
    let text: String
    @ObservedObject var model: NotchModel
    @State private var asText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(asText ? "已改为复制纯文本" : "识别到表格，已按表格复制").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(table.rowCount) 行 × \(table.columnCount) 列").font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            Text(asText ? "粘贴得到一行一行的文字。" : "粘贴到 Excel、Numbers、WPS 或飞书表格，会按单元格分开。")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).padding(.top, 4)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.grid.prefix(Self.rowsShown).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell.isEmpty ? " " : cell)
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 36, maxWidth: 180, alignment: .leading)
                                    .border(Palette.wash(0.12), width: 0.5)
                            }
                        }
                    }
                }
            }
            .frame(height: min(176, CGFloat(min(table.rowCount, Self.rowsShown)) * 23 + 4))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 10)
            if table.rowCount > Self.rowsShown {
                Text("还有 \(table.rowCount - Self.rowsShown) 行，已一并复制").font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.top, 5)
            }
            HStack(spacing: 6) {
                Spacer()
                PillButton(title: asText ? "改回表格" : "改为纯文本复制", style: .plain) {
                    if asText { model.copy(table) } else { model.toolbox.clipboard.copy(text, app: "截图识字") }
                    asText.toggle()
                }
                PillButton(title: "完成", style: .primary) { model.go(.collapsed) }
            }
            .padding(.top, 12)
        }
    }

    private static let rowsShown = 30
}
