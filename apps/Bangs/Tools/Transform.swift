import Foundation

/// Developer conversions offered for a clipboard item's text: only those that fit it, each with its result worked out.
enum Transform {
    enum Kind: String, CaseIterable {
        case json, timestamp, base64, url, naming

        var title: String {
            switch self {
            case .json: "JSON 格式化 / 压缩"
            case .timestamp: "时间戳 ↔ 日期"
            case .base64: "Base64 编码 / 解码"
            case .url: "URL 编码 / 解码"
            case .naming: "命名风格"
            }
        }

        var example: String {
            switch self {
            case .json: "{\"a\":1} ⇄ 缩进好的多行，键的顺序不变"
            case .timestamp: "1762311600 → 2025-11-05 11:00:00，秒和毫秒都认"
            case .base64: "aGVsbG8= → hello"
            case .url: "%E5%88%98%E6%B5%B7 → 刘海"
            case .naming: "user_name ⇄ userName ⇄ UserName ⇄ user-name"
            }
        }
    }

    struct Offer: Equatable, Identifiable {
        let title: String
        let result: String
        var id: String { title }
    }

    /// Longer text is left alone: checking it would slow the clipboard down for nothing.
    static let limit = 200_000

    /// The most specific first: valid JSON, a timestamp or date, something encoded, a name; else the encodings.
    static func offers(for text: String, kinds: Set<Kind>, utc: Bool) -> [Offer] {
        guard text.count <= limit else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var offers: [Offer] = []
        var encodings: [Offer] = []
        if kinds.contains(.json), let first = trimmed.first, "{[".contains(first),
           let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            let pretty = json(trimmed, pretty: true), compact = json(trimmed, pretty: false)
            if pretty != trimmed { offers.append(Offer(title: "格式化", result: pretty)) }
            if compact != trimmed { offers.append(Offer(title: "压缩", result: compact)) }
        }
        let singleLine = !trimmed.contains("\n")
        if kinds.contains(.timestamp), singleLine {
            if let date = date(fromTimestamp: trimmed) {
                let result = format(date, milliseconds: trimmed.count == 13, utc: utc)
                offers.append(Offer(title: "→ \(result)", result: result))
            } else if let date = date(fromText: trimmed, utc: utc) {
                let result = String(Int(date.timeIntervalSince1970))
                offers.append(Offer(title: "→ \(result)", result: result))
            }
        }
        if kinds.contains(.base64), singleLine, trimmed.count <= 2000 {
            if let decoded = base64Decoded(trimmed) {
                offers.append(Offer(title: "Base64 解码", result: decoded))
            } else {
                encodings.append(Offer(title: "Base64 编码", result: Data(trimmed.utf8).base64EncodedString()))
            }
        }
        if kinds.contains(.url), singleLine {
            if trimmed.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil, let decoded = trimmed.removingPercentEncoding, decoded != trimmed {
                offers.append(Offer(title: "URL 解码", result: decoded))
            } else if let encoded = urlEncoded(trimmed), encoded != trimmed {
                encodings.append(Offer(title: "URL 编码", result: encoded))
            }
        }
        if kinds.contains(.naming), let words = words(of: trimmed) {
            for style in [camel(words), pascal(words), words.joined(separator: "_"), words.joined(separator: "-")] where style != trimmed {
                offers.append(Offer(title: style, result: style))
            }
        }
        // Encoding JSON, a timestamp or a name is rarely what you want: encodings only when nothing else fits.
        return offers.isEmpty ? encodings : offers
    }

    // MARK: JSON

    /// Re-indents (or squeezes) JSON text without parsing it into a dictionary, so the keys keep their order.
    static func json(_ text: String, pretty: Bool) -> String {
        let characters = Array(text)
        var out = ""
        var depth = 0
        var inString = false, escaped = false
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        /// The next character that is not whitespace.
        func next(after index: Int) -> Character? {
            var index = index + 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            return index < characters.count ? characters[index] : nil
        }
        for (index, character) in characters.enumerated() {
            if inString {
                out.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
                out.append(character)
            case _ where character.isWhitespace:
                continue
            case "{", "[":
                out.append(character)
                // An empty object or array stays on one line.
                if let following = next(after: index), following == "}" || following == "]" { continue }
                depth += 1
                if pretty { newline() }
            case "}", "]":
                if let last = out.last, last != "{" && last != "[" {
                    depth -= 1
                    if pretty { newline() }
                }
                out.append(character)
            case ",":
                out.append(character)
                if pretty { newline() }
            case ":":
                out += pretty ? ": " : ":"
            default:
                out.append(character)
            }
        }
        return out
    }

    // MARK: Timestamps

    /// Seconds (10 digits) or milliseconds (13) between 2000 and 2100: anything else is just a number.
    static func date(fromTimestamp text: String) -> Date? {
        guard text.count == 10 || text.count == 13, text.allSatisfy(\.isASCII), let value = Double(text), text.allSatisfy(\.isNumber) else { return nil }
        let seconds = text.count == 13 ? value / 1000 : value
        guard seconds >= 946_684_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func date(fromText text: String, utc: Bool) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func format(_ date: Date, milliseconds: Bool, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        formatter.dateFormat = milliseconds ? "yyyy-MM-dd HH:mm:ss.SSS" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + (utc ? " UTC" : "")
    }

    // MARK: Encodings

    /// Standard or URL-safe Base64 that decodes to readable text. Most words are valid Base64 too, but they decode
    /// to bytes that are not text, so they are not offered.
    static func base64Decoded(_ text: String) -> String? {
        guard text.count >= 8, text.range(of: "^[A-Za-z0-9+/_-]+={0,2}$", options: .regularExpression) != nil else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        guard let data = Data(base64Encoded: standard), let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty,
              decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || "\n\r\t".unicodeScalars.contains($0) })
        else { return nil }
        return decoded
    }

    /// A whole link keeps its structure (only spaces and other characters a link cannot hold are escaped); anything
    /// else is escaped as one query value.
    static func urlEncoded(_ text: String) -> String? {
        if text.contains("://") {
            return text.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#")))
        }
        return text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127))).union(.init(charactersIn: "-._~")))
    }

    // MARK: Naming

    /// The words of an identifier written in any of the usual styles, lower case; nil for anything else or one word.
    static func words(of text: String) -> [String]? {
        guard text.count <= 80, text.range(of: "^[A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)*$", options: .regularExpression) != nil else { return nil }
        var words: [String] = []
        for part in text.split(whereSeparator: { $0 == "_" || $0 == "-" }) {
            var current = ""
            let characters = Array(part)
            for (index, character) in characters.enumerated() {
                let previous = index > 0 ? characters[index - 1] : nil
                let following = index + 1 < characters.count ? characters[index + 1] : nil
                // userName → user|Name; HTTPServer → HTTP|Server.
                let boundary = character.isUppercase && previous.map { $0.isLowercase || $0.isNumber || ($0.isUppercase && following?.isLowercase == true) } == true
                if boundary, !current.isEmpty { words.append(current); current = "" }
                current.append(character)
            }
            if !current.isEmpty { words.append(current) }
        }
        let lowered = words.map { $0.lowercased() }
        return lowered.count > 1 ? lowered : nil
    }

    private static func camel(_ words: [String]) -> String { words[0] + words.dropFirst().map(\.capitalized).joined() }
    private static func pascal(_ words: [String]) -> String { words.map(\.capitalized).joined() }
}
