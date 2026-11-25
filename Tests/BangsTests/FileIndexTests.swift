import XCTest
@testable import Bangs

final class FileIndexTests: XCTestCase {
    private var root: URL!
    private var indexes: [FileIndex] = []

    private func make(_ file: URL? = nil) -> FileIndex {
        let index = FileIndex(file: file)
        indexes.append(index)
        return index
    }

    override func setUpWithError() throws {
        TestData.isolate
        // Resolved, as FSEvents reports it (/var is /private/var).
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bangs-files-\(UUID().uuidString)").resolvingSymlinksInPath()
        for folder in ["Projects/app/src", "Projects/app/node_modules/left-pad", "Projects/Tool.app/Contents/MacOS", "Notes", ".config"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Projects/app/src/main.swift", "Projects/app/src/MainView.swift", "Projects/app/README.md", "Projects/app/node_modules/left-pad/index.js",
                     "Projects/Tool.app/Contents/MacOS/Tool", "Notes/Quarterly Report.pdf", "Notes/report-draft.txt", "Notes/Résumé.pages.txt", ".config/settings.json"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
        root = URL(fileURLWithPath: FileIndex.canonical(root.path))
    }

    override func tearDownWithError() throws {
        for index in indexes { index.stopWatching() }
        indexes = []
        try? FileManager.default.removeItem(at: root)
    }

    private var scope: FileIndex.Scope {
        FileIndex.Scope(roots: [root.path], skipPaths: [], skipNames: Set(FileIndex.defaultExclusions.map { $0.lowercased() }))
    }

    private func ready(_ index: FileIndex, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !index.settled, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(index.settled)
    }

    /// Waits for FSEvents to bring a change in.
    private func eventually(_ index: FileIndex, _ query: String, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while index.searchNow(query).total != count, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(index.searchNow(query).total, count, query, file: file, line: line)
    }

    private func names(_ results: FileIndex.Results) -> [String] { results.hits.map(\.name) }

    func testFindsNamesAndLeavesOutDependenciesAndPackageInsides() {
        let index = make()
        index.start(scope)
        ready(index)
        XCTAssertEqual(names(index.searchNow("main")), ["main.swift", "MainView.swift"], "the whole stem first")
        XCTAssertEqual(index.searchNow("node_modules").hits.first?.name, "node_modules", "an excluded folder is still found")
        XCTAssertEqual(index.searchNow("left-pad").total, 0, "but not what is in it")
        XCTAssertEqual(names(index.searchNow("tool")), ["Tool.app"], "an app, not its insides")
        XCTAssertEqual(index.searchNow("tool").hits.first?.kind, .app)
        XCTAssertEqual(names(index.searchNow("REPORT")), ["report-draft.txt", "Quarterly Report.pdf"], "any case; the name's start first")
        XCTAssertEqual(names(index.searchNow("quar rep")), ["Quarterly Report.pdf"], "every word, any order")
        XCTAssertEqual(names(index.searchNow("rep quar")), ["Quarterly Report.pdf"])
        XCTAssertEqual(names(index.searchNow("résumé")), ["Résumé.pages.txt"], "accents, composed or not")
        XCTAssertEqual(names(index.searchNow("re\u{301}sume\u{301}")), ["Résumé.pages.txt"])
        XCTAssertEqual(names(index.searchNow("src/main")), ["main.swift", "MainView.swift"], "a slash matches the path")
        XCTAssertEqual(index.searchNow("settings").hits.first?.folder, root.path + "/.config")
        XCTAssertEqual(index.searchNow("swift", kind: .code).total, 2)
        XCTAssertEqual(index.searchNow("swift").counts[.code], 2)
        XCTAssertEqual(index.searchNow("re", kind: .document).hits.map(\.name).sorted(), ["Quarterly Report.pdf", "README.md", "report-draft.txt"], "ré is not re")
        XCTAssertEqual(index.searchNow("").total, 0)
    }

    func testFollowsChangesOnDisk() throws {
        let index = make()
        index.start(scope)
        ready(index)
        try Data().write(to: root.appendingPathComponent("Notes/new-idea.md"))
        eventually(index, "new-idea", count: 1)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes/Trip/Photos"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Notes/Trip/Photos/beach.heic"))
        eventually(index, "beach", count: 1)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Notes/Trip"), to: root.appendingPathComponent("Projects/Holiday"))
        eventually(index, "holiday/photos/beach", count: 1)
        eventually(index, "trip", count: 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Projects/Holiday"))
        eventually(index, "beach", count: 0)
        try Data().write(to: root.appendingPathComponent("Projects/app/node_modules/left-pad/more.js"))
        try Data().write(to: root.appendingPathComponent("Notes/marker.txt"))
        eventually(index, "marker", count: 1)
        XCTAssertEqual(index.searchNow("more.js").total, 0, "changes inside an excluded folder are ignored")
    }

