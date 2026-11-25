import Foundation
import IOKit.ps

/// Holding a MacBook's battery below a chosen charge: the helper that runs as root (bangs-charge) has the firmware keep
/// the limit, or where it cannot, stops charging at the limit and starts again a little below it. Bangs tells it the
/// limit through a file and a notification.
public enum ChargeLimit {
    public static let label = "io.github.wale-shi.bangs.charge"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let daemonPlistPath = "/Library/LaunchDaemons/\(label).plist"
    /// The limit in percent, as text. Missing or 100 means no limit. Somewhere both Bangs and root can reach.
    public static let settingPath = "/Users/Shared/Bangs/charge-limit"
    /// Posted by Bangs when the setting changes, so the helper applies it at once.
    public static let changedNotification = "\(label).changed"
    /// Bumped when the helper changes, so Bangs knows to install it again.
    public static let helperVersion = 2
    /// Charging starts again this many points below the limit, so it does not flick on and off.
    public static let resumeBelow = 5
    public static let range = 50...95

    /// The limit to apply, from the setting's text: nil (charge fully) unless it is a number in `range`.
    public static func limit(from text: String?) -> Int? {
        guard let text, let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else { return nil }
        return value
    }

    /// Whether charging should be held off: from the limit up; below it, it stays as it was until `resumeBelow` under.
    public static func holds(level: Int, limit: Int?, holding: Bool) -> Bool {
        guard let limit else { return false }
        if level >= limit { return true }
        if level < limit - resumeBelow { return false }
        return holding
    }

    /// How this Mac's firmware controls charging, newest first:
    /// - `firmware`: a limit the firmware keeps itself, between a lower and an upper percentage (bfF0 on or off, bfD0
    ///   the upper, bfE0 the lower, both 32-bit little-endian). Firmware from 2026 (mBoot 20457 and later), also in
    ///   the macOS 15.8 and 26.7 updates; it holds through sleep.
    /// - `chte`: charging on or off (CHTE), on firmware before that from macOS 15.
    /// - `ch0bc`: charging on or off (CH0B and CH0C), on older firmware.
    /// nil on a Mac without a battery, and where none of these may be used: macOS 27 keeps the firmware limit to
    /// Apple's own software, and the newer firmware leaves the older keys as empty placeholders.
    public enum Switch: Equatable {
        case firmware, chte, ch0bc

        public init?(_ smc: SMC) {
            if Self.firmwareUsable(smc) { self = .firmware }
            else if smc.has("CHTE") { self = .chte }
            else if smc.has("CH0B") && smc.has("CH0C") { self = .ch0bc }
            else { return nil }
        }

        private static let firmwareKeys = ["bfF0": 1, "bfD0": 4, "bfE0": 4]

        /// All three keys answer, at their size or none reported, and the switch reads back.
        private static func firmwareUsable(_ smc: SMC) -> Bool {
            firmwareKeys.allSatisfy { key, size in smc.size(of: key).map { $0 == size || $0 == 0 } ?? false }
                && smc.read("bfF0", expected: 1) != nil
        }

        /// The firmware enforces the limit by itself, sleep included; the others need the helper to switch charging.
        public var keepsLimit: Bool { self == .firmware }

        /// Whether charging is held off now; with the firmware limit, whether the limit is on.
        public func holding(_ smc: SMC) -> Bool {
            switch self {
            case .firmware: smc.read("bfF0", expected: 1)?.first == 2
            case .chte: (smc.read("CHTE") ?? []).contains { $0 != 0 }
            case .ch0bc: (smc.read("CH0B") ?? []).contains { $0 != 0 }
            }
        }

        /// Holds charging off or lets it go on; needs root. Not for the firmware limit, which `keep` sets.
        @discardableResult
        public func hold(_ on: Bool, _ smc: SMC) -> Bool {
            switch self {
            case .firmware: on ? false : smc.write("bfF0", [0])
            case .chte: smc.write("CHTE", on ? [1, 0, 0, 0] : [0, 0, 0, 0])
            case .ch0bc: smc.write("CH0B", [on ? 2 : 0]) && smc.write("CH0C", [on ? 2 : 0])
            }
        }

        /// The firmware limit as set now: whether it is on, and its range.
        public func firmwareLimit(_ smc: SMC) -> (on: Bool, lower: Int, upper: Int)? {
            guard self == .firmware, let on = smc.read("bfF0", expected: 1)?.first,
                  let upper = smc.read("bfD0", expected: 4).flatMap(Self.percent),
                  let lower = smc.read("bfE0", expected: 4).flatMap(Self.percent) else { return nil }
            return (on == 2, lower, upper)
        }

        /// Sets the firmware limit to charge up to `upper` and start again below `lower`, or turns it off (nil); needs
        /// root. Unchanged when it is already so. The firmware wants the limit off while its range changes.
        @discardableResult
        public func keep(_ range: (lower: Int, upper: Int)?, _ smc: SMC) -> Bool {
            guard self == .firmware else { return false }
            let now = firmwareLimit(smc)
            guard let range else { return now?.on == false || smc.write("bfF0", [0]) }
            if let now, now.on, now.lower == range.lower, now.upper == range.upper { return true }
            guard smc.write("bfF0", [0]), smc.write("bfD0", Self.bytes(range.upper)), smc.write("bfE0", Self.bytes(range.lower)),
                  smc.write("bfF0", [2]) else {
                smc.write("bfF0", [0])
                return false
            }
            // Read back, and leave it off rather than half set.
            guard let set = firmwareLimit(smc), set.on, set.lower == range.lower, set.upper == range.upper else {
                smc.write("bfF0", [0])
                return false
            }
            return true
        }

        static func bytes(_ percent: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(percent).littleEndian) { Array($0) } }
        static func percent(_ bytes: [UInt8]) -> Int? {
            bytes.count == 4 ? Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24) : nil
        }
    }
}

/// The internal battery as macOS reports it.
public struct Battery: Equatable {
    public var level: Int
    public var onPower: Bool
    public var charging: Bool

    public init(level: Int, onPower: Bool, charging: Bool) {
        self.level = level
        self.onPower = onPower
        self.charging = charging
    }

    /// nil on a Mac without a battery.
    public static func current() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(level: current * 100 / max,
                           onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                           charging: description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}
