import Foundation

/// Hermes takes Python plugins rather than command hooks, and runs every turn in its long-lived gateway rather than in
/// the terminal: this plugin reports the sessions you run in a terminal straight to Bangs' socket, tied to that
/// terminal's `hermes` process through the breadcrumb Hermes keeps per terminal. Hermes' approval hooks only observe,
/// so a prompt shows as waiting in the terminal.
public enum HermesPlugin {
    public static let name = "bangs"

    static let manifest = """
    name: bangs
    version: "1.0"
    description: Show the Hermes sessions you run in a terminal in the MacBook notch (Bangs)

    """

    static let source = #"""
    """Bangs (https://github.com/Wale-Shi/Bangs): shows the Hermes sessions you run in a terminal in the MacBook notch.

    Written by Bangs; remove it from Bangs' settings. Does nothing when Bangs is not running. Every report is sent from
    a background thread, so a slow or missing Bangs never holds up a turn or a tool call.
    """

    from __future__ import annotations

    import json
    import os
    import queue
    import socket
    import subprocess
    import threading
    import time
    from pathlib import Path

    # Sessions in a terminal. The gateway also runs messaging platforms and editor (ACP) sessions.
    _INTERACTIVE = {"cli", "tui"}
    _SOCKET = os.environ.get("BANGS_SOCKET") or os.path.expanduser("~/.bangs/bangs.sock")

    _outbox: queue.Queue = queue.Queue(maxsize=1000)
    _lock = threading.Lock()
    _watched: set = set()
    _busy: set = set()
    _replies: dict = {}
    _places: dict = {}
    _worker = None


    def _home() -> Path:
        try:
            from hermes_constants import get_hermes_home
            return Path(get_hermes_home())
        except Exception:
            return Path(os.environ.get("HERMES_HOME") or "~/.hermes").expanduser()


    def _cli_process(terminal: str) -> int:
        """The hermes process on a terminal named like tty-dev-ttys002."""
        if not terminal.startswith("tty-dev-"):
            return 0
        try:
            out = subprocess.run(["/bin/ps", "-t", terminal[len("tty-dev-"):], "-o", "pid=,command="],
                                 capture_output=True, text=True, timeout=2).stdout
        except Exception:
            return 0
        for line in out.splitlines():
            pid, _, command = line.strip().partition(" ")
            if "hermes" in command and " gateway" not in command and pid.isdigit():
                return int(pid)
        return 0


    def _locate(session_id: str):
        """The session's terminal process and folder. Turns run in the gateway, so until the terminal is found the
        session belongs to the gateway, and is looked for again a few seconds later."""
        place = _places.get(session_id)
        now = time.monotonic()
        if place and (place[0] != os.getpid() or now - place[2] < 5):
            return place[0], place[1]
        pid, cwd = os.getpid(), ""
        try:
            for entry in (_home() / "terminal-sessions").iterdir():
                try:
                    crumb = json.loads(entry.read_text(encoding="utf-8-sig"))
                except Exception:
                    continue
                if not isinstance(crumb, dict) or crumb.get("session_id") != session_id:
                    continue
                cwd = str(crumb.get("cwd") or "")
                pid = _cli_process(entry.name) or pid
                break
        except OSError:
            pass
        _places[session_id] = (pid, cwd, now)
        return pid, cwd


    def _deliver():
        while True:
            event, session_id, payload = _outbox.get()
            try:
                if not os.path.exists(_SOCKET):
                    continue
                pid, cwd = _locate(session_id)
                body = {"hook_event_name": event, "session_id": session_id, "cwd": cwd, **payload}
                line = json.dumps({"harness": "hermes", "event": event, "pid": pid, "payload": body}, default=str) + "\n"
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                    conn.settimeout(1)
                    conn.connect(_SOCKET)
                    conn.sendall(line.encode())
            except Exception:
                pass


    def _send(event: str, session_id, **payload) -> None:
        global _worker
        if session_id not in _watched:
            return
        try:
            if _worker is None:
                _worker = threading.Thread(target=_deliver, name="bangs", daemon=True)
                _worker.start()
            _outbox.put_nowait((event, session_id, payload))
        except Exception:
            pass


    def _watch(session_id, platform) -> bool:
        if not session_id or platform not in _INTERACTIVE:
            return False
        with _lock:
            _watched.add(session_id)
        return True


    def _text(message) -> str:
        if isinstance(message, str):
            return message
        if isinstance(message, list):
            return "\n".join(part.get("text", "") for part in message if isinstance(part, dict) and part.get("type") == "text")
        return ""


    def _session_of(kwargs) -> str:
        return kwargs.get("session_id") or kwargs.get("task_id") or ""


