// Pi extension: forwards Pi lifecycle events to `seh dispatch <event>`.
// Install: ln -s "$PWD/pi/seh.js" ~/.pi/agent/extensions/seh.js
import { spawnSync } from "node:child_process";

export default function (pi) {
  let pending = [];

  const run = (event, ctx, extra = {}) => {
    // Hand-picked fields only: Pi events can carry AbortSignals and whole transcripts.
    const input = JSON.stringify({
      hook_event_name: event,
      session_id: ctx.sessionManager.getSessionId(),
      cwd: ctx.sessionManager.getCwd(),
      ...extra,
    });
    const r = spawnSync("seh", ["dispatch", event], { input, encoding: "utf8" });
    if (r.stdout?.trim()) pending.push(r.stdout.trim());
  };

  pi.on("session_start", (e, ctx) => run("session-start", ctx, { source: e.reason }));
  pi.on("session_compact", (e, ctx) => run("compact", ctx, { source: e.reason }));
  pi.on("session_shutdown", (e, ctx) => run("session-end", ctx, { reason: e.reason }));
  pi.on("agent_settled", (_e, ctx) => run("stop", ctx));
  pi.on("tool_call", (e, ctx) => run("pre-tool", ctx, { tool_name: e.toolName, tool_input: e.input }));
  pi.on("tool_result", (e, ctx) => run("post-tool", ctx, { tool_name: e.toolName, tool_input: e.input }));
  pi.on("before_agent_start", (e, ctx) => {
    run("prompt", ctx, { prompt: e.prompt });
    if (!pending.length) return;
    // Script stdout reaches the model as hidden context on the next prompt.
    const content = pending.join("\n\n");
    pending = [];
    return { message: { customType: "seh", content, display: false } };
  });
}
