import AppKit
import BangsCore

/// The app (Terminal, iTerm, Ghostty, VS Code…) a CLI session runs in: the nearest ancestor that is a regular app.
enum Terminal {
    static func app(for pid: pid_t) -> NSRunningApplication? {
        for ancestor in Processes.ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular { return app }
        }
        return nil
    }

    static func isFrontmost(for pid: pid_t) -> Bool {
        guard let app = app(for: pid) else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Brings the session's terminal forward. Returns false when no app could be found.
    @discardableResult
    static func focus(pid: pid_t) -> Bool {
        guard let app = app(for: pid) else { return false }
        return app.activate()
    }

    /// Runs `command` in a new window of your default terminal (whatever opens .command files, Terminal unless you
    /// changed it), in a login shell so the CLI is on the PATH, leaving the shell open afterwards. No permission needed.
    @discardableResult
    static func run(_ command: String) -> Bool {
        let folder = FileManager.default.temporaryDirectory
        // Yesterday's scripts go.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("bangs-resume-") {
            let url = folder.appendingPathComponent(name)
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, Date().timeIntervalSince(date) > 86_400 {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let script = folder.appendingPathComponent("bangs-resume-\(UUID().uuidString.prefix(8)).command")
        let body = "#!/bin/zsh -il\nclear\n\(command)\nexec /bin/zsh -il\n"
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)) != nil else { return false }
        return NSWorkspace.shared.open(script)
    }
}
