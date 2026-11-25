import Foundation

/// pi (and its fork omp) take TypeScript extensions rather than command hooks. This extension reports the session's
/// lifecycle to `bangs-hook` in Claude-style events. pi does not ask before running tools, so it never blocks anything.
enum PiExtension {
    static func source(hookBinary: String, harness: Harness) -> String {
        let binary = String(decoding: try! JSONSerialization.data(withJSONObject: [hookBinary], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast()
        return """
        // Bangs (https://github.com/Wale-Shi/Bangs): shows this \(harness.displayName) session in the MacBook notch.
        // Written by Bangs; remove it from Bangs' settings. Does nothing when Bangs is not running.
        import { spawn } from "node:child_process";

        const HOOK = \(binary);
        // omp can also load pi's extensions: report under whichever agent is actually running, once per process.
        const AGENT = /(^|\\/)omp([^/]*)$|\\/omp\\//.test(process.execPath) ? "omp" : "\(harness.rawValue)";
        const LOADED = Symbol.for("bangs.extension");

        function send(event: string, payload: Record<string, unknown>) {
          if (process.env.BANGS_IGNORE || process.env.MUSTER_AGENT) return;
          try {
            const child = spawn(HOOK, [AGENT, event], { stdio: ["pipe", "ignore", "ignore"] });
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ hook_event_name: event, ...payload }));
          } catch {}
        }

        function session(ctx: any) {
          let id: string | undefined, file: string | undefined;
          try { id = ctx?.sessionManager?.getSessionId?.(); } catch {}
          try { file = ctx?.sessionManager?.getSessionFile?.(); } catch {}
          return { session_id: id || `pid-${process.pid}`, cwd: ctx?.cwd ?? process.cwd(), ...(file ? { transcript_path: file } : {}) };
        }

        function lastAssistantText(messages: any[] | undefined): string | undefined {
          for (const message of [...(messages ?? [])].reverse()) {
            if (message?.role !== "assistant") continue;
            const content = message.content;
            if (typeof content === "string") return content;
            const text = (Array.isArray(content) ? content : []).filter((part: any) => part?.type === "text").map((part: any) => part.text).join("\\n");
            if (text) return text;
          }
          return undefined;
        }

        export default function (pi: any) {
          const g = globalThis as any;
          if (g[LOADED]) return;
          g[LOADED] = true;
          let interactive = false;
          let last: string | undefined;
          let ending: ReturnType<typeof setTimeout> | undefined;

          // The end of a turn. pi says so with agent_settled; omp has no such event, so a turn also ends once agent_end
          // has gone 1.5 s without a retry or new input starting another run.
          function stop(ctx: any) {
            if (ending) { clearTimeout(ending); ending = undefined; }
            if (!interactive) return;
            send("Stop", { ...session(ctx), last_assistant_message: last ?? "" });
            last = undefined;
          }
          function busy() {
            if (ending) { clearTimeout(ending); ending = undefined; }
          }

          // Only interactive sessions: print, JSON and RPC runs are scripts, not something to watch.
          pi.on("session_start", (_event: any, ctx: any) => {
            interactive = ctx?.mode === "tui";
            if (interactive) send("SessionStart", session(ctx));
          });
          pi.on("input", (event: any, ctx: any) => {
            busy();
            if (interactive) send("UserPromptSubmit", { ...session(ctx), prompt: typeof event?.text === "string" ? event.text : "" });
          });
          pi.on("tool_call", (event: any, ctx: any) => {
            busy();
            if (interactive) send("PreToolUse", { ...session(ctx), tool_name: event?.toolName ?? "", tool_input: event?.input ?? {} });
            return undefined;
          });
          pi.on("tool_result", (event: any, ctx: any) => {
            if (interactive) send("PostToolUse", { ...session(ctx), tool_name: event?.toolName ?? "" });
            return undefined;
          });
          pi.on("agent_start", () => busy());
          pi.on("agent_end", (event: any, ctx: any) => {
            last = lastAssistantText(event?.messages) ?? last;
            busy();
            ending = setTimeout(() => {
              ending = undefined;
              if (ctx?.isIdle?.() !== false) stop(ctx);
            }, 1500);
          });
          pi.on("agent_settled", (_event: any, ctx: any) => {
            if (ctx?.isIdle?.() === false) return;
            stop(ctx);
          });
          pi.on("session_shutdown", (_event: any, ctx: any) => {
            busy();
            if (interactive) send("SessionEnd", session(ctx));
          });
        }

        """
    }
}
