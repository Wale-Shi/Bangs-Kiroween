import AppKit
import BangsCore
import Combine
import Darwin
import SQLite3

/// A finished or earlier session, read from the CLI's own records.
struct PastSession: Codable, Identifiable, Equatable {
    var harness: Harness
    var sessionId: String
    var cwd = ""
    var branch = ""
    /// The title the CLI gave it (Codex's thread title, Claude Code's generated one), and one you gave it yourself.
    var title = ""
    var customTitle = ""
    /// What you typed, in order.
    var prompts: [String] = []
    /// The agent's replies and the commands it ran, for the full-text search.
    var texts: [String] = []
    var updated = Date.distantPast
    /// A thread Codex ran for itself (its approval reviewer, a sub-agent).
    var isInternal = false
    var archived = false

    /// The most of `texts` kept per session, in UTF-8 bytes: a long-running session would otherwise hold every reply it
    /// ever gave. The newest are kept; prompts are never dropped (they are few, and the title comes from them).
    static let textBytesLimit = 256 * 1024

    /// Drops the oldest texts past `textBytesLimit`.
    mutating func trimTexts() {
        var bytes = 0, keep = texts.count
        while keep > 0, bytes + texts[keep - 1].utf8.count <= Self.textBytesLimit {
            bytes += texts[keep - 1].utf8.count
            keep -= 1
        }
        if keep > 0 { texts.removeFirst(keep) }
    }

    var id: String { "\(harness.rawValue):\(sessionId)" }
    var project: String { cwd.isEmpty ? harness.displayName : (cwd as NSString).lastPathComponent }
    var resumeCommand: String? { harness.resumeCommand(sessionId: sessionId, cwd: cwd) }
    /// The title to show: one the CLI gave it, else your first prompt.
    var shownTitle: String {
        !customTitle.isEmpty ? customTitle : !title.isEmpty ? title : SessionStore.oneLine(prompts.first ?? "", limit: 120)
    }
}

/// Reading the records: Claude Code keeps a transcript per session under ~/.claude/projects, Codex a rollout per thread
/// under ~/.codex/sessions with titles in its state database, CodeBuddy a log per session under ~/.codebuddy/projects,
/// pi and omp one under their agent folder's sessions, Gemini CLI a JSON file per chat under ~/.gemini/tmp, and OpenCode
/// a SQLite database. Line-by-line files are read from where the last read stopped, so a growing transcript costs only
/// its new lines; Gemini's chats are one JSON document each, read again whole when they change.
enum HistoryReader {
    /// Each kept text is cut to this: enough to find it by, without holding whole files in memory.
    static let textLimit = 4000

    static func claudeFiles(home: URL) -> [URL] { jsonl(in: home.appendingPathComponent(".claude/projects"), depth: 1) }
    static func codexFiles(home: URL) -> [URL] { jsonl(in: home.appendingPathComponent(".codex/sessions"), depth: 3) }

    /// Every session file Bangs reads, with the CLI that wrote it.
    static func files(home: URL) -> [(URL, Harness)] {
        claudeFiles(home: home).map { ($0, .claude) } + codexFiles(home: home).map { ($0, .codex) }
            + jsonl(in: home.appendingPathComponent(".codebuddy/projects"), depth: 1).map { ($0, .codebuddy) }
            + jsonl(in: home.appendingPathComponent(".pi/agent/sessions"), depth: 1).map { ($0, .pi) }
            + jsonl(in: home.appendingPathComponent(".omp/agent/sessions"), depth: 1).map { ($0, .omp) }
            + geminiFiles(home: home).map { ($0, .gemini) }
    }

