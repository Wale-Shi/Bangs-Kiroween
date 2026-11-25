import Foundation

/// Adds and removes Bangs' hooks for one CLI. In settings files shared with other tools, only Bangs' entries are
/// touched (recognised by the hook binary's name) and the file is backed up before each write; where the CLI reads a
/// directory of hook files or plugins, Bangs keeps a file of its own.
public struct HookInstaller {
    public static let marker = "bangs-hook"
    /// A permission request waits for your answer in the notch; past this the CLI falls back to its own prompt.
    public static let permissionTimeout = 1800
    public static let eventTimeout = 5

    public let harness: Harness
    public let hookBinary: String
    public let user: URL

    public init(harness: Harness, hookBinary: String, user: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.harness = harness
        self.hookBinary = hookBinary
        self.user = user
    }

    public enum State: Equatable { case notDetected, notInstalled, installed, outdated }

    /// The file Bangs writes for this CLI.
    public var file: URL {
        let home = harness.home(in: user)
        switch harness.layout {
        case .claudeStyle(let name, _):
            if harness == .droid, FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks.json").path) { return home.appendingPathComponent("hooks.json") }
            return home.appendingPathComponent(name)
        case .copilotFile: return home.appendingPathComponent("hooks/bangs.json")
        case .kiroFile: return home.appendingPathComponent("hooks/bangs.json")
        case .opencodePlugin: return home.appendingPathComponent("plugins/bangs.js")
        case .piExtension: return home.appendingPathComponent("extensions/bangs.ts")
        case .hermesPlugin: return home.appendingPathComponent("plugins/\(HermesPlugin.name)/__init__.py")
        case .viaClaude: return Harness.claude.hooksFile(in: user)
        }
    }

    var quotedBinary: String { "'\(hookBinary.replacingOccurrences(of: "'", with: #"'\''"#))'" }
    func command(_ native: String) -> String { "\(quotedBinary) \(harness.rawValue) \(native)" }
    func timeout(for event: HookEvent) -> Int { event == .permissionRequest ? Self.permissionTimeout : Self.eventTimeout }

    public func state() -> State {
        if harness.layout == .viaClaude {
            guard FileManager.default.fileExists(atPath: harness.home(in: user).path) else { return .notDetected }
            return HookInstaller(harness: .claude, hookBinary: hookBinary, user: user).state()
        }
        guard FileManager.default.fileExists(atPath: harness.home(in: user).path) else { return .notDetected }
        switch harness.layout {
        case .claudeStyle(_, let milliseconds):
            guard let root = try? read() else { return .notInstalled }
            let hooks = hooksObject(root)
            let ours = Self.commands(in: hooks).filter { $0.contains(Self.marker) }
            if ours.isEmpty { return .notInstalled }
            let complete = harness.events.allSatisfy { native, event in
                Self.handlers(in: hooks, event: native).contains {
                    ($0["command"] as? String) == command(native) && ($0["timeout"] as? Int) == timeout(for: event) * (milliseconds ? 1000 : 1)
                }
            }
            return complete && ours.count == harness.events.count ? .installed : .outdated
        case .hermesPlugin:
            guard let existing = try? String(contentsOf: file, encoding: .utf8) else { return .notInstalled }
            let manifest = try? String(contentsOf: hermesManifest, encoding: .utf8)
            return existing == ownFile() && manifest == HermesPlugin.manifest && hermesEnabled ? .installed : .outdated
        default:
            guard let existing = try? String(contentsOf: file, encoding: .utf8) else { return .notInstalled }
            return existing == ownFile() ? .installed : .outdated
        }
    }

    /// Installed once and gone stale since: Bangs moved (every event would run a command that is no longer there) or
    /// was updated. A Hermes plugin you switched off yourself also reads as outdated, and stays off.
    public var needsRepair: Bool {
        state() == .outdated && (harness.layout != .hermesPlugin || hermesEnabled)
    }

    /// Reinstalls the hooks that need repair, for each CLI in turn (Cursor's live in Claude Code's file, so the state is
    /// read again once that is done). CLIs whose hooks are current or were never installed are not touched, so a
    /// shared settings file is not rewritten, nor backed up again, on every launch. Returns the CLIs repaired.
    @discardableResult
    public static func repair(hookBinary: String, user: URL = FileManager.default.homeDirectoryForCurrentUser,
                              failed: (Harness, Error) -> Void = { _, _ in }) -> [Harness] {
        Harness.allCases.filter { harness in
            let installer = HookInstaller(harness: harness, hookBinary: hookBinary, user: user)
            guard installer.needsRepair else { return false }
            do { try installer.install(); return true } catch { failed(harness, error); return false }
        }
    }

