import Foundation

/// A file a request would change, as lines to show on its card.
public struct FileChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case edit, create, overwrite, delete
        case move(to: String)
    }

    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable { case context, added, removed, gap }
        public let kind: Kind
        public let text: String
        /// The line's number in the file as it will be (nil for removed lines, or where it is not known).
        public let number: Int?

        public init(_ kind: Kind, _ text: String, _ number: Int? = nil) {
            self.kind = kind
            self.text = text
            self.number = number
        }
    }

    /// Relative to the session's folder when inside it, else with `~` for the home folder.
    public var path: String
    public var kind: Kind
    /// Where the change starts in the file, when it could be found.
    public var firstLine: Int?
    /// Changed lines with a little context around them; unchanged stretches between them shrink to one `gap`. Empty
    /// when the change is too large to show, and `added` / `removed` still count it.
    public var lines: [Line]
    public var added: Int
    public var removed: Int

    public init(path: String, kind: Kind, firstLine: Int? = nil, lines: [Line], added: Int? = nil, removed: Int? = nil) {
        self.path = path
        self.kind = kind
        self.firstLine = firstLine
        self.lines = lines
        self.added = added ?? lines.filter { $0.kind == .added }.count
        self.removed = removed ?? lines.filter { $0.kind == .removed }.count
    }
}

/// What a request would change, read from the tool's input: an edit's old and new text, a whole file written, several
/// edits at once, or a Codex patch. Each CLI names these fields its own way; anything else has no preview and the card
/// keeps its one-line summary.
///
/// Reading the input is quick and done as the request arrives (`edits`); reading the files it touches and working out
/// the diff is left to `changes`, which callers run off the main thread.
public enum RequestPreview {
    public struct Replacement: Sendable {
        public let old: String
        public let new: String
    }

    public enum Edit: Sendable {
        case replace(path: String, [Replacement])
        case write(path: String, content: String)
        case patch(String)
    }

    /// The file as it is now, for line numbers and for what a whole-file write replaces.
    public enum FileState: Sendable {
        case missing
        case text(String)
        /// There but not read: too large, binary or not readable.
        case unread
    }

    /// Above this many lines on either side the change is counted but not shown.
    static let maxLines = 2000
    /// Files larger than this are not read.
    static let maxBytes = 2 << 20
    /// A shown line is cut here; the card shows far less of it anyway.
    static let maxLineLength = 400
    /// Unchanged lines kept around each change.
    static let context = 2

    private static let pathKeys = ["file_path", "path", "filePath", "absolute_path", "target_file"]
    private static let oldKeys = ["old_string", "old_str", "oldString"]
    private static let newKeys = ["new_string", "new_str", "newString"]
    private static let contentKeys = ["content", "file_text", "contents"]

    // MARK: Reading the input

    /// The edits in a tool's input, decided by the fields it has rather than the tool's name, which every CLI spells
    /// differently (Edit, replace, edit, str_replace…).
    public static func edits(in input: Any?) -> [Edit] {
        if let patch = patchText(in: input) { return [.patch(patch)] }
        guard let fields = input as? [String: Any], let path = string(fields, pathKeys) else { return [] }
        if let edits = fields["edits"] as? [[String: Any]] {
            let replacements = edits.compactMap { edit in
                string(edit, oldKeys).flatMap { old in string(edit, newKeys).map { Replacement(old: old, new: $0) } }
            }
            return replacements.isEmpty ? [] : [.replace(path: path, replacements)]
        }
        if let old = string(fields, oldKeys), let new = string(fields, newKeys) {
            // An empty old string is how some CLIs create a file.
            return old.isEmpty ? [.write(path: path, content: new)] : [.replace(path: path, [Replacement(old: old, new: new)])]
        }
        if let content = string(fields, contentKeys) { return [.write(path: path, content: content)] }
        return []
    }

