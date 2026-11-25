import Foundation

/// How much of a plan's rate limits is used, as the CLI last reported it.
public struct Limits: Equatable, Codable, Sendable {
    public struct Window: Equatable, Codable, Sendable {
        /// How long the window is: 300 for five hours, 10080 for a week. Nil when the CLI does not say.
        public var minutes: Int?
        /// 0 to 1.
        public var used: Double
        public var resetsAt: Date?

        public init(minutes: Int?, used: Double, resetsAt: Date?) {
            self.minutes = minutes
            self.used = max(0, min(1, used))
            self.resetsAt = resetsAt
        }

        /// "5 小时", "本周", or the length in hours or days.
        public var name: String {
            guard let minutes else { return "额度" }
            if minutes == 10080 { return "本周" }
            if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
            if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
            return "\(minutes) 分钟"
        }
    }

    public var windows: [Window]
    /// When the CLI reported them.
    public var updated: Date

    public init(windows: [Window], updated: Date) {
        self.windows = windows
        self.updated = updated
    }

    /// The windows as they stand at `now`: one whose reset has passed starts again from nothing, though the CLI has not
    /// said so yet (it reports only when it is used).
    public func current(at now: Date) -> [Window] {
        windows.map { window in
            guard let reset = window.resetsAt, reset <= now else { return window }
            return Window(minutes: window.minutes, used: 0, resetsAt: nil)
        }
    }

    /// The most used window, the one that runs out first.
    public func tightest(at now: Date) -> Window? { current(at: now).max { $0.used < $1.used } }
}

/// How full a session's context window is.
public struct ContextFill: Equatable, Sendable {
    public var tokens: Int
    /// The window's size, where the CLI says it.
    public var window: Int?

    public init(tokens: Int, window: Int?) {
        self.tokens = tokens
        self.window = window
    }

    public var fraction: Double? { window.flatMap { $0 > 0 ? min(1, Double(tokens) / Double($0)) : nil } }
}

/// Usage as each CLI writes it down locally. Codex records its rate limits and context in its session logs; Claude Code
/// records tokens per message in its transcripts, and its plan limits only reach its status line command, which Bangs
/// can relay (`StatusLineRelay`). Nothing here goes over the network.
public enum Usage {
    /// The latest limits and context in the end of a Codex session log.
    public static func codex(in tail: String) -> (limits: Limits?, context: ContextFill?) {
        var limits: Limits?, context: ContextFill?
        for line in tail.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any], payload["type"] as? String == "token_count" else { continue }
            let reported = (record["timestamp"] as? String).flatMap(Timestamps.date) ?? Date()
            if context == nil, let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
               let tokens = int(last["input_tokens"]) {
                context = ContextFill(tokens: tokens, window: int(info["model_context_window"]))
            }
            // A model with limits of its own reports them under its own id; the plan's are "codex".
            if limits == nil, let rates = payload["rate_limits"] as? [String: Any], (rates["limit_id"] as? String ?? "codex") == "codex" {
                let windows = ["primary", "secondary"].compactMap { key -> Limits.Window? in
                    guard let window = rates[key] as? [String: Any], let percent = double(window["used_percent"]) else { return nil }
                    return Limits.Window(minutes: int(window["window_minutes"]), used: percent / 100, resetsAt: date(window["resets_at"]))
                }
                if !windows.isEmpty { limits = Limits(windows: windows.sorted { ($0.minutes ?? 0) < ($1.minutes ?? 0) }, updated: reported) }
            }
            if limits != nil, context != nil { break }
        }
        return (limits, context)
    }

    /// How full the context of a Claude Code session (or one of the CLIs that write its transcripts) was at its latest
    /// reply: everything the model read for it. The window's size is not in the transcript.
    public static func claudeContext(in tail: String) -> ContextFill? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"usage\"") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "assistant", record["isSidechain"] as? Bool != true,
                  let usage = (record["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { int(usage[$0]) }.reduce(0, +)
            if tokens > 0 { return ContextFill(tokens: tokens, window: nil) }
        }
        return nil
    }

    /// How full a session's context was at its latest reply, from the end of its transcript, for the CLIs that write
    /// it there. Only Gemini's window is known from the model's name.
    public static func context(in tail: String, harness: Harness) -> ContextFill? {
        switch harness {
        case .claude: return claudeContext(in: tail)
        case .codex: return codex(in: tail).context
        case .codebuddy:
            // Responses-shaped records; the request's input tokens, cached ones included.
            for line in tail.split(separator: "\n").reversed() where line.contains("\"inputTokens\"") {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let usage = (record["providerData"] as? [String: Any])?["usage"] as? [String: Any],
                      let tokens = int(usage["inputTokens"]), tokens > 0 else { continue }
                return ContextFill(tokens: tokens, window: nil)
            }
            return nil
        case .pi, .omp:
            for line in tail.split(separator: "\n").reversed() where line.contains("\"usage\"") {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = record["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let usage = message["usage"] as? [String: Any] else { continue }
                let tokens = ["input", "cacheRead", "cacheWrite"].compactMap { int(usage[$0]) }.reduce(0, +)
                if tokens > 0 { return ContextFill(tokens: tokens, window: nil) }
            }
            return nil
        case .gemini:
            // One JSON document, cut anywhere by the tail: the last "tokens" object is whole if anything is.
            guard let start = tail.range(of: "\"tokens\"", options: .backwards),
                  let open = tail[start.upperBound...].firstIndex(of: "{"), let close = tail[open...].firstIndex(of: "}"),
                  let usage = try? JSONSerialization.jsonObject(with: Data(tail[open...close].utf8)) as? [String: Any],
                  let tokens = int(usage["input"]), tokens > 0 else { return nil }
            let model = tail.range(of: "\"model\"", options: .backwards).flatMap { found -> String? in
                let rest = tail[found.upperBound...].drop { $0 == ":" || $0 == " " || $0 == "\"" }
                return String(rest.prefix { $0 != "\"" })
            }
            // Gemini's models read a million tokens.
            return ContextFill(tokens: tokens, window: model?.hasPrefix("gemini") == true ? 1_048_576 : nil)
        default:
            return nil
        }
    }

    /// What Claude Code gives its status line command: the plan's limits (subscriptions only) and the session's context.
    public static func statusLine(_ payload: [String: Any], at now: Date = Date()) -> (limits: Limits?, context: ContextFill?) {
        var limits: Limits?
        if let rates = payload["rate_limits"] as? [String: Any] {
            let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes -> Limits.Window? in
                guard let window = rates[key] as? [String: Any], let percent = double(window["used_percentage"]) else { return nil }
                return Limits.Window(minutes: minutes, used: percent / 100, resetsAt: date(window["resets_at"]))
            }
            if !windows.isEmpty { limits = Limits(windows: windows, updated: now) }
        }
        var context: ContextFill?
        if let window = payload["context_window"] as? [String: Any], let size = int(window["context_window_size"]) {
            if let tokens = int(window["total_input_tokens"]) {
                context = ContextFill(tokens: tokens, window: size)
            } else if let percent = double(window["used_percentage"]) {
                context = ContextFill(tokens: Int(Double(size) * percent / 100), window: size)
            }
        }
        return (limits, context)
    }

    /// "18k", "1.2M".
    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: count >= 10_000_000 ? "%.0fM" : "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        return "\(count)"
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    /// Seconds or milliseconds since 1970, or an ISO 8601 string.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return Timestamps.date(text) ?? Double(text).flatMap { date($0) } }
        guard let number = double(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
    }
}
