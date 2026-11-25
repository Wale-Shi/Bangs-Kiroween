import Foundation

/// One recorded CLI event: the envelope that hooks send, one JSON object per line.
/// Foundation only, so any tool can reuse it without linking Bangs.
public struct SessionEvent {
    /// The CLI's name, such as "kiro". Not restricted to the harnesses Bangs knows.
    public var harness: String
    /// The CLI's own event name. Older envelopes omit `event`; then `payload.hook_event_name` is used.
    public var native: String
    /// The CLI process id. 0 when absent or outside the Int32 range.
    public var pid: Int32
    public var payload: [String: Any]

    public init(harness: String, native: String, pid: Int32, payload: [String: Any]) {
        self.harness = harness
        self.native = native
        self.pid = pid
        self.payload = payload
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case notObject
        case missingHarness
        case missingPayload

        public var description: String {
            switch self {
            case .notJSON: "not valid JSON"
            case .notObject: "not a JSON object"
            case .missingHarness: "missing string field \"harness\""
            case .missingPayload: "missing object field \"payload\""
            }
        }
    }

    /// Parses one line. Never traps: malformed input and out-of-range integers become errors or defaults.
    public static func parse(line: Data) -> Result<SessionEvent, ParseError> {
        guard let any = try? JSONSerialization.jsonObject(with: line) else { return .failure(.notJSON) }
        guard let object = any as? [String: Any] else { return .failure(.notObject) }
        guard let harness = object["harness"] as? String else { return .failure(.missingHarness) }
        guard let payload = object["payload"] as? [String: Any] else { return .failure(.missingPayload) }
        let native = object["event"] as? String ?? payload["hook_event_name"] as? String ?? ""
        var pid: Int32 = 0
        if let raw = object["pid"] as? Int, let exact = Int32(exactly: raw) { pid = exact }
        return .success(SessionEvent(harness: harness, native: native, pid: pid, payload: payload))
    }

    /// Splits a recording into lines (LF or CRLF) and parses each. Line numbers start at 1; blank lines are skipped.
    public static func parseAll(_ data: Data) -> [(line: Int, result: Result<SessionEvent, ParseError>)] {
        var out: [(Int, Result<SessionEvent, ParseError>)] = []
        var number = 0
        for var piece in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            number += 1
            if piece.last == 0x0D { piece = piece.dropLast() }
            if piece.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            out.append((number, parse(line: Data(piece))))
        }
        return out
    }

    public func string(_ keys: String...) -> String? { string(keys) }

    public func string(_ keys: [String]) -> String? {
        for key in keys { if let value = payload[key] as? String, !value.isEmpty { return value } }
        return nil
    }
}
