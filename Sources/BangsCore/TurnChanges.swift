import Foundation

/// What a turn changed in its project's git checkout: the files written while it ran, and how many lines each gained and
/// lost since the turn began. Read only: git runs with optional locks off, so it never takes the index lock an agent's
/// own git commands may need, and nothing is written to the repository.
public struct TurnChanges: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var path: String
        /// Nil for a binary file.
        public var added: Int?
        public var removed: Int?
        /// Not tracked by git (new since the turn began).
        public var untracked: Bool

        public init(path: String, added: Int?, removed: Int?, untracked: Bool = false) {
            self.path = path
            self.added = added
            self.removed = removed
            self.untracked = untracked
        }
    }

    public var files: [File]
    /// Commits made during the turn.
    public var commits: Int
    /// The commit the turn began on, which diffs are taken against.
    public var base: String
    public var folder: String

    public init(files: [File], commits: Int, base: String, folder: String) {
        self.files = files
        self.commits = commits
        self.base = base
        self.folder = folder
    }

    public var added: Int { files.compactMap(\.added).reduce(0, +) }
    public var removed: Int { files.compactMap(\.removed).reduce(0, +) }
    public var isEmpty: Bool { files.isEmpty && commits == 0 }

    /// "+142 −37 · 6 个文件".
    public var summary: String {
        var parts: [String] = []
        if !files.isEmpty {
            parts.append("+\(added) −\(removed)")
            parts.append("\(files.count) 个文件")
        }
        if commits > 0 { parts.append("\(commits) 次提交") }
        return parts.joined(separator: " · ")
    }
}

/// Where a turn began: the commit checked out, and the files already changed or untracked then, each with when it was
/// last written, so that only files written during the turn count as its own.
public struct TurnStart: Sendable {
    public var folder: String
    public var head: String
    var stamps: [String: Stamp]

    struct Stamp: Equatable { var modified: Date?; var size: Int? }
}

