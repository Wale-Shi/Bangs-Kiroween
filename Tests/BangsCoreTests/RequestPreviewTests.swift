import XCTest
@testable import BangsCore

final class RequestPreviewTests: XCTestCase {
    private let cwd = "/Users/me/code/app", home = "/Users/me"

    private func changes(_ input: Any, files: [String: String] = [:]) -> [FileChange] {
        RequestPreview.changes(RequestPreview.edits(in: input), cwd: cwd, home: home) { path in
            files[path].map(RequestPreview.FileState.text) ?? .missing
        }
    }

    /// Claude Code's Edit: the old and new text, numbered from where the old text is in the file.
    func testEditIsADiffAtItsLine() {
        let file = "import SwiftUI\n\nstruct A {\n    let x = 1\n    let y = 2\n}\n"
        let input: [String: Any] = ["file_path": "\(cwd)/Sources/A.swift", "old_string": "    let x = 1\n    let y = 2", "new_string": "    let x = 10\n    let y = 2\n    let z = 3"]
        let change = try! XCTUnwrap(changes(input, files: ["\(cwd)/Sources/A.swift": file]).first)
        XCTAssertEqual(change.path, "Sources/A.swift")
        XCTAssertEqual(change.kind, .edit)
        XCTAssertEqual(change.firstLine, 4)
        XCTAssertEqual(change.lines, [
            .init(.removed, "    let x = 1"),
            .init(.added, "    let x = 10", 4),
            .init(.context, "    let y = 2", 5),
            .init(.added, "    let z = 3", 6),
        ])
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
    }

    /// Without the file (moved, unreadable) the diff still shows, without numbers.
    func testEditWithoutTheFileHasNoNumbers() {
        let change = changes(["path": "a.txt", "old_str": "one", "new_str": "two"]).first
        XCTAssertEqual(change?.lines, [.init(.removed, "one"), .init(.added, "two")])
        XCTAssertNil(change?.firstLine)
    }

    func testMultiEditJoinsItsHunksWithGaps() {
        let input: [String: Any] = ["file_path": "a.swift", "edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d"]]]
        XCTAssertEqual(changes(input).first?.lines.map(\.kind), [.removed, .added, .gap, .removed, .added])
    }

    func testWritingANewFile() {
        let change = changes(["file_path": "\(cwd)/new.swift", "content": "let a = 1\nlet b = 2\n"]).first
        XCTAssertEqual(change?.kind, .create)
        XCTAssertEqual(change?.lines, [.init(.added, "let a = 1", 1), .init(.added, "let b = 2", 2)])
    }

    /// A whole-file write over an existing file shows only what differs, with the stretches between cut to a gap.
    func testOverwritingKeepsOnlyNearbyContext() {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[1] = "line two"
        new[17] = "line eighteen"
        let change = changes(["file_path": "notes.txt", "content": new.joined(separator: "\n")], files: ["\(cwd)/notes.txt": old.joined(separator: "\n")]).first
        XCTAssertEqual(change?.kind, .overwrite)
        XCTAssertEqual(change?.lines.map(\.kind), [.context, .removed, .added, .context, .context, .gap, .context, .context, .removed, .added, .context, .context])
        XCTAssertEqual(change?.lines.first?.number, 1)
        XCTAssertEqual(change?.added, 2)
    }

    func testCodexPatch() {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/App.swift
        @@ func run() {
             let a = 1
        -    let b = 2
        +    let b = 3
        *** Add File: Tests/AppTests.swift
        +import XCTest
        +
        *** Delete File: Old.swift
        *** Update File: Sources/Name.swift
        *** Move to: Sources/NewName.swift
        @@
        -old
        +new
        *** End Patch
        """
        let all = changes(["command": ["apply_patch", patch]])
        XCTAssertEqual(all.map(\.path), ["Sources/App.swift", "Tests/AppTests.swift", "Old.swift", "Sources/Name.swift"])
        XCTAssertEqual(all.map(\.kind), [.edit, .create, .delete, .move(to: "Sources/NewName.swift")])
        XCTAssertEqual(all[0].lines, [.init(.context, "    let a = 1"), .init(.removed, "    let b = 2"), .init(.added, "    let b = 3")])
        XCTAssertEqual(all[1].lines, [.init(.added, "import XCTest", 1), .init(.added, "", 2)])
        XCTAssertEqual(RequestPreview.paths(of: RequestPreview.edits(in: ["input": patch])),
                       ["Sources/App.swift", "Tests/AppTests.swift", "Old.swift", "Sources/Name.swift", "Sources/NewName.swift"])
    }

    func testPathsOutsideTheFolderKeepTheHome() {
        XCTAssertEqual(changes(["file_path": "~/.zshrc", "old_string": "a", "new_string": "b"]).first?.path, "~/.zshrc")
        XCTAssertEqual(changes(["file_path": "/etc/hosts", "content": "x"]).first?.path, "/etc/hosts")
    }

    func testCommands() {
        XCTAssertEqual(RequestPreview.command(in: ["command": "swift test"]), "swift test")
        XCTAssertEqual(RequestPreview.command(in: ["command": ["bash", "-lc", "git push -f"]]), "git push -f")
        XCTAssertEqual(RequestPreview.command(in: ["command": ["git", "commit", "-m", "two words"]]), "git commit -m 'two words'")
        XCTAssertNil(RequestPreview.command(in: ["file_path": "a"]))
    }

    /// Reads that are not edits have no preview.
    func testOtherToolsHaveNone() {
        XCTAssertTrue(RequestPreview.edits(in: ["file_path": "a.swift"]).isEmpty)
        XCTAssertTrue(RequestPreview.edits(in: ["command": "ls"]).isEmpty)
        XCTAssertTrue(RequestPreview.edits(in: nil).isEmpty)
    }

    func testHugeChangesAreCountedNotShown() {
        let old = (0..<3000).map { "a\($0)" }.joined(separator: "\n"), new = (0..<3000).map { "b\($0)" }.joined(separator: "\n")
        let change = changes(["file_path": "big.txt", "content": new], files: ["\(cwd)/big.txt": old]).first
        XCTAssertEqual(change?.lines, [])
        XCTAssertEqual(change?.added, 3000)
        XCTAssertEqual(change?.removed, 3000)
    }
}
