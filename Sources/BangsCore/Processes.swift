import Darwin
import Foundation

/// Small wrappers over the BSD process table.
public enum Processes {
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// When the process started.
    public static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Every process: its parent and when it started.
    public static func table() -> [pid_t: (parent: pid_t, start: Date)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Room for processes started between the two calls.
        size += size / 8
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [:] }
        var table: [pid_t: (parent: pid_t, start: Date)] = [:]
        for info in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let start = info.kp_proc.p_un.__p_starttime
            table[info.kp_proc.p_pid] = (info.kp_eproc.e_ppid, Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000))
        }
        return table
    }

    /// Whether a descendant of `pid` that started after `date` is still running: a command an agent is waiting on.
    public static func hasDescendant(of pid: pid_t, startedAfter date: Date, in table: [pid_t: (parent: pid_t, start: Date)]) -> Bool {
        table.contains { child, entry in
            guard child != pid, entry.start > date else { return false }
            var current = entry.parent
            for _ in 0..<32 {
                if current == pid { return true }
                guard current > 1, let next = table[current]?.parent else { return false }
                current = next
            }
            return false
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// The process a hook runs for: its parent, unless that is the shell wrapping the hook command.
    public static func hookOwner(parent: pid_t = getppid()) -> pid_t {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
        if let name = name(of: parent), shells.contains(name), let grandparent = Self.parent(of: parent) { return grandparent }
        return parent
    }

    /// The pid followed by its ancestors, nearest first, stopping before launchd.
    public static func ancestry(of pid: pid_t, limit: Int = 32) -> [pid_t] {
        var chain = [pid]
        var current = pid
        while chain.count < limit, let next = parent(of: current), next > 1 {
            chain.append(next)
            current = next
        }
        return chain
    }
}