    func testSavedIndexIsUsedAndCatchesUpOnChanges() throws {
        let file = root.deletingLastPathComponent().appendingPathComponent("index-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = make(file)
        first.start(scope)
        ready(first)
        let count = first.entryCount
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        first.stopWatching()
        try Data().write(to: root.appendingPathComponent("Notes/while-away.txt"))

        let second = make(file)
        second.start(scope)
        ready(second, timeout: 1)
        XCTAssertGreaterThanOrEqual(second.entryCount, count)
        XCTAssertEqual(names(second.searchNow("quarterly")), ["Quarterly Report.pdf"])
        eventually(second, "while-away", count: 1)

        // Another scope does not use it.
        let third = make(file)
        third.start(FileIndex.Scope(roots: [root.path + "/Notes"], skipPaths: [], skipNames: []))
        ready(third)
        XCTAssertEqual(third.searchNow("main").total, 0)
    }

    /// A damaged index file costs a walk, not a crash (or a hang) on every launch.
    func testDamagedSavedIndexIsRebuilt() throws {
        let file = root.deletingLastPathComponent().appendingPathComponent("index-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = make(file)
        first.start(scope)
        ready(first)
        let count = first.entryCount
        first.stopWatching()
        let good = try Data(contentsOf: file)

        // The layout `save()` writes: a fixed header, the volume, the roots, then the entries.
        func load<T>(_ offset: Int, as: T.Type) -> T { good.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) } }
        func patched<T>(_ offset: Int, _ value: T) -> Data {
            var data = good
            withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
            return data
        }
        let countOffset = 32, volume = Int(load(56, as: UInt32.self)), rootCount = Int(load(60 + volume, as: UInt32.self))
        let entries = 64 + volume + 4 * rootCount, stride = MemoryLayout<FileIndex.Entry>.stride
        let stored = Int(load(countOffset, as: UInt64.self))
        XCTAssertEqual(entries + stored * stride + 2 * Int(load(countOffset + 8, as: UInt64.self)), good.count, "the layout is as read here")
        let last = entries + (stored - 1) * stride
        let damaged: [(String, Data)] = [
            ("truncated", good.prefix(good.count - 7)),
            ("header only", good.prefix(entries)),
            ("count overflows", patched(countOffset, UInt64.max / 4)),
            ("count one more", patched(countOffset, UInt64(stored + 1))),
            ("arena overflows", patched(countOffset + 8, UInt64.max)),
            ("deleted past count", patched(countOffset + 16, UInt64(stored + 1))),
            ("root out of range", patched(64 + volume, Int32(stored))),
            ("parent out of range", patched(last, Int32.max)),
            ("parent is itself", patched(last, Int32(stored - 1))),
            ("next loops", patched(last + 8, Int32(stored - 1))),
            ("first child out of range", patched(entries + 4, Int32(stored))),
            ("name past the arena", patched(last + 12, UInt32.max)),
        ]
        for (label, data) in damaged {
            try data.write(to: file)
            let index = make(file)
            index.start(scope)
            ready(index)
            XCTAssertEqual(index.entryCount, count, label)
            XCTAssertEqual(names(index.searchNow("quarterly")), ["Quarterly Report.pdf"], label)
            index.stopWatching()
        }
    }

    func testANewScopeWhileWalkingIsWalkedToo() {
        let index = make()
        index.start(scope)
        index.start(FileIndex.Scope(roots: [root.path + "/Notes"], skipPaths: [], skipNames: []))
        ready(index)
        XCTAssertEqual(index.searchNow("main").total, 0)
        XCTAssertEqual(names(index.searchNow("quarterly")), ["Quarterly Report.pdf"])
    }

