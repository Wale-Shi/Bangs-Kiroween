import Foundation

/// Stopping an agent mid-turn (Esc, or rejecting a tool) sends no hook at all in Claude Code, Codex or CodeBuddy, so the
/// session would look busy until the next prompt. Each of them writes the interruption to its transcript, though.
public enum Transcript {
    /// The end of a transcript is enough: the record that decides is among the last few.
    public static func tail(of path: String, bytes: Int = 32_768) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// How a turn ended, as its transcript tells it.
    public enum End: Equatable {
        /// Stopped mid-turn.
        case interrupted(Date)
        /// Completed, with the agent's last message when the transcript has it.
        case finished(Date, message: String?)
        /// Gave up on an error, such as a dropped connection after its retries.
        case failed(Date, message: String)

        public var date: Date {
            switch self {
            case .interrupted(let date), .finished(let date, _), .failed(let date, _): date
            }
        }
    }

    /// When the turn was interrupted, if the latest record that says how the turn stands is an interruption.
    public static func interruption(in tail: String) -> Date? {
        if case .interrupted(let date) = end(in: tail) { return date }
        return nil
    }

    /// How the turn ended, if the latest record that says how the turn stands is its end. Codex records its turns'
    /// ends, and its desktop app may never send the Stop hook when a turn fails; the other CLIs' hooks are reliable.
    public static func end(in tail: String) -> End? {
        for line in tail.split(separator: "\n").reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let date = timestamp(record) ?? Date()
            switch verdict(record) {
            case .interrupted: return .interrupted(date)
            case .finished(let message): return .finished(date, message: message)
            case .failed(let message): return .failed(date, message: message)
            case .going: return nil
            case .unrelated: continue
            }
        }
        return nil
    }

    private enum Verdict { case interrupted, finished(String?), failed(String), going, unrelated }

    private static func verdict(_ record: [String: Any]) -> Verdict {
        let type = record["type"] as? String ?? ""
        switch type {
        // Claude Code: "[Request interrupted by user]" (or "… for tool use") as the user's next message.
        case "user", "assistant":
            if record["isSidechain"] as? Bool == true { return .unrelated }
            guard type == "user", let message = record["message"] as? [String: Any] else { return .going }
            let parts = (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? [message["content"] as? String].compactMap { $0 }
            return parts.contains { $0.hasPrefix("[Request interrupted by user") } ? .interrupted : .going
        // Codex: a turn ends with task_complete, turn_aborted or an error (stream_error is only a retry).
        case "event_msg":
            let payload = record["payload"] as? [String: Any] ?? [:]
            switch payload["type"] as? String ?? "" {
            case "turn_aborted": return .interrupted
            case "task_complete", "turn_complete": return .finished(payload["last_agent_message"] as? String)
            case "error": return .failed(payload["message"] as? String ?? "")
            case "task_started", "turn_started", "user_message": return .going
            default: return .unrelated
            }
        // CodeBuddy: the stopped tool's result is left incomplete.
        case "function_call_result":
            return record["status"] as? String == "incomplete" ? .interrupted : .going
        case "message", "function_call":
            return .going
        default:
            return .unrelated
        }
    }

    /// What started a Codex thread, from its transcript's first record: "user", "automation", "subagent",
    /// "guardian_review" and so on. Nil while the transcript is not written yet, and for other CLIs.
    public static func codexThreadSource(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The first record carries Codex's base instructions: tens of KB.
        guard let data = try? handle.read(upToCount: 512 * 1024), let end = data.firstIndex(of: 0x0A),
              let record = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
              record["type"] as? String == "session_meta", let payload = record["payload"] as? [String: Any] else { return nil }
        if let source = payload["thread_source"] as? String { return source }
        // Older transcripts: a sub-agent's source is an object naming it.
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return "subagent" }
        return payload["source"] as? String ?? ""
    }

    /// Threads Codex runs for itself rather than for you: the reviewer that judges approval requests, and the
    /// sub-agents a conversation spawns (their parent already shows the work).
    public static let codexInternalSources: Set<String> = ["guardian_review", "subagent", "memory", "memory_consolidation"]

    private static func timestamp(_ record: [String: Any]) -> Date? {
        if let text = record["timestamp"] as? String { return Timestamps.date(text) }
        if let millis = record["timestamp"] as? Double { return Date(timeIntervalSince1970: millis / 1000) }
        return nil
    }
}