    def _on_session_start(**kwargs):
        try:
            if _watch(kwargs.get("session_id"), kwargs.get("platform")):
                _send("SessionStart", kwargs["session_id"])
        except Exception:
            pass


    def _on_prompt(**kwargs):
        try:
            session_id = kwargs.get("session_id")
            if _watch(session_id, kwargs.get("platform")):
                with _lock:
                    _busy.add(session_id)
                _send("UserPromptSubmit", session_id, prompt=_text(kwargs.get("user_message")))
        except Exception:
            pass
        return None


    def _on_tool(**kwargs):
        try:
            args = kwargs.get("args")
            _send("PreToolUse", _session_of(kwargs), tool_name=kwargs.get("tool_name") or "", tool_input=args if isinstance(args, dict) else {})
        except Exception:
            pass
        return None


    def _on_tool_done(**kwargs):
        try:
            _send("PostToolUse", _session_of(kwargs), tool_name=kwargs.get("tool_name") or "")
        except Exception:
            pass


    def _on_reply(**kwargs):
        try:
            if kwargs.get("session_id") in _watched:
                _replies[kwargs["session_id"]] = _text(kwargs.get("assistant_response"))
        except Exception:
            pass


    def _on_turn_end(**kwargs):
        try:
            session_id = kwargs.get("session_id")
            with _lock:
                _busy.discard(session_id)
            _send("Stop", session_id, last_assistant_message=_replies.pop(session_id, ""))
        except Exception:
            pass


    def _on_session_finalize(**kwargs):
        try:
            session_id = kwargs.get("session_id")
            _send("SessionEnd", session_id)
            with _lock:
                _watched.discard(session_id)
                _busy.discard(session_id)
            _replies.pop(session_id, None)
        except Exception:
            pass


    def _approval_session(kwargs) -> str:
        """Approval hooks name a session key; when that is not a session seen here, the one mid-turn."""
        for key in (kwargs.get("session_id"), kwargs.get("session_key")):
            if key in _watched:
                return key
        with _lock:
            return next(iter(_busy)) if len(_busy) == 1 else ""


    def _on_approval(**kwargs):
        try:
            # Smart approval: an auxiliary model decides, nobody is asked.
            if kwargs.get("surface") == "smart":
                return
            message = kwargs.get("command") or kwargs.get("description") or ""
            _send("Notification", _approval_session(kwargs), notification_type="permission_prompt", message=message)
        except Exception:
            pass


    def _on_approval_done(**kwargs):
        try:
            _send("PostToolUse", _approval_session(kwargs), tool_name="")
        except Exception:
            pass


    def register(ctx):
        ctx.register_hook("on_session_start", _on_session_start)
        ctx.register_hook("pre_llm_call", _on_prompt)
        ctx.register_hook("pre_tool_call", _on_tool)
        ctx.register_hook("post_tool_call", _on_tool_done)
        ctx.register_hook("post_llm_call", _on_reply)
        ctx.register_hook("on_session_end", _on_turn_end)
        ctx.register_hook("on_session_finalize", _on_session_finalize)
        ctx.register_hook("pre_approval_request", _on_approval)
        ctx.register_hook("post_approval_response", _on_approval_done)

    """#

    /// Whether `plugins.enabled` in Hermes' config.yaml lists Bangs (block or flow style).
    public static func isEnabled(config: String) -> Bool {
        var inPlugins = false, inEnabled = false
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: " #").first ?? raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inPlugins = trimmed.hasPrefix("plugins:")
                inEnabled = false
                continue
            }
            guard inPlugins else { continue }
            if trimmed.hasPrefix("enabled:") {
                let rest = trimmed.dropFirst("enabled:".count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") {
                    let items = rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    if items.contains(where: { unquoted($0) == name }) { return true }
                    inEnabled = false
                } else {
                    inEnabled = true
                }
                continue
            }
            if inEnabled, trimmed.hasPrefix("-") {
                if unquoted(trimmed.dropFirst()) == name { return true }
            } else if inEnabled, !trimmed.hasPrefix("-") {
                inEnabled = false
            }
        }
        return false
    }

    private static func unquoted<S: StringProtocol>(_ text: S) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Runs `hermes plugins <verb> bangs` against the Hermes home given, so Hermes edits its own config and its
    /// running gateway reloads its plugins.
    static func run(_ verb: String, home: URL, user: URL) throws {
        let candidates = [user.appendingPathComponent(".local/bin/hermes").path, NSHomeDirectory() + "/.local/bin/hermes",
                          "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes", home.appendingPathComponent("hermes-agent/hermes").path]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure("找不到 hermes 命令。请在终端运行 hermes plugins \(verb) \(name)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["plugins", verb, name]
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = home.path
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", user.appendingPathComponent(".local/bin").path].joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("hermes plugins \(verb) \(name) 失败：\(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))")
        }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
