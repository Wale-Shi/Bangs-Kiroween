import AppKit
import BangsCore
import Combine
import notify

/// The charge limit as Bangs sees it: the battery, whether charging is held, and the root helper that holds it (see
/// ChargeLimit). Bangs never runs as root: it installs the helper once, with your password, and then only tells it the
/// limit.
@MainActor
final class ChargeLimiter: ObservableObject {
    enum Support { case noBattery, unsupported, supported }
    enum HelperState: Equatable { case missing, outdated, installed }

    let support: Support
    /// How this Mac controls charging, when it can.
    let mode: ChargeLimit.Switch?
    @Published private(set) var battery: Battery?
    @Published private(set) var holding = false
    @Published private(set) var helper: HelperState = .missing
    /// Installing or removing the helper, which waits on your password.
    @Published private(set) var busy = false
    @Published var error: String?

    private let preferences: Preferences
    private let smc: SMC?
    private var subscriptions: Set<AnyCancellable> = []
    /// The installed helper's answer to --version, for the file as it was then: asking spawns it, and the settings
    /// window refreshes every few seconds.
    private var helperChecked: (file: HelperFile, state: HelperState)?

    init(preferences: Preferences) {
        self.preferences = preferences
        let smc = SMC()
        self.smc = smc
        mode = smc.flatMap(ChargeLimit.Switch.init)
        support = Battery.current() == nil ? .noBattery : mode == nil ? .unsupported : .supported
        refresh()
        guard support == .supported else { return }
        // The helper reads the limit from a file whatever happens to Bangs, so it is kept up to date from launch.
        preferences.$chargeLimitOn.combineLatest(preferences.$chargeLimit).dropFirst().sink { [weak self] on, limit in
            self?.publish(on: on, limit: limit)
        }.store(in: &subscriptions)
        publish(on: preferences.chargeLimitOn, limit: preferences.chargeLimit)
    }

    /// The helper bundled with this Bangs.
    private static var bundledHelper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bangs-charge").path
    }

    func refresh() {
        battery = Battery.current()
        if let smc, let mode {
            // The firmware limit is on all the time; it holds when the adapter is in and the battery does not charge.
            holding = mode.holding(smc) && (!mode.keepsLimit || (battery?.onPower == true && battery?.charging == false))
        }
        helper = installedHelper()
    }

    /// What tells one helper file from another without running it.
    struct HelperFile: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value, let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size
            self.modified = modified
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    private func installedHelper() -> HelperState {
        guard FileManager.default.isExecutableFile(atPath: ChargeLimit.helperPath),
              FileManager.default.fileExists(atPath: ChargeLimit.daemonPlistPath), let file = HelperFile(path: ChargeLimit.helperPath) else { return .missing }
        if let checked = helperChecked, checked.file == file { return checked.state }
        let state = Self.version(of: ChargeLimit.helperPath)
        helperChecked = (file, state)
        return state
    }

    private static func version(of path: String) -> HelperState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return .outdated }
        process.waitUntilExit()
        let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(version.trimmingCharacters(in: .whitespacesAndNewlines)) == ChargeLimit.helperVersion ? .installed : .outdated
    }

    /// Turning the limit on: installs the helper first when it is missing or older than this Bangs.
    func turnOn() {
        guard helper != .installed else { preferences.chargeLimitOn = true; return }
        install { [weak self] ok in if ok { self?.preferences.chargeLimitOn = true } }
    }

    private func publish(on: Bool, limit: Int) {
        let url = URL(fileURLWithPath: ChargeLimit.settingPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try Data((on ? "\(limit)" : "off").utf8).write(to: url, options: .atomic)
        } catch {
            Log.write("charge limit: could not write the setting: \(error.localizedDescription)")
        }
        notify_post(ChargeLimit.changedNotification)
        // The helper acts at once; read back what it did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func install(then done: @escaping (Bool) -> Void = { _ in }) {
        let plist: [String: Any] = [
            "Label": ChargeLimit.label,
            "ProgramArguments": [ChargeLimit.helperPath],
            "RunAtLoad": true,
            // Restarted if it crashes; not when it quits on a Mac it cannot control.
            "KeepAlive": ["SuccessfulExit": false],
            "StandardErrorPath": "/Library/Logs/Bangs-charge.log",
        ]
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(ChargeLimit.label).plist")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: staged)) != nil else { error = "无法准备充电助手"; done(false); return }
        let helper = Self.quote(ChargeLimit.helperPath), daemon = Self.quote(ChargeLimit.daemonPlistPath)
        run([
            "launchctl bootout system/\(ChargeLimit.label) 2>/dev/null || true",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(Self.quote(Self.bundledHelper)) \(helper)",
            "chown root:wheel \(helper)",
            "chmod 755 \(helper)",
            "cp \(Self.quote(staged.path)) \(daemon)",
            "chown root:wheel \(daemon)",
            "chmod 644 \(daemon)",
            "launchctl bootstrap system \(daemon)",
        ], done: done)
    }

    /// Removes the helper; it lets the battery charge fully again as it stops.
    func uninstall() {
        preferences.chargeLimitOn = false
        run([
            "launchctl bootout system/\(ChargeLimit.label) 2>/dev/null || true",
            "rm -f \(Self.quote(ChargeLimit.daemonPlistPath)) \(Self.quote(ChargeLimit.helperPath))",
        ]) { _ in }
    }

    /// Runs shell commands as root, after macOS asks for an administrator's password.
    private func run(_ commands: [String], done: @escaping (Bool) -> Void) {
        busy = true
        error = nil
        let script = commands.joined(separator: " && ")
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", apple]
            let errors = Pipe()
            process.standardError = errors
            let ok: Bool, message: String
            do {
                try process.run()
                process.waitUntilExit()
                ok = process.terminationStatus == 0
                message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            } catch {
                ok = false
                message = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                // Installed or removed: ask the helper afresh even if its file looks the same.
                self.helperChecked = nil
                // Cancelling the password dialog is not an error worth showing (-128).
                if !ok && !message.contains("-128") {
                    self.error = "没有完成：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
                    Log.write("charge limit: \(message)")
                }
                self.refresh()
                done(ok)
            }
        }
    }

    private static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
