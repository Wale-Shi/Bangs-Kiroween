import Darwin
import Foundation

/// Minimal blocking Unix-domain stream socket helpers.
public enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Connects to a listening socket, or nil when nothing listens there.
    public static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    /// Binds and listens, replacing a stale socket file. Returns nil when another process is already listening.
    public static func listen(at path: String) -> Int32? {
        if let existing = connect(to: path) { close(existing); return nil }
        unlink(path)
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 64) == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        return fd
    }

    public static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
    }

    /// Reads up to the first newline (excluded), or nil on EOF before one. Each side sends a single line per
    /// connection, so reading past the newline in chunks loses nothing.
    public static func readLine(_ fd: Int32, limit: Int = 4 << 20) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while line.count < limit {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[..<newline])
                return line
            }
            line.append(contentsOf: buffer[..<count])
        }
        return nil
    }
}