    public func install() throws {
        switch harness.layout {
        case .claudeStyle(_, let milliseconds):
            var root = Self.removing(from: try read(), wrapped: wrapped)
            var hooks = hooksObject(root)
            for (native, event) in harness.events {
                var groups = hooks[native] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": command(native), "timeout": timeout(for: event) * (milliseconds ? 1000 : 1)]]])
                hooks[native] = groups
            }
            if wrapped { root["hooks"] = hooks } else { root = root.merging(hooks) { $1 } }
            try write(root)
        case .copilotFile, .kiroFile, .opencodePlugin, .piExtension:
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ownFile().utf8).write(to: file, options: .atomic)
        case .hermesPlugin:
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(HermesPlugin.manifest.utf8).write(to: hermesManifest, options: .atomic)
            try Data(ownFile().utf8).write(to: file, options: .atomic)
            // Hermes edits its own config and has its running gateway reload its plugins; switching an enabled plugin
            // off and on again is how an update reaches the gateway.
            let home = harness.home(in: user)
            if hermesEnabled { try HermesPlugin.run("disable", home: home, user: user) }
            try HermesPlugin.run("enable", home: home, user: user)
        case .viaClaude:
            try HookInstaller(harness: .claude, hookBinary: hookBinary, user: user).install()
        }
    }

    public func uninstall() throws {
        switch harness.layout {
        case .claudeStyle:
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            try write(Self.removing(from: try read(), wrapped: wrapped))
        case .copilotFile, .kiroFile, .opencodePlugin, .piExtension:
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        case .hermesPlugin:
            if hermesEnabled { try HermesPlugin.run("disable", home: harness.home(in: user), user: user) }
            let directory = file.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        case .viaClaude:
            try HookInstaller(harness: .claude, hookBinary: hookBinary, user: user).uninstall()
        }
    }

    var hermesManifest: URL { file.deletingLastPathComponent().appendingPathComponent("plugin.yaml") }

    var hermesEnabled: Bool {
        let config = (try? String(contentsOf: harness.home(in: user).appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        return HermesPlugin.isEnabled(config: config)
    }

    // MARK: Settings files shared with other tools

    /// Droid's standalone hooks.json keys events at the top level; every other file nests them under "hooks".
    var wrapped: Bool { !(harness == .droid && file.lastPathComponent == "hooks.json") }

    func hooksObject(_ root: [String: Any]) -> [String: Any] { wrapped ? root["hooks"] as? [String: Any] ?? [:] : root }

    /// The settings without any of Bangs' hook commands; groups and events left empty by that are dropped.
    public static func removing(from root: [String: Any], wrapped: Bool = true) -> [String: Any] {
        guard let hooks = wrapped ? root["hooks"] as? [String: Any] : root else { return root }
        var cleaned = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let rest = handlers.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if rest.count == handlers.count { return group }
                if rest.isEmpty { return nil }
                var copy = group
                copy["hooks"] = rest
                return copy
            }
            cleaned[event] = kept.isEmpty ? nil : kept
        }
        guard wrapped else { return cleaned }
        var copy = root
        copy["hooks"] = cleaned.isEmpty ? nil : cleaned
        return copy
    }

    static func handlers(in hooks: [String: Any], event: String? = nil) -> [[String: Any]] {
        let groups = event.map { hooks[$0] as? [[String: Any]] ?? [] } ?? hooks.values.flatMap { $0 as? [[String: Any]] ?? [] }
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    static func commands(in hooks: [String: Any]) -> [String] { handlers(in: hooks).compactMap { $0["command"] as? String } }

    func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        return root
    }

    func write(_ root: [String: Any]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: file.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let backup = file.appendingPathExtension("bangs-\(stamp).bak")
            // A backup from the same second already holds this file's state from before our change.
            if !manager.fileExists(atPath: backup.path) { try manager.copyItem(at: file, to: backup) }
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    // MARK: Files Bangs owns

    func ownFile() -> String {
        switch harness.layout {
        case .copilotFile:
            let hooks = Dictionary(uniqueKeysWithValues: harness.events.map { native, event in
                (native, [["type": "command", "bash": command(native), "timeoutSec": timeout(for: event)]])
            })
            return json(["version": 1, "hooks": hooks])
        case .kiroFile:
            let hooks = harness.events.map { native, event in
                ["name": "bangs-\(native)", "trigger": native, "action": ["type": "command", "command": command(native)], "timeout": timeout(for: event), "enabled": true] as [String: Any]
            }
            return json(["version": "v1", "hooks": hooks])
        case .opencodePlugin:
            return OpenCodePlugin.source(hookBinary: hookBinary)
        case .piExtension:
            return PiExtension.source(hookBinary: hookBinary, harness: harness)
        case .hermesPlugin:
            return HermesPlugin.source
        default:
            return ""
        }
    }

    private func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

extension Harness {
    /// Claude Code's user settings, which Cursor also reads.
    func hooksFile(in user: URL) -> URL { home(in: user).appendingPathComponent("settings.json") }
}