    /// The command a request would run: Codex's `["bash", "-lc", script]` gives the script.
    public static func command(in input: Any?) -> String? {
        guard let fields = input as? [String: Any] else { return nil }
        if let command = (fields["command"] as? String) ?? (fields["cmd"] as? String) { return command.isEmpty ? nil : command }
        guard let words = fields["command"] as? [String], let program = words.first else { return nil }
        if Shell.shells.contains((program as NSString).lastPathComponent), let script = Shell.script(Array(words.dropFirst())) { return script }
        return words.map { $0.contains(where: \.isWhitespace) ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// The files the edits would write, as given (relative paths are the session's).
    public static func paths(of edits: [Edit]) -> [String] {
        edits.flatMap { edit -> [String] in
            switch edit {
            case .replace(let path, _), .write(let path, _): [path]
            case .patch(let text): patch(text).flatMap { change -> [String] in
                if case .move(let to) = change.kind { return [change.path, to] }
                return [change.path]
            }
            }
        }
    }

    /// A Codex patch (`*** Begin Patch`), wherever the input holds it: the input itself, one of its fields, or the
    /// script of an `apply_patch <<'EOF'` command.
    private static func patchText(in input: Any?) -> String? {
        func find(_ text: String) -> String? {
            guard let start = text.range(of: "*** Begin Patch") else { return nil }
            let end = text.range(of: "*** End Patch", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            return String(text[start.lowerBound..<end])
        }
        if let text = input as? String { return find(text) }
        guard let fields = input as? [String: Any] else { return nil }
        for value in fields.values {
            if let text = value as? String, let patch = find(text) { return patch }
            if let words = value as? [String], let patch = words.lazy.compactMap(find).first { return patch }
        }
        return nil
    }

    private static func string(_ fields: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { fields[$0] as? String }.first
    }

    // MARK: Working out the changes

    /// The changes the edits would make, reading the files they touch through `read`. Not on the main thread.
    public static func changes(_ edits: [Edit], cwd: String, home: String = NSHomeDirectory(),
                               read: (String) -> FileState = RequestPreview.read) -> [FileChange] {
        func absolute(_ path: String) -> String {
            let expanded = path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
            return expanded.hasPrefix("/") || cwd.isEmpty ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        }
        func shown(_ path: String) -> String { display(absolute(path), cwd: cwd, home: home) }
        return edits.flatMap { edit -> [FileChange] in
            switch edit {
            case .replace(let path, let replacements):
                let current: String? = if case .text(let text) = read(absolute(path)) { text } else { nil }
                var lines: [FileChange.Line] = [], added = 0, removed = 0, first: Int?
                for replacement in replacements {
                    let start = current.flatMap { lineNumber(of: replacement.old, in: $0) }
                    first = first ?? start
                    let change = diff(split(replacement.old), split(replacement.new), firstLine: start)
                    if !lines.isEmpty, !change.lines.isEmpty { lines.append(FileChange.Line(.gap, "")) }
                    lines += change.lines
                    added += change.added
                    removed += change.removed
                }
                return [FileChange(path: shown(path), kind: .edit, firstLine: first, lines: lines, added: added, removed: removed)]
            case .write(let path, let content):
                switch read(absolute(path)) {
                case .text(let old):
                    let change = diff(split(old), split(content), firstLine: 1)
                    return [FileChange(path: shown(path), kind: .overwrite, firstLine: change.lines.first { $0.number != nil }?.number,
                                       lines: change.lines, added: change.added, removed: change.removed)]
                case .unread:
                    return [FileChange(path: shown(path), kind: .overwrite, lines: [], added: split(content).count, removed: 0)]
                case .missing:
                    let new = split(content)
                    let shownLines = new.count > maxLines ? [] : new.enumerated().map { FileChange.Line(.added, clip($0.element), $0.offset + 1) }
                    return [FileChange(path: shown(path), kind: .create, firstLine: 1, lines: shownLines, added: new.count, removed: 0)]
                }
            case .patch(let text):
                return patch(text).map { change in
                    var change = change
                    change.path = shown(change.path)
                    if case .move(let to) = change.kind { change.kind = .move(to: shown(to)) }
                    return change
                }
            }
        }
    }

    /// Parses a Codex patch: `*** Update File:`, `*** Add File:` and `*** Delete File:` sections, an optional
    /// `*** Move to:`, and hunks of ` `, `-` and `+` lines after `@@` headers. Paths are as written.
    public static func patch(_ text: String) -> [FileChange] {
        var changes: [FileChange] = []
        var current: FileChange?
        var number = 0
        func finish() {
            if var change = current {
                change.added = change.lines.filter { $0.kind == .added }.count
                change.removed = change.lines.filter { $0.kind == .removed }.count
                changes.append(change)
            }
            current = nil
        }
        for line in split(text) {
            if line.hasPrefix("*** ") {
                let header = line.dropFirst(4)
                func path(after prefix: String) -> String? {
                    header.hasPrefix(prefix) ? header.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) : nil
                }
                if let path = path(after: "Update File:") {
                    finish()
                    current = FileChange(path: path, kind: .edit, lines: [])
                } else if let path = path(after: "Add File:") {
                    finish()
                    current = FileChange(path: path, kind: .create, firstLine: 1, lines: [])
                    number = 0
                } else if let path = path(after: "Delete File:") {
                    finish()
                    current = FileChange(path: path, kind: .delete, lines: [])
                } else if let path = path(after: "Move to:") {
                    current?.kind = .move(to: path)
                } else if header.hasPrefix("End Patch") {
                    finish()
                }
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("@@") {
                if current?.lines.isEmpty == false { current?.lines.append(FileChange.Line(.gap, "")) }
                continue
            }
            let body = clip(String(line.dropFirst()))
            switch line.first {
            case "+":
                // A new file's lines are numbered; an update's are not known from the patch.
                let created = current?.kind == .create
                if created { number += 1 }
                current?.lines.append(FileChange.Line(.added, body, created ? number : nil))
            case "-": current?.lines.append(FileChange.Line(.removed, body))
            default: current?.lines.append(FileChange.Line(.context, body))
            }
        }
        finish()
        return changes
    }

    /// A line diff of `old` against `new` (Swift's `difference(from:)`), unchanged stretches trimmed to `context` lines
    /// around each change. Lines are numbered from `firstLine` in the new text when it is known.
    public static func diff(_ old: [String], _ new: [String], firstLine: Int?) -> (lines: [FileChange.Line], added: Int, removed: Int) {
        // Diffing grows with both sizes times the number of changes: past the limit, counting every line is enough.
        guard old.count <= maxLines, new.count <= maxLines else { return ([], new.count, old.count) }
        let difference = new.difference(from: old)
        var removedOld = Set<Int>(), insertedNew = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOld.insert(offset)
            case .insert(let offset, _, _): insertedNew.insert(offset)
            }
        }
        var all: [FileChange.Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removedOld.contains(i) {
                all.append(FileChange.Line(.removed, clip(old[i])))
                i += 1
            } else if j < new.count, insertedNew.contains(j) {
                all.append(FileChange.Line(.added, clip(new[j]), firstLine.map { $0 + j }))
                j += 1
            } else {
                all.append(FileChange.Line(.context, clip(j < new.count ? new[j] : old[i]), firstLine.map { $0 + j }))
                i += 1
                j += 1
            }
        }
        // Keep the context near a change; a stretch left out becomes one gap.
        let changed = all.indices.filter { all[$0].kind != .context }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - context)...min(all.count - 1, index + context)) }
        var lines: [FileChange.Line] = []
        var skipped = false
        for (index, line) in all.enumerated() {
            if keep.contains(index) {
                if skipped, !lines.isEmpty { lines.append(FileChange.Line(.gap, "")) }
                lines.append(line)
                skipped = false
            } else {
                skipped = true
            }
        }
        return (lines, insertedNew.count, removedOld.count)
    }

    // MARK: Helpers

    /// Reads a file for a preview: missing, its text, or unread when it is too large or not text.
    @Sendable public static func read(_ path: String) -> FileState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return .missing }
        guard (attributes[.size] as? Int ?? 0) <= maxBytes, attributes[.type] as? FileAttributeType == .typeRegular,
              let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return .unread }
        return .text(text)
    }

    /// Lines without their ends; a final line break makes no extra empty line.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The 1-based line where `text` first appears in `file`.
    static func lineNumber(of text: String, in file: String) -> Int? {
        guard !text.isEmpty, let range = file.range(of: text) else { return nil }
        return file[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static func clip(_ line: String) -> String {
        let line = line.replacingOccurrences(of: "\t", with: "    ")
        return line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : line
    }

    static func display(_ path: String, cwd: String, home: String) -> String {
        let path = (path as NSString).standardizingPath
        let folder = (cwd as NSString).standardizingPath
        if !cwd.isEmpty, path.hasPrefix(folder + "/") { return String(path.dropFirst(folder.count + 1)) }
        return Risk.abbreviate(path, home: (home as NSString).standardizingPath)
    }
}
