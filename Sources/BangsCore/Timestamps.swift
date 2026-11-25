import Foundation

/// ISO 8601 dates, read and written by formatters made once: making one is far dearer than using it, and transcripts
/// and the log go through these for every line. The formatters are only configured here, and ISO8601DateFormatter is
/// thread safe once configured, so the queues that call these can share them.
public enum Timestamps {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// With or without fractional seconds, as CLIs write them.
    public static func date(_ text: String) -> Date? { fractional.date(from: text) ?? plain.date(from: text) }

    public static func string(_ date: Date = Date()) -> String { plain.string(from: date) }
}
