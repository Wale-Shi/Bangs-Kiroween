import Darwin
import Foundation
import SwiftUI
import BangsCore

/// CPU and memory of this Mac, and the processes using the most.
@MainActor
final class SystemMonitor: ObservableObject {
    struct Process: Identifiable, Equatable {
        let pid: Int32
        let name: String
        let cpu: Double
        let memory: UInt64
        var id: Int32 { pid }
    }

    /// 0…1 across all cores.
    @Published private(set) var cpu: Double = 0
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var top: [Process] = []
    /// The status tab is open, so the process list is worth collecting.
    var watchingProcesses = false { didSet { updateSampling() } }
    /// The closed island shows CPU or memory.
    var inNotch = false { didSet { updateSampling() } }

    private var previous: (busy: UInt64, total: UInt64)?
    private var timer: Timer?
    private var listing = false

    /// Sampling runs only while something shows it.
    var sampling: Bool { timer != nil }

    private func updateSampling() {
        let needed = watchingProcesses || inNotch
        guard needed != sampling else { return }
        guard needed else {
            timer?.invalidate()
            timer = nil
            // Ticks from long ago would average the whole pause into the first figure.
            previous = nil
            return
        }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        timer?.tolerance = 0.4
        // The first sample only sets the baseline: a fresh CPU figure follows shortly rather than in two seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { if let self, self.sampling { self.sample() } }
        }
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            // The counters are 32 bits and wrap; a sample across the wrap is skipped rather than trapping.
            if let previous, ticks.total > previous.total, ticks.busy >= previous.busy {
                cpu = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
            }
            previous = ticks
        }
        memoryUsed = Self.memoryInUse() ?? memoryUsed
        if watchingProcesses && !listing { listProcesses() }
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// What Activity Monitor calls memory used: app memory, wired and compressed.
    private static func memoryInUse() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Purgeable pages are counted among the internal ones, but the two are read at slightly different moments.
        let internalPages = UInt64(stats.internal_page_count)
        let pages = internalPages - min(UInt64(stats.purgeable_count), internalPages) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private func listProcesses() {
        listing = true
        DispatchQueue.global(qos: .utility).async {
            let list = Self.ps()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.listing = false
                    if let list { self.top = list }
                }
            }
        }
    }

    /// The five processes using the most CPU, from ps.
    nonisolated private static func ps() -> [Process]? {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let own = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(8).compactMap { line -> Process? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), pid != own, let cpu = Double(fields[1]), let rss = UInt64(fields[2]) else { return nil }
            return Process(pid: pid, name: String(fields[3]), cpu: cpu, memory: rss * 1024)
        }.prefix(5).map { $0 }
    }

    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(value) / 1_048_576)
    }
}

struct SystemView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            meter("CPU", value: monitor.cpu, detail: "\(Int((monitor.cpu * 100).rounded()))%", color: Color(red: 0.5, green: 0.47, blue: 0.87))
            meter("内存", value: Double(monitor.memoryUsed) / Double(monitor.memoryTotal),
                  detail: "\(SystemMonitor.bytes(monitor.memoryUsed)) / \(SystemMonitor.bytes(monitor.memoryTotal))", color: Color(red: 0.11, green: 0.62, blue: 0.46))
            VStack(alignment: .leading, spacing: 5) {
                Text("占用 CPU 最多").font(.system(size: 10.5)).foregroundStyle(Palette.dim)
                if monitor.top.isEmpty {
                    Text("读取中…").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                ForEach(monitor.top) { process in
                    HStack(spacing: 8) {
                        if let harness = harness(for: process.pid) { HarnessIcon(harness: harness, size: 12) }
                        Text(name(process)).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", process.cpu)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 48, alignment: .trailing)
                        Text(SystemMonitor.bytes(process.memory)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear { monitor.watchingProcesses = true }
        .onDisappear { monitor.watchingProcesses = false }
    }

    /// Agent CLIs are named after their CLI rather than "node".
    private func name(_ process: SystemMonitor.Process) -> String {
        guard let harness = harness(for: process.pid) else { return process.name }
        return "\(process.name)（\(harness.displayName)）"
    }

    private func harness(for pid: Int32) -> BangsCore.Harness? {
        store.sessions.first { $0.pid == pid }?.harness
    }

    private func meter(_ title: String, value: Double, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.wash(0.08))
                    Capsule().fill(color).frame(width: max(4, proxy.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.5), value: value)
        }
    }
}
