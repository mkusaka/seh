# seh

Session-scoped hooks for coding agent CLIs (Claude Code, Codex, Devin, Pi): register a shell script to run for one specific session id, e.g. "after this session is compacted, run this script".

## How it works

- `seh add <event> <script> [session_id]` symlinks the script into `~/.local/state/seh/<session_id>/<event>/` (override the root with `$SEH_ROOT`).
- Each CLI is wired once to call `seh dispatch <event>` with its hook JSON on stdin. `dispatch` reads `session_id` from the JSON and runs that session's executables for `<event>` in name order, passing the same JSON on stdin.
- Sessions with no registrations are a no-op (exit 0). A failing script does not stop the rest; the failure is reported on stderr.
- Script stdout goes back to the CLI. Where the CLI injects hook stdout into the conversation (e.g. `SessionStart` / `UserPromptSubmit` in Claude Code), scripts can add context that way.

Requires `bash` and `jq` (plus Node-compatible runtime for the Pi extension, which Pi already provides).

## Events

`<event>` is a seh label. Wire the labels you need; each maps to a native event per CLI:

| label           | Claude Code                       | Codex                           | Devin              | Pi                   |
| --------------- | --------------------------------- | ------------------------------- | ------------------ | -------------------- |
| `session-start` | `SessionStart` `startup\|resume\|clear\|fork` | `SessionStart` `startup\|resume\|clear` | `SessionStart` | `session_start` |
| `compact`       | `SessionStart` `compact`          | `SessionStart` `compact`        | `PostCompaction`   | `session_compact`    |
| `prompt`        | `UserPromptSubmit`                | `UserPromptSubmit`              | `UserPromptSubmit` | `before_agent_start` |
| `pre-tool`      | `PreToolUse`                      | `PreToolUse`                    | `PreToolUse`       | `tool_call`          |
| `post-tool`     | `PostToolUse`                     | `PostToolUse`                   | `PostToolUse`      | `tool_result`        |
| `stop`          | `Stop`                            | `Stop`                          | `Stop`             | `agent_settled`      |
| `session-end`   | `SessionEnd`                      | `SessionEnd`                    | `SessionEnd`       | `session_shutdown`   |

Labels are just directory names, so you can wire other native events under any label you like.

## Setup

```sh
ln -s "$PWD/bin/seh" ~/.local/bin/seh
seh init                 # wire every CLI found (~/.claude, ~/.codex, ~/.config/devin, ~/.pi/agent)
seh init claude codex    # or only the ones you name
```

`init` is safe to re-run:

- Claude Code / Codex / Devin: adds one hook per event to `settings.json` / `hooks.json` / `config.json`, replacing only earlier seh hooks. Before writing, seh checks that the new file equals the old one apart from seh's own hooks; if the file can't be parsed or the check fails, it is left untouched and `init` exits non-zero. Otherwise the old file is backed up as `*.bak-seh-<timestamp>`. Hooks call `seh` by absolute path. Codex asks you to trust new or changed hooks on the next launch.
- Pi: links `pi/seh.js` into `~/.pi/agent/extensions/`. Script stdout is added as hidden context on the next prompt.

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` are respected. There is no uninstall command; remove the `seh dispatch` hooks and the Pi link by hand.

### Agent skill

`skills/seh/SKILL.md` teaches an agent to use seh. Link it into your agent's skills directory, e.g.:

```sh
ln -s "$PWD/skills/seh" ~/.claude/skills/seh
```

## Usage

```sh
seh add compact ./after-compact.sh     # register for the current session
seh add stop ./notify.sh <sid>         # register for another session
seh show                               # current session's registrations (every session when run outside one)
seh show <sid>
seh remove stop notify.sh [sid]        # unregister
```

`show` prints `<session_id>/<event>/<name> -> <script>`.

### Session ids

Without `session_id`, the current session is resolved in this order:

1. **Devin**: a `devin` ancestor process → the newest visible session in Devin's `sessions.db` whose working directory contains `$DEVIN_PROJECT_DIR` (or `$PWD`). Devin exports no session id, so this is a heuristic: two Devin sessions in the same directory resolve to the most recently active one. Requires `sqlite3`.
2. **Pi**: `PI_SESSION_ID`, set by Pi's bash tool (Pi ≥ 0.82.0).
3. **Codex**: `CODEX_THREAD_ID`.
4. **Claude Code**: `CLAUDE_CODE_SESSION_ID`.

Inner CLIs come first because a CLI launched from another inherits its environment.

Registrations are not cleaned up when a session ends; remove them with `rm -rf ~/.local/state/seh/<sid>`.

## Test

```sh
./test.sh
```
