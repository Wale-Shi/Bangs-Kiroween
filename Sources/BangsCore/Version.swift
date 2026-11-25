import Foundation

/// Release versions as Bangs tags them: "0.4.7", optionally "v0.4.7".
public enum Version {
    /// The numeric parts, missing ones as 0: "v0.4" is [0, 4].
    public static func parts(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
        return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