    /// ~/.gemini/tmp/<project>/chats/session-….json; the project's folder is written in <project>/.project_root.
    static func geminiFiles(home: URL) -> [URL] {
        let projects = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".gemini/tmp"), includingPropertiesForKeys: nil)) ?? []
        return projects.flatMap { project in
            ((try? FileManager.default.contentsOfDirectory(at: project.appendingPathComponent("chats"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
        }
    }

    /// Whether the CLI writes a session as whole lines that only grow (else the file is read again whole).
    static func appends(_ harness: Harness) -> Bool { harness != .gemini }

    /// The id a session file is named by, where it is.
    static func sessionId(of file: URL, harness: Harness) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        switch harness {
        case .claude, .codebuddy: return name
        // "2026-11-03T15-08-40-305Z_<id>"; the header line says it too.
        case .pi, .omp: return name.split(separator: "_").last.map(String.init) ?? ""
        default: return ""
        }
    }

    /// Reads lines of a session file into `session`, the way its CLI writes them.
    static func read(_ lines: [Data], harness: Harness, into session: inout PastSession) {
        switch harness {
        case .claude: readClaude(lines, into: &session)
        case .codex: readCodex(lines, into: &session)
        case .codebuddy: readCodeBuddy(lines, into: &session)
        case .pi, .omp: readPi(lines, into: &session)
        default: break
        }
    }

    private static func jsonl(in folder: URL, depth: Int) -> [URL] {
        var level = [folder]
        for _ in 0..<depth {
            level = level.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                .filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return level.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
    }

    /// The complete lines of `file` after `offset`, and where they end.
    /// The whole lines from `offset` on, as slices of the file mapped into memory: nothing is copied, and the pages
    /// go back to the system as soon as the lines are read (session files run to tens of megabytes).
    static func lines(of file: URL, from offset: UInt64) -> (lines: [Data], end: UInt64)? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        guard offset < UInt64(data.count), let last = data[Int(offset)...].lastIndex(of: 0x0A) else { return ([], offset) }
        return (data[Int(offset)...last].split(separator: 0x0A, omittingEmptySubsequences: true), UInt64(last + 1))
    }

    // MARK: Claude Code

    private static let claudeTypes = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"ai-title\"", "\"type\":\"custom-title\""].map { Data($0.utf8) }

    /// Each line's parsed objects go as soon as it is read: kept until the file was done, a long session held hundreds
    /// of megabytes for a moment, and left the heap in pieces that stayed.
    static func readClaude(_ lines: [Data], into session: inout PastSession) {
        var stamp: String?
        for line in lines { autoreleasepool {
            // Most lines are bookkeeping, some of it large (whole API requests): only these are worth parsing.
            guard claudeTypes.contains(where: { line.range(of: $0) != nil }),
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch record["type"] as? String {
            case "custom-title":
                if let title = record["customTitle"] as? String { session.customTitle = title }
            // Generated again as the conversation goes on: the latest stands.
            case "ai-title":
                if let title = record["aiTitle"] as? String, !title.isEmpty { session.title = title }
            case "user", "assistant":
                if record["isSidechain"] as? Bool == true || record["isMeta"] as? Bool == true { return }
                if let cwd = record["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
                if let branch = record["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { session.branch = branch }
                stamp = record["timestamp"] as? String ?? stamp
                let message = record["message"] as? [String: Any] ?? [:]
                let blocks = message["content"] as? [[String: Any]] ?? (message["content"] as? String).map { [["type": "text", "text": $0]] } ?? []
                if record["type"] as? String == "user" {
                    for block in blocks where block["type"] as? String == "text" {
                        if let text = block["text"] as? String, isPrompt(text) { session.prompts.append(cut(text)) }
                    }
                } else {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text": if let text = block["text"] as? String, !text.isEmpty { session.texts.append(cut(text)) }
                        case "tool_use": if let command = command(block["input"]) { session.texts.append(command) }
                        default: break
                        }
                    }
                }
            default: break
            }
        } }
        if let stamp, let date = date(stamp) { session.updated = max(session.updated, date) }
        session.trimTexts()
    }

    // MARK: Codex

    static func readCodex(_ lines: [Data], into session: inout PastSession) {
        var stamp: String?
        for line in lines { autoreleasepool {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            let payload = record["payload"] as? [String: Any] ?? [:]
            switch record["type"] as? String {
            case "session_meta":
                if let id = payload["id"] as? String { session.sessionId = id }
                if let cwd = payload["cwd"] as? String { session.cwd = cwd }
                let source = payload["thread_source"] as? String ?? ((payload["source"] as? [String: Any])?["subagent"] != nil ? "subagent" : "")
                session.isInternal = Transcript.codexInternalSources.contains(source)
                stamp = record["timestamp"] as? String ?? stamp
            case "response_item":
                stamp = record["timestamp"] as? String ?? stamp
                switch payload["type"] as? String {
                case "message":
                    let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                    switch payload["role"] as? String {
                    case "user": session.prompts += texts.filter(isPrompt).map(cut)
                    case "assistant": session.texts += texts.filter { !$0.isEmpty }.map(cut)
                    default: break
                    }
                case "function_call":
                    let arguments = (payload["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    if let command = command(arguments) { session.texts.append(command) }
                case "custom_tool_call":
                    if let input = payload["input"] as? String, !input.isEmpty { session.texts.append(String(input.prefix(300))) }
                default: break
                }
            default: break
            }
        } }
        if let stamp, let date = date(stamp) { session.updated = max(session.updated, date) }
        session.trimTexts()
    }

    // MARK: CodeBuddy

    /// One record per line: your messages and its replies in the Responses API's shape, tool calls with their
    /// arguments as JSON text, each line with the session's folder and id.
    static func readCodeBuddy(_ lines: [Data], into session: inout PastSession) {
        var stamp: Double?
        for line in lines { autoreleasepool {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let id = record["sessionId"] as? String, !id.isEmpty { session.sessionId = id }
            if let cwd = record["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
            switch record["type"] as? String {
            case "message":
                stamp = (record["timestamp"] as? NSNumber)?.doubleValue ?? stamp
                let texts = (record["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                switch record["role"] as? String {
                case "user": session.prompts += texts.filter(isPrompt).map(cut)
                case "assistant": session.texts += texts.filter { !$0.isEmpty }.map(cut)
                default: break
                }
            case "function_call":
                let arguments = (record["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                if let command = command(arguments) { session.texts.append(command) }
            default: break
            }
        } }
        if let stamp { session.updated = max(session.updated, Date(timeIntervalSince1970: stamp / 1000)) }
        session.trimTexts()
    }

    // MARK: pi and omp

    /// A header line (`session`: id, folder), titles, and messages whose content is text and tool calls.
    static func readPi(_ lines: [Data], into session: inout PastSession) {
        var stamp: String?
        for line in lines { autoreleasepool {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch record["type"] as? String {
            case "session":
                if let id = record["id"] as? String, !id.isEmpty { session.sessionId = id }
                if let cwd = record["cwd"] as? String { session.cwd = cwd }
                if let title = record["title"] as? String, !title.isEmpty { session.title = plain(title) }
                stamp = record["timestamp"] as? String ?? stamp
            case "title", "title_change":
                if let title = record["title"] as? String, !title.isEmpty { session.title = plain(title) }
            case "message":
                stamp = record["timestamp"] as? String ?? stamp
                let message = record["message"] as? [String: Any] ?? [:]
                let parts = message["content"] as? [[String: Any]] ?? (message["content"] as? String).map { [["type": "text", "text": $0]] } ?? []
                switch message["role"] as? String {
                case "user":
                    for part in parts where part["type"] as? String == "text" {
                        if let text = part["text"] as? String, isPrompt(text) { session.prompts.append(cut(text)) }
                    }
                case "assistant":
                    for part in parts {
                        switch part["type"] as? String {
                        case "text": if let text = part["text"] as? String, !text.isEmpty { session.texts.append(cut(text)) }
                        case "toolCall": if let command = command(part["arguments"]) { session.texts.append(command) }
                        default: break
                        }
                    }
                default: break
                }
            default: break
            }
        } }
        if let stamp, let date = date(stamp) { session.updated = max(session.updated, date) }
        session.trimTexts()
    }

    /// omp starts its titles with an icon from a Nerd Font, which other fonts draw as a box.
    static func plain(_ title: String) -> String {
        let privateUse: (Unicode.Scalar) -> Bool = { (0xE000...0xF8FF).contains($0.value) || $0.value >= 0xF0000 }
        return String(String.UnicodeScalarView(title.unicodeScalars.drop { privateUse($0) || $0.properties.isWhitespace }))
    }

    // MARK: Gemini CLI

    /// One JSON document per chat: its id, when it was last updated, and its messages (yours, Gemini's with the tools
    /// it called). The folder is the project's, read from beside the chats.
    static func readGemini(_ data: Data, cwd: String, into session: inout PastSession) {
        guard let chat = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        session.prompts = []
        session.texts = []
        if let id = chat["sessionId"] as? String { session.sessionId = id }
        session.cwd = cwd
        for message in chat["messages"] as? [[String: Any]] ?? [] {
            let content = message["content"]
            let texts = (content as? String).map { [$0] } ?? (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            switch message["type"] as? String {
            case "user": session.prompts += texts.filter(isPrompt).map(cut)
            case "gemini":
                session.texts += texts.filter { !$0.isEmpty }.map(cut)
                for call in message["toolCalls"] as? [[String: Any]] ?? [] {
                    if let command = command(call["args"]) { session.texts.append(command) }
                }
            default: break
            }
        }
        if let stamp = chat["lastUpdated"] as? String, let date = date(stamp) { session.updated = date }
        session.trimTexts()
    }

    static func geminiFolder(of file: URL) -> String {
        let root = file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".project_root")
        return (try? String(contentsOf: root, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: OpenCode

    static func openCodeDatabase(home: URL) -> URL { home.appendingPathComponent(".local/share/opencode/opencode.db") }

    /// OpenCode's sessions from its database, read only: titles and folders from `session`, what was said from the
    /// text and tool parts of each message. Sub-agents' sessions (with a parent) are its own.
    static func readOpenCode(home: URL) -> [PastSession] {
        var db: OpaquePointer?
        let path = openCodeDatabase(home: home).path
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        func rows(_ sql: String, _ each: (OpaquePointer) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
        }
        func text(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var sessions: [String: PastSession] = [:]
        rows("select id, directory, title, time_updated, time_archived is not null, parent_id is not null from session") { row in
            var session = PastSession(harness: .opencode, sessionId: text(row, 0))
            session.cwd = text(row, 1)
            // Until it names the session, OpenCode calls it "New session - <date>".
            let title = text(row, 2)
            session.title = title.hasPrefix("New session - ") ? "" : title
            session.updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1000)
            session.archived = sqlite3_column_int(row, 4) != 0
            session.isInternal = sqlite3_column_int(row, 5) != 0
            sessions[session.sessionId] = session
        }
        guard !sessions.isEmpty else { return [] }
        rows("select p.session_id, m.data, p.data from part p join message m on m.id = p.message_id order by p.session_id, p.time_created") { row in
            autoreleasepool {
                let id = text(row, 0)
                guard sessions[id] != nil,
                      let message = try? JSONSerialization.jsonObject(with: Data(text(row, 1).utf8)) as? [String: Any],
                      let part = try? JSONSerialization.jsonObject(with: Data(text(row, 2).utf8)) as? [String: Any] else { return }
                let user = message["role"] as? String == "user"
                switch part["type"] as? String {
                case "text":
                    guard let body = part["text"] as? String, part["synthetic"] as? Bool != true else { return }
                    if user { if isPrompt(body) { sessions[id]?.prompts.append(cut(body)) } } else if !body.isEmpty { sessions[id]?.texts.append(cut(body)) }
                case "tool":
                    if let command = command((part["state"] as? [String: Any])?["input"]) { sessions[id]?.texts.append(command) }
                default: break
                }
            }
        }
        return sessions.values.map { session in
            var session = session
            session.trimTexts()
            return session
        }
    }

    /// When OpenCode's database last changed (its write-ahead log takes the writes first).
    static func openCodeModified(home: URL) -> Date? {
        let path = openCodeDatabase(home: home).path
        return [path, path + "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }

    /// Titles, branches and archiving from the Codex app's thread list, by thread id. Empty when it cannot be read
    /// (an older Codex, or a newer one that moved it).
    static func codexThreads(home: URL) -> [String: (title: String, branch: String, archived: Bool)] {
        let folder = home.appendingPathComponent(".codex")
        let databases = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) }
        guard let name = databases.last else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(folder.appendingPathComponent(name).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select id, title, coalesce(git_branch, ''), archived from threads", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var threads: [String: (String, String, Bool)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            threads[text(0)] = (text(1), text(2), sqlite3_column_int(statement, 3) != 0)
        }
        return threads
    }

    // MARK: Pieces

    /// What you typed, not what the CLI put in your turn: context blocks, slash command records, notices.
    static func isPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.hasPrefix("<") && !trimmed.hasPrefix("[Request interrupted") && !trimmed.hasPrefix("# AGENTS.md")
            && !trimmed.hasPrefix("Caveat:") && !trimmed.hasPrefix("[Image")
    }

    /// A tool call in one line: the shell command, or the file it touched.
    static func command(_ input: Any?) -> String? {
        let fields = input as? [String: Any] ?? [:]
        if let command = fields["command"] as? String ?? fields["cmd"] as? String ?? (fields["command"] as? [String])?.joined(separator: " ") {
            return "$ " + String(command.prefix(300))
        }
        for key in ["file_path", "path", "pattern", "url", "query"] {
            if let value = fields[key] as? String, !value.isEmpty { return String(value.prefix(300)) }
        }
        return nil
    }

    private static func cut(_ text: String) -> String { text.count > textLimit ? String(text.prefix(textLimit)) : text }

    private static func date(_ text: String) -> Date? { Timestamps.date(text) }
}

/// Finding sessions: every word of the query must turn up somewhere in a session; the session shows the line where the
/// first word did, the surest kind of match first (its ID, title or a prompt before a reply), then the latest.
enum HistorySearch {
    enum Field: Int, Comparable {
        case id, title, prompt, project, branch, reply
        static func < (a: Field, b: Field) -> Bool { a.rawValue < b.rawValue }
    }

    struct Snippet: Equatable {
        var before: String
        var match: String
        var after: String
    }

    struct Hit: Identifiable, Equatable {
        let session: PastSession
        /// The surest kind of field that matched, for ranking.
        let field: Field
        /// The line to show under the title, and which kind of field it comes from. The title, project and branch are
        /// on the first line already, so a match there shows your first prompt instead.
        let snippet: Snippet
        let snippetField: Field
        var id: String { session.id }
    }

    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A session with all its searchable text lowered into one run of bytes, so a query is a few `memmem` calls per
    /// session: milliseconds for every session on the Mac, where comparing field by field took a few hundred.
    struct Indexed: Sendable {
        let session: PastSession
        let haystack: [UInt8]
        /// Where each field of `fields(of:)` ends in it, and its kind: a match's offset says which field it is in.
        let ends: [Int]
        let kinds: [Field]

        init(_ session: PastSession) {
            self.session = session
            var bytes: [UInt8] = [], ends: [Int] = [], kinds: [Field] = []
            for (field, text) in HistorySearch.fields(of: session) {
                if !bytes.isEmpty { bytes.append(0x0A) }
                bytes += text.lowercased().utf8
                ends.append(bytes.count)
                kinds.append(field)
            }
            haystack = bytes
            self.ends = ends
            self.kinds = kinds
        }

        /// The first field holding `needle` that `allowed` takes, by its place in `fields(of:)`.
        func field(of needle: [UInt8], where allowed: (Field) -> Bool = { _ in true }) -> Int? {
            haystack.withUnsafeBytes { hay in
                needle.withUnsafeBytes { word in
                    var start = 0, field = 0
                    while start < hay.count, let hit = memmem(hay.baseAddress! + start, hay.count - start, word.baseAddress, word.count) {
                        let offset = UnsafeRawPointer(hit) - hay.baseAddress!
                        while field < ends.count - 1, ends[field] <= offset { field += 1 }
                        if allowed(kinds[field]) { return field }
                        start = ends[field] + 1
                        field += 1
                    }
                    return nil
                }
            }
        }

        func contains(_ needle: [UInt8]) -> Bool {
            haystack.withUnsafeBytes { hay in
                needle.withUnsafeBytes { word in memmem(hay.baseAddress, hay.count, word.baseAddress, word.count) != nil }
            }
        }
    }

    static func search(_ sessions: [PastSession], for query: String, limit: Int = 60) -> [Hit] {
        search(sessions.map(Indexed.init), for: query, limit: limit)
    }

    static func search(_ sessions: [Indexed], for query: String, limit: Int = 60) -> [Hit] {
        let words = words(query)
        guard let first = words.first else { return [] }
        let needles = words.map { Array($0.utf8) }
        // Ranked by where the first word turns up, read off the lowered bytes; only the sessions shown get a snippet.
        var ranked: [(item: Indexed, field: Field)] = []
        for item in sessions where needles.allSatisfy(item.contains) {
            // Another word may be the one in the text; the session still matched every word.
            ranked.append((item, item.field(of: needles[0]).map { item.kinds[$0] } ?? .reply))
        }
        let shown = ranked.sorted { ($0.field, $1.item.session.updated) < ($1.field, $0.item.session.updated) }.prefix(limit)
        return shown.map { item, rank in
            let session = item.session
            if let index = item.field(of: needles[0], where: { ![.title, .project, .branch].contains($0) }) {
                let (field, text) = fields(of: session)[index]
                if let range = text.range(of: first, options: .caseInsensitive) {
                    return Hit(session: session, field: rank, snippet: snippet(text, range), snippetField: field)
                }
            }
            let prompt = session.prompts.first.map { SessionStore.oneLine($0, limit: 140) } ?? ""
            return Hit(session: session, field: rank, snippet: Snippet(before: prompt, match: "", after: ""), snippetField: .prompt)
        }
    }

    static func fields(of session: PastSession) -> [(field: Field, text: String)] {
        [(.id, session.sessionId), (.title, session.customTitle), (.title, session.title)] + session.prompts.map { (.prompt, $0) }
            + [(.project, session.project), (.branch, session.branch)] + session.texts.map { (.reply, $0) }
    }

    /// The match with a little before it and more after, on one line.
    static func snippet(_ text: String, _ range: Range<String.Index>) -> Snippet {
        let flat = { (part: Substring) in part.split(whereSeparator: \.isNewline).joined(separator: " ") }
        let before = flat(text[text.startIndex..<range.lowerBound])
        let after = flat(text[range.upperBound...])
        return Snippet(before: before.count > 24 ? "…" + before.suffix(24) : before, match: String(text[range]), after: String(after.prefix(120)))
    }
}

/// The past sessions on this Mac, kept up to date when you search. Held in memory only: Bangs keeps no copy of your
/// conversations on disk, so each launch reads them once more in the background (a few seconds for hundreds).
@MainActor
final class SessionHistory: ObservableObject {
    @Published private(set) var sessions: [PastSession] = []
    /// The same sessions, ready to search.
    private(set) var indexed: [HistorySearch.Indexed] = []
    /// Reading files: how many are done of how many.
    @Published private(set) var progress: (done: Int, total: Int)?
    private var lastRefresh = Date.distantPast
    private var refreshing = false
    private let preferences: Preferences
    private let home: URL
    /// What was read of each file, to read only what is new next time.
    private var files: [String: FileState] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    /// What was read of each file: how far, and the session it holds.
    struct FileState: Sendable {
        var size: UInt64
        var modified: Date
        var offset: UInt64
        var session: PastSession
    }

    init(preferences: Preferences, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.preferences = preferences
        self.home = home
        // Turned off: nothing is kept.
        preferences.$sessionHistory.dropFirst().filter { !$0 }.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.files = [:]
                self?.show([])
                self?.lastRefresh = .distantPast
            }
        }.store(in: &subscriptions)
    }

    /// Sessions you can search: yours, and archived ones only if you asked for them.
    var searchable: [PastSession] { sessions.filter(shows) }
    var searchableIndex: [HistorySearch.Indexed] { indexed.filter { shows($0.session) } }

    private func shows(_ session: PastSession) -> Bool {
        !session.isInternal && (preferences.historyIncludesArchived || !session.archived) && !session.sessionId.isEmpty
    }

    /// Sessions given rather than read, for snapshots: no reading over them for a while.
    func show(_ sessions: [PastSession]) {
        lastRefresh = Date().addingTimeInterval(3600)
        indexed = sessions.map(HistorySearch.Indexed.init)
        self.sessions = sessions
    }

    func count(of harness: Harness) -> Int { searchable.filter { $0.harness == harness }.count }

    /// Reads what changed since the last time, off the main thread. Cheap when nothing did; at most every 20 seconds.
    func refresh(force: Bool = false) {
        guard preferences.sessionHistory, !refreshing, force || Date().timeIntervalSince(lastRefresh) > 20 else { return }
        refreshing = true
        lastRefresh = Date()
        let home = home, previous = files
        // Sessions that did not change keep their lowered text.
        let known = Dictionary(indexed.map { ($0.session.id, $0) }, uniquingKeysWith: { first, _ in first })
        Task.detached(priority: .utility) {
            let (sessions, files) = Self.read(home: home, previous: previous) { done, total in
                Task { @MainActor [weak self] in self?.progress = done < total ? (done, total) : nil }
            }
            let indexed = sessions.map { session in
                known[session.id].flatMap { $0.session == session ? $0 : nil } ?? HistorySearch.Indexed(session)
            }
            await MainActor.run {
                self.files = files
                self.indexed = indexed
                self.sessions = sessions
                self.progress = nil
                self.refreshing = false
            }
            // The reading is over and most of what it used is free again: hand it back rather than keep it for later.
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private nonisolated static func read(home: URL, previous states: [String: FileState],
                                         progress: @escaping @Sendable (Int, Int) -> Void) -> ([PastSession], [String: FileState]) {
        let files = HistoryReader.files(home: home)
        let threads = HistoryReader.codexThreads(home: home)
        var kept: [String: FileState] = [:]
        for (index, (file, harness)) in files.enumerated() {
            if index % 20 == 0 { progress(index, files.count) }
            // The parser's objects go as soon as each file is read, not when the whole read is over (that held hundreds
            // of megabytes).
            autoreleasepool {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value, let modified = attributes[.modificationDate] as? Date else { return }
                var state = states[file.path]
                if let current = state, current.size == size, current.modified == modified {
                    kept[file.path] = current
                    return
                }
                // Grown: read on from where it stopped. Rewritten or new, or a file only ever read whole: from the start.
                if state == nil || size < state!.offset || !HistoryReader.appends(harness) {
                    let id = HistoryReader.sessionId(of: file, harness: harness)
                    state = FileState(size: 0, modified: .distantPast, offset: 0, session: PastSession(harness: harness, sessionId: id))
                }
                guard var next = state else { return }
                if harness == .gemini {
                    guard let data = try? Data(contentsOf: file) else { return }
                    HistoryReader.readGemini(data, cwd: HistoryReader.geminiFolder(of: file), into: &next.session)
                    next.offset = size
                } else {
                    guard let read = HistoryReader.lines(of: file, from: next.offset) else { return }
                    HistoryReader.read(read.lines, harness: harness, into: &next.session)
                    next.offset = read.end
                }
                next.size = size
                next.modified = modified
                kept[file.path] = next
            }
        }
        // OpenCode's database, read again only when it changed: kept under its path like a file.
        let database = HistoryReader.openCodeDatabase(home: home).path
        if let modified = HistoryReader.openCodeModified(home: home) {
            if let known = states.filter({ $0.key.hasPrefix(database + "#") }).first, known.value.modified == modified {
                for (key, state) in states where key.hasPrefix(database + "#") { kept[key] = state }
            } else {
                for session in HistoryReader.readOpenCode(home: home) {
                    kept[database + "#" + session.sessionId] = FileState(size: 0, modified: modified, offset: 0, session: session)
                }
            }
        }
        // Files deleted since are not kept.
        let sessions = kept.values.map { state in
            var session = state.session
            if session.harness == .codex, let thread = threads[session.sessionId] {
                if !thread.title.isEmpty { session.title = thread.title }
                if !thread.branch.isEmpty { session.branch = thread.branch }
                session.archived = thread.archived
            }
            return session
        }
        .filter { !$0.prompts.isEmpty || !$0.title.isEmpty || !$0.customTitle.isEmpty }
        .sorted { $0.updated > $1.updated }
        return (sessions, kept)
    }
}
