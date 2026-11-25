import Foundation

/// OpenCode has plugins rather than command hooks. This plugin translates its events into the Claude-style events
/// `bangs-hook` understands. OpenCode's permission prompts stay in OpenCode; Bangs only says that one is waiting.
enum OpenCodePlugin {
    static func source(hookBinary: String) -> String {
        let binary = String(decoding: try! JSONSerialization.data(withJSONObject: [hookBinary], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast()
        return """
        // Bangs (https://github.com/Wale-Shi/Bangs): shows this OpenCode session in the MacBook notch.
        // Written by Bangs; remove it from Bangs' settings. Does nothing when Bangs is not running.
        import { spawn } from "node:child_process";

        const HOOK = \(binary);

        function send(event, payload) {
          if (process.env.BANGS_IGNORE || process.env.MUSTER_AGENT) return;
          try {
            const child = spawn(HOOK, ["opencode", event], { stdio: ["pipe", "ignore", "ignore"] });
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ hook_event_name: event, ...payload }));
          } catch {}
        }

        export const BangsPlugin = async ({ directory }) => {
          const busy = new Set();
          return {
            "tool.execute.before": async (input, output) => {
              send("PreToolUse", { session_id: input.sessionID, cwd: directory, tool_name: input.tool, tool_input: output?.args ?? {} });
            },
            "tool.execute.after": async (input) => {
              send("PostToolUse", { session_id: input.sessionID, cwd: directory, tool_name: input.tool });
            },
            event: async ({ event }) => {
              const p = event?.properties ?? {};
              switch (event?.type) {
                case "session.created":
                  if (!p.info?.parentID) send("SessionStart", { session_id: p.info?.id, cwd: p.info?.directory ?? directory });
                  break;
                case "session.deleted":
                  send("SessionEnd", { session_id: p.info?.id, cwd: directory });
                  break;
                case "session.status":
                  if (p.status?.type === "busy" && !busy.has(p.sessionID)) {
                    busy.add(p.sessionID);
                    send("UserPromptSubmit", { session_id: p.sessionID, cwd: directory });
                  }
                  break;
                case "session.idle":
                  busy.delete(p.sessionID);
                  send("Stop", { session_id: p.sessionID, cwd: directory });
                  break;
                case "permission.asked":
                case "permission.updated":
                  send("Notification", { session_id: p.sessionID, cwd: directory, notification_type: "permission_prompt", message: p.title ?? p.permission ?? "" });
                  break;
                case "permission.replied":
                  send("PostToolUse", { session_id: p.sessionID, cwd: directory, tool_name: "" });
                  break;
              }
            },
          };
        };

        """
    }
}
