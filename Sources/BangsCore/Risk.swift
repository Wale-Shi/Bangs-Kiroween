import Foundation

/// What a request may do beyond what it seems to: a push that rewrites a remote branch, a delete outside the project, a
/// script run straight off the internet, an edit to keys or outside the session's folder. It only explains: the card
/// shows the reason and a `danger` cannot be allowed from the keyboard, but the decision stays with you.
///
/// Commands are read as the shell would split them, word by word, so a command that only mentions `rm -rf /` inside a
/// quoted string (an `echo`, a commit message) is not flagged.
public struct Risk: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case caution, danger
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let level: Level
    /// One sentence for the person deciding, in the app's language.
    public let reason: String

    public init(_ level: Level, _ reason: String) {
        self.level = level
        self.reason = reason
    }

    /// The gravest of several; the first of equals, so the more specific reason, listed first, wins.
    public static func gravest(_ risks: [Risk?]) -> Risk? {
        risks.compactMap { $0 }.reduce(nil) { best, risk in best.map { $0.level >= risk.level ? $0 : risk } ?? risk }
    }

    // MARK: Commands

    /// The gravest risk of a shell command run in `cwd` (empty when not known: relative paths then count as inside it).
    public static func of(command: String, cwd: String, home: String = NSHomeDirectory()) -> Risk? {
        of(command: command, cwd: cwd, home: home, depth: 0)
    }

    private static func of(command: String, cwd: String, home: String, depth: Int) -> Risk? {
        // `bash -c "…"` nested in itself is read a few levels deep, no further.
        guard depth < 4 else { return nil }
        var risks: [Risk?] = []
        for pipeline in Shell.pipelines(command) {
            let commands = pipeline.map(Command.init)
            risks.append(downloadsAndRuns(commands))
            for command in commands {
                risks.append(of(command, cwd: cwd, home: home, depth: depth))
                if command.elevated { risks.append(Risk(.danger, "以管理员身份运行（\(command.elevator)），能改动系统里的任何文件")) }
            }
        }
        return gravest(risks)
    }

    private static func of(_ command: Command, cwd: String, home: String, depth: Int) -> Risk? {
        let args = command.args
        switch command.program {
        case "rm": return remove(args, cwd: cwd, home: home)
        case "git": return git(args)
        case let shell where Shell.shells.contains(shell):
            guard let script = Shell.script(args) else { return nil }
            // `sh -c "$(curl …)"` runs what it downloads.
            if ["$(curl", "$(wget", "`curl", "`wget"].contains(where: script.contains) { return Risk(.danger, "下载并直接运行网上的脚本，运行前看不到它的内容") }
            return of(command: script, cwd: cwd, home: home, depth: depth + 1)
        case "dd" where args.contains { $0.hasPrefix("of=/dev/") }:
            return Risk(.danger, "会直接写入磁盘设备，盘上原有的数据会被覆盖")
        case let program where program.hasPrefix("mkfs") || program.hasPrefix("newfs"):
            return Risk(.danger, "会格式化磁盘")
        case "diskutil" where args.contains { ["erase", "partitiondisk", "zerodisk", "randomdisk", "secureerase", "reformat"].contains(where: $0.lowercased().hasPrefix) }:
            return Risk(.danger, "会抹掉磁盘")
        case "chmod" where args.contains { ["777", "666", "a+rwx", "a+w", "o+w", "ugo+rwx"].contains($0) }:
            return Risk(.caution, "会让所有人都能读写这些文件")
        case "dropdb":
            return Risk(.caution, "会删除整个数据库")
        case let client where databaseClients.contains(client) && args.contains(where: dropsData):
            return Risk(.caution, "会删除数据库里的数据")
        default: return nil
        }
    }

    /// `curl … | sh`: a download piped into something that runs it.
    private static func downloadsAndRuns(_ commands: [Command]) -> Risk? {
        guard let download = commands.firstIndex(where: { ["curl", "wget"].contains($0.program) }),
              commands[(download + 1)...].contains(where: runsInput)
        else {
            // `bash <(curl …)`
            let substituted = commands.contains { Shell.shells.contains($0.program) && $0.args.contains { $0.hasPrefix("<(") && ($0.contains("curl") || $0.contains("wget")) } }
            return substituted ? Risk(.danger, "下载并直接运行网上的脚本，运行前看不到它的内容") : nil
        }
        return Risk(.danger, "下载并直接运行网上的脚本，运行前看不到它的内容")
    }

    /// Whether a shell or interpreter runs what it reads from the pipe: `| sh`, `| bash -s -- …`, `| python3 -`, but not
    /// `| python3 -m json.tool` or `| bash -c '…'`, which only read it as data.
    private static func runsInput(_ command: Command) -> Bool {
        guard Shell.shells.contains(command.program) || runtimes.contains(command.program) else { return false }
        if command.args.contains("-s") { return true }
        if command.args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(where: "cem".contains) }) { return false }
        let operand = command.args.first { !$0.hasPrefix("-") }
        return operand == nil || operand == "-"
    }

    private static let runtimes: Set<String> = ["python", "python3", "node", "ruby", "perl", "php"]
    private static let databaseClients: Set<String> = ["psql", "mysql", "mariadb", "sqlite3", "duckdb", "clickhouse", "clickhouse-client", "sqlcmd", "mongosh", "redis-cli"]

    private static func dropsData(_ word: String) -> Bool {
        let text = word.lowercased()
        return text.range(of: #"\b(drop\s+(table|database|schema)|truncate(\s+table)?\s+\w)"#, options: .regularExpression) != nil
            || ["flushall", "flushdb", "dropdatabase()"].contains { text.contains($0) }
    }

    private static func remove(_ args: [String], cwd: String, home: String) -> Risk? {
        var recursive = false, targets: [String] = [], operands = false
        for arg in args {
            if !operands, arg == "--" { operands = true; continue }
            if !operands, arg.hasPrefix("--") { recursive = recursive || arg == "--recursive"; continue }
            if !operands, arg.hasPrefix("-"), arg.count > 1 { recursive = recursive || arg.contains("r") || arg.contains("R"); continue }
            targets.append(arg)
        }
        // Without -r only files go, as they would one by one in the Finder.
        guard recursive, !targets.isEmpty else { return nil }
        let homePath = (home as NSString).standardizingPath
        for target in targets {
            let path = expand(target, home: homePath)
            if path == "/" || path.hasPrefix("/*") { return Risk(.danger, "会删除整个磁盘上的文件") }
            if path == homePath || path == homePath + "/*" { return Risk(.danger, "会删除你的整个家目录") }
            if path.contains("$") { return Risk(.caution, "删除的路径里有变量，展开后才知道删的是哪里") }
            guard !cwd.isEmpty else { continue }
            let resolved = resolve(path, cwd: cwd)
            let project = (cwd as NSString).standardizingPath
            if resolved == project { return Risk(.danger, "会删除整个项目文件夹") }
            if !inside(resolved, project), !temporary(resolved) {
                return Risk(.danger, "会永久删除项目之外的文件（\(abbreviate(resolved, home: homePath))）")
            }
        }
        let what = targets.count == 1 ? (targets[0] as NSString).lastPathComponent : "\(targets.count) 项"
        return Risk(.caution, "删除 \(what)，删除后不能从废纸篓找回")
    }

    private static func git(_ args: [String]) -> Risk? {
        // Options before the subcommand, two of which take a value of their own.
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            index += ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(args[index]) ? 2 : 1
        }
        guard index < args.count else { return nil }
        let subcommand = args[index], rest = Array(args[(index + 1)...])
        let flags = rest.filter { $0.hasPrefix("-") }, positional = rest.filter { !$0.hasPrefix("-") }
        func short(_ letter: Character) -> Bool { flags.contains { !$0.hasPrefix("--") && $0.dropFirst().contains(letter) } }
        switch subcommand {
        case "push":
            // Remote, then refspecs: `+main` forces one branch, `:main` deletes it.
            let refspecs = positional.dropFirst()
            let branch = refspecs.first.map { spec in String(spec.drop { $0 == "+" || $0 == ":" }.split(separator: ":").last ?? "") }.flatMap { $0.isEmpty ? nil : $0 }
            // A branch name between Chinese words gets a space on each side.
            let target = branch.map { "远程分支 \($0)" } ?? "远程分支"
            let history = branch.map { "远程分支 \($0) 的历史" } ?? "远程分支的历史"
            if flags.contains("--delete") || short("d") || refspecs.contains(where: { $0.hasPrefix(":") }) {
                return Risk(.danger, "会删除\(target)")
            }
            if flags.contains(where: { $0.hasPrefix("--force-with-lease") || $0.hasPrefix("--force-if-includes") }), !flags.contains("--force") {
                return Risk(.caution, "强制推送（有 lease 保护），仍会改写\(history)")
            }
            if flags.contains("--force") || flags.contains("--mirror") || short("f") || refspecs.contains(where: { $0.hasPrefix("+") }) {
                return Risk(.danger, "强制推送，会覆盖\(history)，别人已拉取的提交会丢失")
            }
        case "reset" where flags.contains("--hard"):
            return Risk(.caution, "会丢掉还没提交的改动")
        case "clean" where (flags.contains("--force") || short("f")) && !flags.contains("--dry-run") && !short("n"):
            return Risk(.caution, "会删除没被 git 跟踪的文件")
        case "checkout" where flags.contains("--force") || short("f") || (rest.contains("--") && !positional.isEmpty) || positional == ["."]:
            return Risk(.caution, "会丢掉还没提交的改动")
        case "restore" where !positional.isEmpty && (!flags.contains("--staged") || flags.contains("--worktree")):
            return Risk(.caution, "会丢掉这些文件还没提交的改动")
        case "branch" where short("D") || (flags.contains("--delete") && flags.contains("--force")):
            return Risk(.caution, "会删除还没合并的分支")
        case "stash" where ["drop", "clear"].contains(positional.first ?? ""):
            return Risk(.caution, "会丢掉暂存（stash）里的改动")
        default: break
        }
        return nil
    }

    // MARK: Files

    /// The risk of changing the file at `path`, for a session in `cwd`.
    public static func of(path: String, cwd: String, home: String = NSHomeDirectory()) -> Risk? {
        let homePath = (home as NSString).standardizingPath
        let resolved = resolve(expand(path, home: homePath), cwd: cwd)
        let name = (resolved as NSString).lastPathComponent
        let components = (resolved as NSString).pathComponents
        let secretFolder = components.contains { [".ssh", ".gnupg"].contains($0) } || resolved.hasPrefix(homePath + "/Library/Keychains")
        let secretFile = (name == ".env" || (name.hasPrefix(".env.") && ![".example", ".sample", ".template", ".dist"].contains { name.hasSuffix($0) }))
            || ["pem", "key", "p12", "pfx", "keychain"].contains((name as NSString).pathExtension.lowercased())
            || ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"].contains { name.hasPrefix($0) }
            || resolved.hasSuffix("/.aws/credentials") || name == ".netrc"
        if secretFolder || secretFile { return Risk(.danger, "会改动密钥或凭据") }
        let project = (cwd as NSString).standardizingPath
        if !cwd.isEmpty, !inside(resolved, project), !temporary(resolved) {
            return Risk(.caution, "在项目之外修改文件（项目在 \(abbreviate(project, home: homePath))）")
        }
        return nil
    }

    // MARK: Paths

    private static func expand(_ path: String, home: String) -> String {
        for prefix in ["~", "$HOME", "${HOME}"] where path == prefix || path.hasPrefix(prefix + "/") {
            return home + path.dropFirst(prefix.count)
        }
        return path
    }

    private static func resolve(_ path: String, cwd: String) -> String {
        let absolute = path.hasPrefix("/") || cwd.isEmpty ? path : (cwd as NSString).appendingPathComponent(path)
        return (absolute as NSString).standardizingPath
    }

    private static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Scratch space agents use all the time; changing it is not news.
    private static func temporary(_ path: String) -> Bool {
        ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", NSTemporaryDirectory()].contains { inside(path, ($0 as NSString).standardizingPath) }
    }

    static func abbreviate(_ path: String, home: String) -> String {
        inside(path, home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// One simple command: its program, without the wrappers that only change how it runs (`env`, `nohup`, `sudo`…).
private struct Command {
    let program: String
    let args: [String]
    /// Run through sudo or doas, named here.
    let elevator: String

    var elevated: Bool { !elevator.isEmpty }

    init(_ words: [String]) {
        var words = words[...], elevator = ""
        while let first = words.first {
            if first.contains("="), !first.hasPrefix("="), !first.hasPrefix("-"), first.prefix(while: { $0 != "=" }).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                words = words.dropFirst()   // VAR=value
            } else if ["sudo", "doas"].contains(first) {
                elevator = first
                words = words.dropFirst()
                // sudo's own options; -u and -g take a value.
                while let option = words.first, option.hasPrefix("-") {
                    words = words.dropFirst(["-u", "-g", "-h", "-p", "-C"].contains(option) ? 2 : 1)
                }
            } else if ["env", "command", "builtin", "exec", "nohup", "time", "caffeinate"].contains(first) {
                words = words.dropFirst()
                while let option = words.first, option.hasPrefix("-") { words = words.dropFirst() }
            } else if first == "nice" {
                words = words.dropFirst()
                if words.first == "-n" { words = words.dropFirst(2) } else if words.first?.hasPrefix("-") == true { words = words.dropFirst() }
            } else {
                break
            }
        }
        program = words.first.map { ($0 as NSString).lastPathComponent } ?? ""
        args = Array(words.dropFirst())
        self.elevator = elevator
    }
}

/// Splits shell text the way a POSIX shell would, far enough to tell commands and their words apart: quotes, escapes,
/// `;` `&&` `||` `&` and newlines between commands, `|` within a pipeline, redirections (whose targets are not words of
/// the command) and comments. `$(…)`, backticks and `<(…)` stay inside the word they appear in.
enum Shell {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// Pipelines, each a list of commands, each a list of words.
    static func pipelines(_ text: String) -> [[[String]]] {
        let chars = Array(text)
        var pipelines: [[[String]]] = [], commands: [[String]] = [], words: [String] = []
        var word = "", inWord = false, redirected = false
        func endWord() {
            if inWord {
                if redirected { redirected = false } else { words.append(word) }
            }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        func endPipeline() {
            endCommand()
            if !commands.isEmpty { pipelines.append(commands) }
            commands = []
        }
        /// Copies a bracketed run (`$(…)`, `<(…)`) whole, nesting included, from the opening bracket at `start`.
        func balanced(from start: Int) -> Int {
            var depth = 0, index = start
            while index < chars.count {
                if chars[index] == "(" { depth += 1 } else if chars[index] == ")" { depth -= 1; if depth == 0 { return index } }
                index += 1
            }
            return chars.count - 1
        }
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            switch char {
            case "'":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "'" { word.append(chars[index]); index += 1 }
            case "\"":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count, "\"\\$`".contains(chars[index + 1]) { index += 1 }
                    word.append(chars[index])
                    index += 1
                }
            case "\\":
                if let next, next != "\n" { word.append(next); inWord = true }
                index += 1
            case " ", "\t":
                endWord()
            case "\n", ";":
                endPipeline()
            case "&":
                if next == "&" { endPipeline(); index += 1 } else if next == ">" { endWord(); index += 1; redirected = true } else { endPipeline() }
            case "|":
                if next == "|" { endPipeline(); index += 1 } else { endCommand(); if next == "&" { index += 1 } }
            case "<" where next == "(":
                endWord()
                let end = balanced(from: index + 1)
                word = "<" + String(chars[(index + 1)...end])
                inWord = true
                index = end
            case ">", "<":
                // `2>file`: the descriptor's number is part of the operator, not a word.
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false } else { endWord() }
                while index + 1 < chars.count, ">&|".contains(chars[index + 1]) { index += 1 }
                redirected = true
            case "$" where next == "(":
                let end = balanced(from: index + 1)
                word += String(chars[index...end])
                inWord = true
                index = end
            case "`":
                var end = index + 1
                while end < chars.count, chars[end] != "`" { end += 1 }
                word += String(chars[index...min(end, chars.count - 1)])
                inWord = true
                index = end
            case "#" where !inWord:
                while index + 1 < chars.count, chars[index + 1] != "\n" { index += 1 }
            case "(", ")":
                endWord()
            default:
                word.append(char)
                inWord = true
            }
            index += 1
        }
        endPipeline()
        return pipelines
    }

    /// The script of `sh -c script` (any flags spelled with c: `-lc`, `-ec`), nil when the shell reads a file or stdin.
    static func script(_ args: [String]) -> String? {
        guard let flag = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }) else { return nil }
        return args[(flag + 1)...].first { !$0.hasPrefix("-") }
    }
}
