// Pi extension: forwards lifecycle events to `seh dispatch <event>`. pi/omp.ts is the Oh My Pi variant.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// The seh script shipped in this package, so git installs work without seh on PATH.
const seh = fileURLToPath(new URL("../bin/seh", import.meta.url));

export function sehExtension({ omp }: { omp: boolean }) {
  return (pi: ExtensionAPI) => {
    let pending: string[] = [];

    const run = (event: string, ctx: ExtensionContext, extra: Record<string, unknown> = {}) => {
      // Hand-picked fields only: Pi events can carry AbortSignals and whole transcripts.
      const input = JSON.stringify({
        hook_event_name: event,
        session_id: ctx.sessionManager.getSessionId(),
        cwd: ctx.cwd,
        ...extra,
      });
      const r = spawnSync(seh, ["dispatch", event], {
        input,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "inherit"],
      });
      if (r.error) process.stderr.write(`seh ${event}: ${r.error.message}\n`);
      if (r.stdout?.trim()) pending.push(r.stdout.trim());
    };
    // Script stdout reaches the model as hidden context.
    const take = () => {
      const content = pending.join("\n\n");
      pending = [];
      return { customType: "seh", content, display: false };
    };

    pi.on("session_start", (e, ctx) => run("session-start", ctx, { source: e.reason }));
    pi.on("session_compact", (e, ctx) => {
      run("compact", ctx, { source: e.reason });
      // Steer, not the next prompt: auto-compaction continues the same run when messages are queued,
      // and `pi -p` never sees a next prompt.
      if (pending.length) pi.sendMessage(take(), { deliverAs: "steer" });
    });
    pi.on("session_shutdown", (e, ctx) => run("session-end", ctx, { reason: e.reason }));
    // Oh My Pi has no agent_settled.
    if (omp) pi.on("agent_end", (_e, ctx) => run("stop", ctx));
    else pi.on("agent_settled", (_e, ctx) => run("stop", ctx));
    pi.on("tool_call", (e, ctx) => run("pre-tool", ctx, { tool_name: e.toolName, tool_input: e.input }));
    pi.on("tool_result", (e, ctx) => run("post-tool", ctx, { tool_name: e.toolName, tool_input: e.input }));
    pi.on("before_agent_start", (e, ctx) => {
      run("prompt", ctx, { prompt: e.prompt });
      if (pending.length) return { message: take() };
    });
  };
}

export default sehExtension({ omp: false });
