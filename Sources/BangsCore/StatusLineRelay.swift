import Foundation

/// Claude Code tells only its status line command how much of the plan's limits is used. With the relay on, that command
/// is `bangs-hook claude statusline`: it passes what Claude Code sends on to Bangs, then runs the status line you had
/// before (kept in Bangs' own folder) with the same input, so your status line looks as it did. Turning it off puts
/// yours back. Opt-in: it is the one setting of Claude Code's that Bangs replaces rather than adds to.
public struct StatusLineRelay {
    /// The event name the relay sends; no CLI has one like it.
    public static let event = "StatusLine"

    public let hookBinary: String
    public let user: URL

    public init(hookBinary: String, user: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.hookBinary = hookBinary
        self.user = user
    }

    public enum State: Equatable { case notDetected, off, on, outdated }

    var installer: HookInstaller { HookInstaller(harness: .claude, hookBinary: hookBinary, user: user) }
    public var settings: URL { installer.file }
    /// Your own status line, as it was before the relay took its place.
    var saved: URL { Self.savedFile(user: user) }

    static func savedFile(user: URL) -> URL {
        // Wire.directory, but under `user`, so tests keep to their own folder.
        user.appendingPathComponent(".bangs/claude-statusline.json")
    }

    var command: String { "\(installer.quotedBinary) claude statusline" }

    public func state() -> State {
        guard FileManager.default.fileExists(atPath: Harness.claude.home(in: user).path) else { return .notDetected }
        guard let current = ((try? installer.read())?["statusLine"] as? [String: Any])?["command"] as? String,
              current.contains(HookInstaller.marker) else { return .off }
        return current == command ? .on : .outdated
    }

    public func install() throws {
        var root = try installer.read()
        let current = root["statusLine"] as? [String: Any]
        let ours = (current?["command"] as? String)?.contains(HookInstaller.marker) == true
        if !ours {
            try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: current ?? [:], options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            try data.write(to: saved, options: .atomic)
        }
        var line: [String: Any] = ["type": "command", "command": command]
        if let padding = current?["padding"] { line["padding"] = padding }
        root["statusLine"] = line
        try installer.write(root)
    }

    public func uninstall() throws {
        var root = try installer.read()
        if let current = (root["statusLine"] as? [String: Any])?["command"] as? String, current.contains(HookInstaller.marker) {
            let original = Self.original(user: user)
            root["statusLine"] = original.isEmpty ? nil : original
            try installer.write(root)
        }
        try? FileManager.default.removeItem(at: saved)
    }

    /// Bangs moved or was updated since the relay was turned on: it points at a hook binary that is not there.
    @discardableResult
    public func repair() throws -> Bool {
        guard state() == .outdated else { return false }
        try install()
        return true
    }

    /// The status line you had before, as Claude Code's settings held it; empty when there was none.
    public static func original(user: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any] {
        guard let data = try? Data(contentsOf: savedFile(user: user)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The command of the status line you had before, which the relay runs in its place.
    public static func originalCommand(user: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let command = original(user: user)["command"] as? String, !command.isEmpty, !command.contains(HookInstaller.marker) else { return nil }
        return command
    }
}
