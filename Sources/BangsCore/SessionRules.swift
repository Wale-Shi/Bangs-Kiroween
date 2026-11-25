import Foundation

/// "Allow for this session": a standing yes you gave one session for one kind of request, which Bangs then answers for
/// you until the session ends. Kept narrow on purpose, because a broad rule here quietly does what you never saw:
///
/// - Nothing flagged (`Risk`) is ever answered by a rule, whatever rules there are.
/// - A command is allowed by what it runs: its program, and the subcommand for tools that have them (`swift build`,
///   `git commit`). A command whose words can hide another one (`$(…)`, backticks, `sh -c`, `xargs`, `find -exec`) or
///   that writes through a redirection is never covered, nor allowed for the session.
/// - File edits are allowed per tool, and only inside the session's folder (outside it they are flagged anyway).
/// - Any other tool is allowed by name.
/// - Questions are always yours to answer.
///
/// Rules live in memory only, per session, and go with it.
public struct SessionRule: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Commands whose every part is one of these (`swift build`, `tail`).
        case commands(Set<String>)
        /// The tool's edits inside the session's folder.
        case edits
        /// Every call of the tool.
        case tool
    }

    public let tool: String
    public let scope: Scope

    public init(tool: String, scope: Scope) {
        self.tool = tool
        self.scope = scope
    }

    /// How the rule reads on the card and in the session's menu.
    public var title: String {
        switch scope {
        case .commands(let keys): "运行 " + keys.sorted().joined(separator: "、")
        case .edits: "\(tool) 修改项目内的文件"
        case .tool: "所有 \(tool) 请求"
        }
    }

    /// The rule that would allow requests like this one for the rest of the session; nil when this kind cannot be.
    public static func rule(tool: String, input: Any?, risk: Risk?) -> SessionRule? {
        guard risk == nil, !tool.isEmpty, tool != AgentQuestion.tool else { return nil }
        if let command = RequestPreview.command(in: input) {
            return keys(of: command).map { SessionRule(tool: tool, scope: .commands($0)) }
        }
        if !RequestPreview.edits(in: input).isEmpty { return SessionRule(tool: tool, scope: .edits) }
        return SessionRule(tool: tool, scope: .tool)
    }

    /// Whether `rules` answer this request. `risk` is the request's own, and anything flagged is left to you.
    public static func covers(_ rules: [SessionRule], tool: String, input: Any?, risk: Risk?) -> Bool {
        guard risk == nil, !tool.isEmpty, tool != AgentQuestion.tool else { return false }
        let mine = rules.filter { $0.tool == tool }
        guard !mine.isEmpty else { return false }
        if let command = RequestPreview.command(in: input) {
            guard let keys = keys(of: command) else { return false }
            let allowed = mine.reduce(into: Set<String>()) { all, rule in
                if case .commands(let keys) = rule.scope { all.formUnion(keys) }
            }
            return keys.isSubset(of: allowed)
        }
        if !RequestPreview.edits(in: input).isEmpty { return mine.contains { $0.scope == .edits } }
        return mine.contains { $0.scope == .tool }
    }

    // MARK: Commands

    /// Programs that run what they are given rather than doing one thing, so naming them allows anything.
    static let runners: Set<String> = Shell.shells.union(["eval", "exec", "source", ".", "xargs", "env", "sudo", "doas", "su",
                                                           "nohup", "time", "timeout", "nice", "command", "builtin", "caffeinate",
                                                           "osascript", "open", "parallel", "watch", "script", "ssh", "expect"])
    /// Interpreters, allowed only with the same script (`python3 tools/gen.py`), never with `-c` or `-e`.
    static let interpreters: Set<String> = ["python", "python3", "node", "ruby", "perl", "php", "deno", "bun", "swift", "lua", "Rscript"]
    /// Tools whose first word picks what they do.
    static let subcommands: Set<String> = ["git", "npm", "pnpm", "yarn", "bun", "swift", "cargo", "go", "docker", "kubectl", "brew", "pip", "pip3",
                                           "uv", "poetry", "gradle", "mvn", "make", "dotnet", "xcodebuild", "gh", "deno", "rustup", "terraform",
                                           "helm", "npx", "pnpx", "bundle", "rake", "mix", "flutter", "dart", "composer", "just", "task", "nx", "turbo"]
    /// Redirections that write nowhere that matters.
    static let harmlessRedirections = ["2>&1", "1>&2", ">&2", "&>/dev/null", "2>/dev/null", "2> /dev/null", ">/dev/null", "> /dev/null", "1>/dev/null"]

    /// What a command runs, one key per part of it; nil when it cannot be pinned down that far.
    static func keys(of command: String) -> Set<String>? {
        var text = command
        for harmless in harmlessRedirections { text = text.replacingOccurrences(of: harmless, with: " ") }
        guard !text.contains(">"), !text.contains("$("), !text.contains("`"), !text.contains("<(") else { return nil }
        var keys = Set<String>()
        for pipeline in Shell.pipelines(text) {
            for words in pipeline {
                // `VAR=value cmd` sets a variable for the command only: the command is what runs.
                let words = Array(words.drop { $0.contains("=") && !$0.hasPrefix("-") && $0.first?.isLetter == true })
                guard let first = words.first else { continue }
                let program = (first as NSString).lastPathComponent
                guard !runners.contains(program) else { return nil }
                let args = Array(words.dropFirst())
                if ["find", "fd"].contains(program), args.contains(where: { ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-x", "-X", "--exec", "--exec-batch"].contains($0) }) { return nil }
                if interpreters.contains(program) && !subcommands.contains(program) {
                    guard let script = args.first, !script.hasPrefix("-") else { return nil }
                    keys.insert("\(program) \(script)")
                } else if subcommands.contains(program), let sub = args.first(where: { !$0.hasPrefix("-") }) {
                    // `swift build`, `git commit`; `swift script.swift` and `bun x.ts` run a script, which must match too.
                    keys.insert("\(program) \(sub)")
                } else {
                    keys.insert(program)
                }
            }
        }
        return keys.isEmpty ? nil : keys
    }
}