public enum Git {
    /// A Mac without the developer tools has only the stub at /usr/bin/git, which offers to install them in a dialog:
    /// git runs only where the tools are present.
    public static let available: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let folder = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: folder + "/usr/bin/git")
            || FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    }()

    /// Changed or untracked files beyond this are not looked at one by one.
    static let maxFiles = 3000
    /// Output beyond this is cut (a diff of one file is shown in part anyway).
    static let maxOutput = 4 << 20

    /// Runs git in `folder` and returns what it printed, or nil when it failed or took longer than `timeout`.
    public static func run(_ arguments: [String], in folder: String, timeout: TimeInterval = 5) -> String? {
        guard available, !folder.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder, "-c", "core.quotepath=off", "--no-pager"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count < maxOutput { data.append(chunk.prefix(maxOutput - data.count)) }
        }
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The repository's top folder, when `folder` is in one.
    public static func root(of folder: String) -> String? {
        run(["rev-parse", "--show-toplevel"], in: folder).map { $0.trimmingCharacters(in: .newlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Turns

    /// Notes where a turn begins. Nil outside a git checkout, or in one with no commit yet.
    public static func start(in folder: String, home: String = NSHomeDirectory()) -> TurnStart? {
        // A home folder kept in git (dotfiles) would have every file under it listed on every turn.
        guard let root = root(of: folder), root != home,
              let head = run(["rev-parse", "--verify", "HEAD"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        let paths = Array((changed(since: head, in: root).map(\.path) + untracked(in: root)).prefix(maxFiles))
        return TurnStart(folder: root, head: head, stamps: Dictionary(paths.map { ($0, stamp(of: $0, in: root)) }) { first, _ in first })
    }

    /// The files written since the turn began, against the commit it began on (so commits made during it still count).
    public static func changes(since start: TurnStart) -> TurnChanges? {
        let root = start.folder
        guard let head = run(["rev-parse", "--verify", "HEAD"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // Touched during the turn: not changed when it began, or written since.
        func touched(_ path: String) -> Bool { start.stamps[path].map { $0 != stamp(of: path, in: root) } ?? true }
        var files = changed(since: start.head, in: root).filter { touched($0.path) }
        for path in untracked(in: root).prefix(maxFiles) where touched(path) {
            files.append(TurnChanges.File(path: path, added: lineCount(of: path, in: root), removed: 0, untracked: true))
        }
        let commits = head == start.head ? 0 : Int(run(["rev-list", "--count", "\(start.head)..\(head)"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        return TurnChanges(files: files.sorted { $0.path < $1.path }, commits: commits, base: start.head, folder: root)
    }

    /// One file's diff since the turn began, to show.
    public static func diff(of file: TurnChanges.File, in changes: TurnChanges) -> FileChange? {
        if file.untracked {
            let url = URL(fileURLWithPath: changes.folder).appendingPathComponent(file.path)
            guard case .text(let content) = RequestPreview.read(url.path) else {
                return FileChange(path: file.path, kind: .create, lines: [], added: file.added ?? 0, removed: 0)
            }
            return RequestPreview.changes([.write(path: url.path, content: content)], cwd: changes.folder) { _ in .missing }.first
        }
        guard let text = run(["diff", "--no-ext-diff", "--no-color", "--no-renames", "-U2", changes.base, "--", file.path], in: changes.folder) else { return nil }
        return unified(text).first
    }

    /// Files whose content differs from `commit` (committed since, staged or not).
    static func changed(since commit: String, in root: String) -> [TurnChanges.File] {
        guard let output = run(["diff", "--numstat", "--no-renames", "-z", commit], in: root) else { return [] }
        return output.split(separator: "\0").compactMap { entry in
            let fields = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return TurnChanges.File(path: String(fields[2]), added: Int(fields[0]), removed: Int(fields[1]))
        }
    }

    static func untracked(in root: String) -> [String] {
        run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)?.split(separator: "\0").map(String.init) ?? []
    }

    static func stamp(of path: String, in root: String) -> TurnStart.Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: (root as NSString).appendingPathComponent(path))
        return TurnStart.Stamp(modified: attributes?[.modificationDate] as? Date, size: (attributes?[.size] as? NSNumber)?.intValue)
    }

    /// Lines in a new text file; nil for a binary or very large one.
    static func lineCount(of path: String, in root: String) -> Int? {
        guard case .text(let content) = RequestPreview.read((root as NSString).appendingPathComponent(path)) else { return nil }
        return RequestPreview.split(content).count
    }

    // MARK: Unified diffs

    /// The files of a unified diff (`git diff`), with their changed lines and the context git kept.
    public static func unified(_ text: String) -> [FileChange] {
        var changes: [FileChange] = []
        var current: FileChange?
        var newLine = 0, added = 0, removed = 0, binary = false
        func finish() {
            guard var change = current else { return }
            change.added = added
            change.removed = removed
            if binary || change.lines.count > RequestPreview.maxLines { change.lines = [] }
            changes.append(change)
            current = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finish()
                added = 0; removed = 0; binary = false
                // "diff --git a/path b/path": the "+++" line names it more surely, but a file only added or removed, or a
                // binary one, may not have one.
                let path = line.dropFirst("diff --git a/".count).components(separatedBy: " b/").first ?? ""
                current = FileChange(path: path, kind: .edit, lines: [])
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("new file mode") { current?.kind = .create; continue }
            if line.hasPrefix("deleted file mode") { current?.kind = .delete; continue }
            if line.hasPrefix("Binary files") { binary = true; continue }
            if line.hasPrefix("+++ ") {
                if line != "+++ /dev/null" { current?.path = String(line.dropFirst(line.hasPrefix("+++ b/") ? 6 : 4)) }
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("similarity") || line.hasPrefix("old mode") || line.hasPrefix("new mode") { continue }
            if line.hasPrefix("@@") {
                // "@@ -12,5 +14,7 @@ context"
                let target = line.split(separator: " ").first { $0.hasPrefix("+") }
                newLine = Int(target?.dropFirst().split(separator: ",").first ?? "") ?? 1
                if current?.firstLine == nil { current?.firstLine = newLine }
                if current?.lines.isEmpty == false { current?.lines.append(.init(.gap, "")) }
                continue
            }
            guard let marker = line.first else { continue }
            let body = String(line.dropFirst().prefix(RequestPreview.maxLineLength))
            switch marker {
            case "+":
                added += 1
                current?.lines.append(.init(.added, body, newLine))
                newLine += 1
            case "-":
                removed += 1
                current?.lines.append(.init(.removed, body))
            case " ":
                current?.lines.append(.init(.context, body, newLine))
                newLine += 1
            default:
                // "\ No newline at end of file"
                break
            }
        }
        finish()
        return changes
    }
}
