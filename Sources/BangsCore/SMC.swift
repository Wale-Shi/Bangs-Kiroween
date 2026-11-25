import Foundation
import IOKit

/// The System Management Controller, which among much else decides whether the battery charges. Anyone may read its
/// keys; only root may write them.
public final class SMC {
    private var connection: io_connect_t = 0

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// A key's bytes, or nil when this Mac has no such key or will not let us read it. Some firmware reports a size of
    /// 0 for keys that read fine at their known size, given as `expected`.
    public func read(_ key: String, expected: Int? = nil) -> [UInt8]? {
        guard let reported = size(of: key) else { return nil }
        let size = reported > 0 ? reported : expected ?? 0
        guard size > 0, size <= 32 else { return nil }
        var input = Self.request(key, command: 5)
        Self.put(UInt32(size), into: &input, at: 28)
        guard let output = call(input) else { return nil }
        return Array(output[48..<48 + size])
    }

    /// Writes `bytes` to a key of that size (or one reporting 0); false when it is missing, of another size, or we
    /// are not allowed to (not root, or the firmware keeps it to Apple).
    @discardableResult
    public func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let size = size(of: key), size == bytes.count || size == 0, bytes.count <= 32 else { return false }
        var input = Self.request(key, command: 6)
        Self.put(UInt32(bytes.count), into: &input, at: 28)
        input.replaceSubrange(48..<48 + bytes.count, with: bytes)
        return call(input) != nil
    }

    /// Whether this Mac has the key with a value. Newer firmware keeps keys it no longer lets anyone use as empty
    /// placeholders, which do not count.
    public func has(_ key: String) -> Bool { (size(of: key) ?? 0) > 0 }

    /// A key's size in bytes; nil when it is missing or we may not ask.
    public func size(of key: String) -> Int? {
        guard let output = call(Self.request(key, command: 9)) else { return nil }
        return Int(output.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) })
    }

    /// What asking for a key's size gives, for diagnosing: the size, or the driver's or the SMC's error.
    public func describe(_ key: String) -> String {
        var output = [UInt8](repeating: 0, count: 80)
        var count = output.count
        let input = Self.request(key, command: 9)
        let result = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, $0.baseAddress, &count) }
        }
        if result != kIOReturnSuccess { return String(format: "error 0x%08x", result) }
        if output[40] != 0 { return String(format: "missing (SMC 0x%02x)", output[40]) }
        let size = Int(output.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) })
        let value = read(key).map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "unreadable"
        return "size \(size): \(value)"
    }

    /// The driver's SMCKeyData_t, 80 bytes: the key at 0, its size at 28 (keyInfo.dataSize), the result at 40, the
    /// command at 42 (data8) and the value from 48.
    private static func request(_ key: String, command: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 80)
        put(key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, into: &bytes, at: 0)
        bytes[42] = command
        return bytes
    }

    private static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var size = output.count
        let result = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                // kSMCHandleYPCEvent
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &size)
            }
        }
        return result == kIOReturnSuccess && output[40] == 0 ? output : nil
    }
}
