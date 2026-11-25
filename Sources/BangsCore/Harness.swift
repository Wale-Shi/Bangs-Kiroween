import Foundation

/// An agent CLI whose sessions Bangs follows through the CLI's own hooks (or plugin system).
public enum Harness: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case gemini
    case qwen
    case opencode
    case copilot
    case cursor
    case droid
    case kiro
    case codebuddy
    case qoder
    case qoderCN = "qoder-cn"
    case pi
    case omp
    case hermes

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .qwen: "Qwen Code"
        case .opencode: "OpenCode"
        case .copilot: "Copilot CLI"
        case .cursor: "Cursor"
        case .droid: "Droid"
        case .kiro: "Kiro"
        case .codebuddy: "CodeBuddy"
        case .qoder: "Qoder"
        case .qoderCN: "Qoder CN"
        case .pi: "pi"
        case .omp: "omp"
        case .hermes: "Hermes"
        }
    }

    /// The directory whose presence means the CLI is set up for this user.
    public func home(in user: URL) -> URL {
        switch self {
        case .claude: user.appendingPathComponent(".claude")
        case .codex: user.appendingPathComponent(".codex")
        case .gemini: user.appendingPathComponent(".gemini")
        case .qwen: user.appendingPathComponent(".qwen")
        case .opencode: user.appendingPathComponent(".config/opencode")
        case .copilot: user.appendingPathComponent(".copilot")
        case .cursor: user.appendingPathComponent(".cursor")
        case .droid: user.appendingPathComponent(".factory")
        case .kiro: user.appendingPathComponent(".kiro")
        case .codebuddy: user.appendingPathComponent(".codebuddy")
        case .qoder: user.appendingPathComponent(".qoder")
        case .qoderCN: user.appendingPathComponent(".qoder-cn")
        case .pi: user.appendingPathComponent(".pi/agent")
        case .omp: user.appendingPathComponent(".omp/agent")
        case .hermes: user.appendingPathComponent(".hermes")
        }
    }

    /// How Bangs is wired into the CLI.
    public enum Layout: Equatable, Sendable {
        /// Claude Code's format, `{"hooks": {"Event": [{"hooks": [{"type": "command", "command", "timeout"}]}]}}`,
        /// in a file shared with other settings and tools.
        case claudeStyle(file: String, milliseconds: Bool)
        /// A file of Bangs' own in the CLI's hooks directory.
        case copilotFile
        case kiroFile
        case opencodePlugin
        /// A TypeScript extension in pi's (or omp's) extensions directory.
        case piExtension
        /// A Python plugin in Hermes' plugins directory, switched on in its config.
        case hermesPlugin
        /// No hooks of its own: the CLI runs Claude Code's hooks and is told apart by its environment.
        case viaClaude
    }

    public var layout: Layout {
        switch self {
        case .claude: .claudeStyle(file: "settings.json", milliseconds: false)
        case .codex: .claudeStyle(file: "hooks.json", milliseconds: false)
        case .gemini: .claudeStyle(file: "settings.json", milliseconds: true)
        case .qwen, .codebuddy, .qoder, .qoderCN: .claudeStyle(file: "settings.json", milliseconds: false)
        // Droid reads ~/.factory/hooks.json (events at the top level) when present, else the hooks key of settings.json.
        case .droid: .claudeStyle(file: "settings.json", milliseconds: false)
        case .copilot: .copilotFile
        case .kiro: .kiroFile
        case .opencode: .opencodePlugin
        case .pi, .omp: .piExtension
        case .hermes: .hermesPlugin
        case .cursor: .viaClaude
        }
    }

    /// The CLI's own event names and what each means to Bangs.
    public var events: [(native: String, event: HookEvent)] {
        let claude: [(String, HookEvent)] = [
            ("SessionStart", .sessionStart), ("SessionEnd", .sessionEnd), ("UserPromptSubmit", .prompt),
            ("PreToolUse", .preTool), ("PostToolUse", .postTool), ("PermissionRequest", .permissionRequest),
            ("Notification", .notification), ("Stop", .stop),
        ]
        switch self {
        case .claude, .qwen, .codebuddy, .qoder, .qoderCN: return claude
        case .codex:
            return claude.filter { ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"].contains($0.0) }
        case .droid:
            // No PermissionRequest: its Notification(permission_prompt) says the terminal is waiting for you.
            return claude.filter { $0.0 != "PermissionRequest" }
        case .gemini:
            return [("SessionStart", .sessionStart), ("SessionEnd", .sessionEnd), ("BeforeAgent", .prompt), ("BeforeTool", .preTool),
                    ("AfterTool", .postTool), ("Notification", .notification), ("AfterAgent", .stop)]
        case .copilot:
            return [("sessionStart", .sessionStart), ("sessionEnd", .sessionEnd), ("userPromptSubmitted", .prompt), ("preToolUse", .preTool),
                    ("postToolUse", .postTool), ("permissionRequest", .permissionRequest), ("agentStop", .stop)]
        case .kiro:
            return [("SessionStart", .sessionStart), ("SessionEnd", .sessionEnd), ("UserPromptSubmit", .prompt), ("PreToolUse", .preTool),
                    ("PostToolUse", .postTool), ("Stop", .stop)]
        case .opencode:
            // The plugin speaks Claude's names; permission prompts arrive as Notification(permission_prompt).
            return claude.filter { $0.0 != "PermissionRequest" }
        case .pi, .omp:
            // pi runs tools without asking, so there is nothing to approve.
            return claude.filter { !["PermissionRequest", "Notification"].contains($0.0) }
        case .hermes:
            // Hermes' approval hooks only observe, so a prompt waiting in the terminal arrives as Notification(permission_prompt).
            return claude.filter { $0.0 != "PermissionRequest" }
        case .cursor:
            // Cursor runs Claude Code's hooks but not PermissionRequest or Notification.
            return claude.filter { !["PermissionRequest", "Notification"].contains($0.0) }
        }
    }

    public func event(named native: String) -> HookEvent? {
        events.first { $0.native == native }?.event
    }

    /// Whether Bangs can answer this CLI's permission requests from the notch; otherwise it only says the terminal is waiting.
    public var answersPermissions: Bool { events.contains { $0.event == .permissionRequest } }

    /// Whether Bangs can answer this CLI's questions with choices (`AgentQuestion`): Claude Code takes the answers in
    /// the allowed tool's input.
    public var answersQuestions: Bool { self == .claude }

    /// How a permission decision is printed for this CLI. `input` is the tool's input, which answers are added to.
    public func permissionOutput(_ reply: PermissionReply, input: Any? = nil) -> String? {
        switch (self, reply) {
        case (_, .terminal): return nil
        case (_, .answers(let answers)):
            guard answersQuestions, var updated = input as? [String: Any] else { return nil }
            updated["answers"] = answers
            let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                                "decision": ["behavior": "allow", "updatedInput": updated]]]
            guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        case (.copilot, .allow): return #"{"behavior":"allow"}"#
        case (.copilot, .deny): return #"{"behavior":"deny","message":"Denied in Bangs"}"#
        // Only fields every Claude-style CLI accepts: Codex fails closed on updatedInput, updatedPermissions or interrupt.
        case (_, .allow): return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case (_, .deny): return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in Bangs"}}}"#
        }
    }

    /// The shell command that opens this session again in a terminal, from its own folder (Claude Code, Gemini and
    /// others look sessions up per project). Nil when the CLI sent no session id of its own.
    public func resumeCommand(sessionId: String, cwd: String) -> String? {
        guard !sessionId.isEmpty, !sessionId.hasPrefix("pid-") else { return nil }
        let id = Self.quote(sessionId)
        let resume: String = switch self {
        case .claude: "claude --resume \(id)"
        case .codex: "codex resume \(id)"
        case .gemini: "gemini --resume \(id)"
        case .qwen: "qwen --resume \(id)"
        case .opencode: "opencode --session \(id)"
        case .copilot: "copilot --resume \(id)"
        case .cursor: "cursor-agent --resume \(id)"
        case .droid: "droid --resume \(id)"
        // Kiro resumes the latest conversation of the folder it starts in.
        case .kiro: "kiro-cli chat --resume"
        case .codebuddy: "codebuddy --resume \(id)"
        case .qoder, .qoderCN: "qodercli --resume \(id)"
        case .pi: "pi --session \(id)"
        case .omp: "omp --resume \(id)"
        case .hermes: "hermes --resume \(id)"
        }
        return cwd.isEmpty ? resume : "cd \(Self.quote(cwd)) && \(resume)"
    }

    /// Plain words stay as they are; anything else goes in single quotes.
    static func quote(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@%+=,")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Hooks that run inside another CLI's process: Cursor runs Claude Code's hooks with its own variables set.
    public static func resolve(_ harness: Harness, environment: [String: String]) -> Harness {
        if harness == .claude, environment["CURSOR_VERSION"] != nil || environment["CURSOR_TRANSCRIPT_PATH"] != nil { return .cursor }
        return harness
    }
}

/// What an event means to Bangs, whatever the CLI calls it.
public enum HookEvent: String, Sendable {
    case sessionStart
    case sessionEnd
    case prompt
    case preTool
    case postTool
    /// The CLI waits for an allow/deny answer from the hook.
    case permissionRequest
    case notification
    case stop
}
