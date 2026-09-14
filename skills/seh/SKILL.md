---
name: seh
description: Use when a coding agent session (Claude Code, Codex, Devin, or Pi) should run a shell script on one of its own lifecycle events — after compaction, at session start or end, on each prompt, before or after tool calls, or when the agent stops — using the seh CLI. Covers wiring CLIs with `seh init`, registering scripts for the current or another session with `seh add`, listing and removing registrations, and troubleshooting hooks that do not fire.
---

# seh

`seh` runs shell scripts for one specific session id when that session hits a lifecycle event. Registrations are per session, so they never affect other sessions.

## Quick start

```bash
seh init                                   # once per machine: wire every installed CLI
seh add compact /abs/path/after-compact.sh # run after this session is compacted
```

`seh add` without a session id registers for the current session. Scripts must be executable.

## Events

| event           | fires                                          |
| --------------- | ---------------------------------------------- |
| `session-start` | session starts or resumes (not on compaction)  |
| `compact`       | after context compaction                       |
| `prompt`        | user submits a prompt                          |
| `pre-tool`      | before each tool call                          |
| `post-tool`     | after each tool call                           |
| `stop`          | agent finishes responding                      |
| `session-end`   | session ends                                   |

## Writing a script

- stdin is the hook JSON: always `session_id`, usually `cwd` and `hook_event_name`, plus event fields such as `source`, `tool_name`, `tool_input`, `prompt`.
- stdout goes back to the CLI as the hook's output, so each CLI's own hook rules apply (Claude Code adds it to the conversation for `session-start`, `compact`, and `prompt`). Pi adds any output as hidden context on the next prompt. Use this to re-inject instructions after compaction.
- Keep scripts fast and quiet; `pre-tool` and `post-tool` run on every tool call. A failing script is reported on stderr and does not block the others.

Example — restore working notes after compaction:

```bash
cat > /tmp/after-compact.sh <<'EOF'
#!/bin/sh
cat "$HOME/notes/current-task.md"
EOF
chmod +x /tmp/after-compact.sh
seh add compact /tmp/after-compact.sh
```

## Session ids

`seh add`, `seh remove`, and `seh show` default to the current session, resolved from (first match wins):

1. Devin: a `devin` ancestor process, then the newest session for the current directory in Devin's `sessions.db`. If two Devin sessions share a directory this can pick the wrong one — pass the id explicitly then.
2. Pi: `PI_SESSION_ID` (set by Pi's bash tool, Pi ≥ 0.82.0).
3. Codex: `CODEX_THREAD_ID`.
4. Claude Code: `CLAUDE_CODE_SESSION_ID`.

Run `seh show` first when unsure which session a command will target.

## Managing registrations

```bash
seh show                              # this session (every session when run outside one)
seh show <session_id>
seh remove <event> <script> [session_id]   # script name or path
rm -rf ~/.local/state/seh/<session_id>     # remove all for a session
```

`$SEH_ROOT` overrides `~/.local/state/seh`. Registrations are symlinks, so moving or deleting the original script breaks them. They are not removed when a session ends.

## Troubleshooting

- Nothing runs: check the CLI is wired (`seh init <cli>` is safe to re-run; it replaces only seh's own hooks and backs up the config as `*.bak-seh-<timestamp>`), and that the registration exists under the session id the CLI reports.
- Codex: new or changed hooks must be trusted in Codex before they run.
- Pi: `seh init pi` links the extension into `~/.pi/agent/extensions/`; run `/reload` or start a new session.
- Test a registration without the CLI: `echo '{"session_id":"<id>"}' | seh dispatch <event>`.