    func testStopForgetsTheIndex() {
        let file = root.deletingLastPathComponent().appendingPathComponent("index-\(UUID().uuidString).bin")
        let index = make(file)
        index.start(scope)
        ready(index)
        index.stop()
        XCTAssertFalse(index.settled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLargestKeepsTheTopInOrder() {
        let keys = (0..<10_000).map { _ in Int64.random(in: -1_000_000...1_000_000) }
        XCTAssertEqual(Array(FileIndex.largest(keys, 50)), Array(keys.sorted(by: >).prefix(50)))
    }

    /// Measures the real home folder, leaving out the folders macOS asks about. BANGS_BENCH=1 to run.
    func testBenchmarkHome() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANGS_BENCH"] == "1")
        let home = NSHomeDirectory()
        var scope = FileIndex.Scope.make(wholeDisk: false, exclusions: FileIndex.defaultExclusions)
        scope.roots.removeAll { $0.contains("Mobile Documents") }
        for folder in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] { scope.skipPaths.insert(home + "/" + folder) }
        let started = Date()
        let index = make()
        index.start(scope)
        ready(index, timeout: 120)
        print("BENCH entries=\(index.entryCount) walk=\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        for query in ["a", "swift", "readme", "bangs", "main.swift", "src/index", "no-such-file-anywhere"] {
            _ = index.searchNow(query)
            let results = index.searchNow(query)
            print("BENCH search '\(query)' total=\(results.total) \(String(format: "%.1f", results.milliseconds)) ms first=\(results.hits.first?.path ?? "-")")
        }
    }
}

@MainActor
final class EditKeysTests: XCTestCase {
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testEditShortcutsByKeyCode() {
        XCTAssertEqual(NotchPanel.editAction(key(8, "c", .command)), #selector(NSText.copy(_:)))
        XCTAssertEqual(NotchPanel.editAction(key(9, "м", .command)), #selector(NSText.paste(_:)), "any layout")
        XCTAssertEqual(NotchPanel.editAction(key(6, "Z", [.command, .shift])), Selector(("redo:")))
        XCTAssertNil(NotchPanel.editAction(key(8, "C", [.command, .shift])), "⇧⌘C is the files tab's")
        XCTAssertNil(NotchPanel.editAction(key(8, "c", [])))
    }

    func testSelectAllReachesTheFieldInThePanel() {
        let panel = NotchPanel()
        panel.setFrame(NSRect(x: 0, y: 0, width: 300, height: 100), display: false)
        let field = NSTextField(string: "node_modules")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        panel.contentView?.addSubview(field)
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = field.currentEditor() as? NSTextView
        editor?.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: key(0, "a", .command)))
        XCTAssertEqual(editor?.selectedRange(), NSRange(location: 0, length: 12))
        panel.orderOut(nil)

        // Without it (and with no Edit menu to answer), a panel lets the shortcut go: the bug this fixes.
        let plain = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let other = NSTextField(string: "abc")
        plain.contentView?.addSubview(other)
        plain.orderFrontRegardless()
        plain.makeFirstResponder(other)
        XCTAssertFalse(plain.performKeyEquivalent(with: key(0, "a", .command)))
        plain.orderOut(nil)
    }
}

@MainActor
final class ClipboardImageTests: XCTestCase {
    override class func setUp() { TestData.isolate }

    private func image(_ width: Int, _ height: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func waitForFile(_ url: URL) -> Data? {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return try? Data(contentsOf: url)
    }

    func testCopiedImagesKeepTheirSizeAndBecomePNGOffTheMainThread() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bangs-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(preferences: Preferences(), pasteboard: pasteboard)

        let png = try XCTUnwrap(image(300, 200).representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        history.poll()
        let first = try XCTUnwrap(history.items.first)
        XCTAssertEqual(first.kind, .image)
        XCTAssertEqual(first.size, [300, 200])
        XCTAssertEqual(waitForFile(history.images.appendingPathComponent(first.image!)), png, "a PNG is kept byte for byte")

        let tiff = try XCTUnwrap(image(120, 80).tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        history.poll()
        let second = try XCTUnwrap(history.items.first)
        XCTAssertEqual(second.size, [120, 80])
        let stored = try XCTUnwrap(waitForFile(history.images.appendingPathComponent(second.image!)))
        XCTAssertEqual(Array(stored.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "anything else is stored as PNG")
        XCTAssertEqual(NSBitmapImageRep(data: stored)?.pixelsWide, 120)
    }
}
