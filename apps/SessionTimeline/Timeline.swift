import Foundation
import SessionEvents

enum Timeline {
    static let usage = """
    Usage: session-timeline < recording.jsonl

    Reads one JSON Lines recording on standard input and prints its events in order.
    Each line is an envelope: {"harness": "kiro", "event": "PreToolUse", "pid": 1, "payload": {...}}.
    If "event" is missing, payload.hook_event_name is used.

    Prompts and tool arguments are never printed. Control characters in printed
    values are escaped. Malformed lines are reported on standard error with their
    line number, and the exit status is 1. Options: -h, --help.
    """

    /// Makes a value safe for a terminal: control, format and separator characters become \\u{XXXX}; long values are cut.
    static func sanitize(_ text: String, limit: Int = 64) -> String {
        var out = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit { out += "…"; break }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate:
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default:
                out.unicodeScalars.append(scalar)
            }
            count += 1
        }
        return out
    }

    /// Returns the timeline text, the error text, and the exit status.
    static func render(_ input: Data) -> (out: String, err: String, status: Int32) {
        var out = ""
        var err = ""
        var failed = false
        var n = 0
        for (line, result) in SessionEvent.parseAll(input) {
            switch result {
            case .failure(let error):
                failed = true
                err += "line \(line): \(error)\n"
            case .success(let event):
                n += 1
                var parts = [String(format: "%3d", n), "line \(line)", sanitize(event.harness), event.native.isEmpty ? "(unnamed)" : sanitize(event.native)]
                if let session = event.string("session_id", "sessionId", "conversation_id", "sessionID") { parts.append("session=" + sanitize(session, limit: 16)) }
                if let tool = event.string("tool_name", "toolName", "tool") { parts.append("tool=" + sanitize(tool)) }
                parts.append("pid=\(event.pid)")
                out += parts.joined(separator: "  ") + "\n"
            }
        }
        if n == 0 && !failed { out = "No events.\n" }
        return (out, err, failed ? 1 : 0)
    }
}
