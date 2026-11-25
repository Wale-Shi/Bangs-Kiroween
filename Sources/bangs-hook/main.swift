import BangsCore
import Darwin
import Foundation

// Runs as a CLI hook: `bangs-hook <cli> [<event>]`. Forwards the event to Bangs and, for a permission request,
// prints the user's decision. Whatever goes wrong (app not running, bad input), it exits 0 silently so the CLI
// carries on as usual.

let arguments = CommandLine.arguments
guard arguments.count > 1, let installed = Harness(rawValue: arguments[1]) else { exit(0) }
let input = FileHandle.standardInput.readDataToEndOfFile()
let environment = ProcessInfo.processInfo.environment

// `bangs-hook claude statusline`: Claude Code's status line, relayed (see StatusLineRelay). What Claude Code sends goes
// to Bangs without waiting for it, then the status line you had before runs on the same input and prints as it did.
if installed == .claude, arguments.count > 2, arguments[2] == "statusline" {
    if environment["BANGS_IGNORE"] == nil, environment["MUSTER_AGENT"] == nil,
       let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
       let data = try? HookEnvelope(harness: .claude, native: StatusLineRelay.event, pid: Processes.hookOwner(), payload: payload).encoded(),
       let fd = UnixSocket.connect(to: Wire.socketPath) {
        _ = UnixSocket.write(fd, data)
        close(fd)
    }
    guard let command = StatusLineRelay.originalCommand() else { exit(0) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    process.standardInput = stdin
    // Its output and errors go straight to Claude Code, as if it ran on its own.
    guard (try? process.run()) != nil else { exit(0) }
    // A status line that never reads its input must not take this process down with it.
    signal(SIGPIPE, SIG_IGN)
    try? stdin.fileHandleForWriting.write(contentsOf: input)
    try? stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    exit(process.terminationReason == .exit ? process.terminationStatus : 0)
}

// Tools that run agents on your behalf can keep their sessions out of Bangs: BANGS_IGNORE, or Muster's MUSTER_AGENT.
if environment["BANGS_IGNORE"] != nil || environment["MUSTER_AGENT"] != nil { exit(0) }

guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
let harness = Harness.resolve(installed, environment: environment)
let native = arguments.count > 2 ? arguments[2] : payload["hook_event_name"] as? String ?? ""
let envelope = HookEnvelope(harness: harness, native: native, pid: Processes.hookOwner(), payload: payload)
guard envelope.event != nil, let fd = UnixSocket.connect(to: Wire.socketPath), let data = try? envelope.encoded(), UnixSocket.write(fd, data) else { exit(0) }

if envelope.event == .permissionRequest, let line = UnixSocket.readLine(fd), let reply = PermissionReply(line: line),
   let output = harness.permissionOutput(reply, input: envelope.toolInput) {
    FileHandle.standardOutput.write(Data((output + "\n").utf8))
}
close(fd)
exit(0)
