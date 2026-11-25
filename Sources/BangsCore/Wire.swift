import Foundation
import SessionEvents

/// The hook binary and the app talk over a Unix socket, one JSON object per line.
/// The hook sends one `HookEnvelope`; for a permission request it then waits for one `PermissionReply`.
public enum Wire {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bangs", isDirectory: true)
    }
    /// `BANGS_SOCKET` overrides the path, for tests and side-by-side development builds.
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["BANGS_SOCKET"] ?? directory.appendingPathComponent("bangs.sock").path
    }
}

public struct HookEnvelope {
    public var harness: Harness
    /// The CLI's own name for the event.
    public var native: String
    /// The CLI process the hook runs for (the shell that wraps the hook command is skipped).
    public var pid: Int32
    /// The hook's stdin, as the CLI sent it.
    public var payload: [String: Any]

    public init(harness: Harness, native: String, pid: Int32, payload: [String: Any]) {
        self.harness = harness
        self.native = native
        self.pid = pid
        self.payload = payload
    }

    public func encoded() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["harness": harness.rawValue, "event": native, "pid": Int(pid), "payload": payload])
        data.append(0x0A)
        return data
    }

    public init?(line: Data) {
        guard case .success(let parsed) = SessionEvent.parse(line: line), let harness = Harness(rawValue: parsed.harness) else { return nil }
        self.init(harness: harness, native: parsed.native, pid: parsed.pid, payload: parsed.payload)
    }
    public var event: HookEvent? { harness.event(named: native) }

    // CLIs name the same things differently (Copilot uses camelCase, Cursor conversation ids, Gemini prompt_response).

    public var sessionId: String {
        string("session_id", "sessionId", "conversation_id", "sessionID") ?? "pid-\(pid)"
    }
    public var cwd: String {
        string("cwd", "directory") ?? (payload["workspace_roots"] as? [String])?.first ?? ""
    }
    public var toolName: String { string("tool_name", "toolName", "tool") ?? "" }
    public var toolInput: Any? {
        let value = payload["tool_input"] ?? payload["toolArgs"] ?? payload["args"]
        if let text = value as? String, let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) { return object }
        return value
    }
    /// The CLI's id for one tool call, where it sends one: what ties a PostToolUse to the request it answers.
    public var toolUseId: String? { string("tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id") }
    public var prompt: String? { string("prompt") }
    public var transcriptPath: String? { string("transcript_path", "transcriptPath") }
    /// How the CLI handles approvals now (Claude Code and Codex): "default", "acceptEdits", "plan", "dontAsk" or
    /// "bypassPermissions". It can change mid-session, when you switch to running without approvals.
    public var permissionMode: String? { string("permission_mode", "permissionMode") }
    /// The CLI approves everything itself: nothing waits for you.
    public var approvesEverything: Bool { ["bypassPermissions", "dontAsk"].contains(permissionMode ?? "") }
    public var lastMessage: String? { string("last_assistant_message", "prompt_response") }

    /// What a Notification is about.
    public enum NotificationKind { case permission, idle, other }
    public var notificationKind: NotificationKind {
        switch string("notification_type", "notificationType") ?? "" {
        case "permission_prompt", "ToolPermission", "permission": .permission
        case "idle_prompt", "agent_idle": .idle
        default: .other
        }
    }

    private func string(_ keys: String...) -> String? {
        SessionEvent(harness: harness.rawValue, native: native, pid: pid, payload: payload).string(keys)
    }
}

/// The user's answer to a permission request. `.terminal` hands the decision back to the CLI's own prompt; `.answers`
/// allows a question tool (`AgentQuestion`) with your answers: question text → answer.
public enum PermissionReply: Equatable, Sendable {
    case allow
    case deny
    case terminal
    case answers([String: String])

    private var decision: String {
        switch self {
        case .allow: "allow"
        case .deny: "deny"
        case .terminal: "terminal"
        case .answers: "answers"
        }
    }

    public var line: Data {
        var object: [String: Any] = ["decision": decision]
        if case .answers(let answers) = self { object["answers"] = answers }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"decision":"terminal"}"#.utf8)
        data.append(0x0A)
        return data
    }

    public init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let raw = object["decision"] as? String else { return nil }
        switch raw {
        case "allow": self = .allow
        case "deny": self = .deny
        case "terminal": self = .terminal
        case "answers":
            guard let answers = object["answers"] as? [String: String], !answers.isEmpty else { return nil }
            self = .answers(answers)
        default: return nil
        }
    }
}
