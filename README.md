# seh

Session-scoped hooks for Claude Code: register a shell script to run for one specific session id, e.g. "after this session is compacted, run this script".

## Setup

Requires `bash` and `jq`.

```sh
ln -s "$PWD/bin/seh" ~/.local/bin/seh
```

Add this to `hooks.SessionStart` in `~/.claude/settings.json`:

```json
{
  "matcher": "compact",
  "hooks": [
    { "type": "command", "command": "seh dispatch compact", "timeout": 30 }
  ]
}
```

Other events (`PreCompact`, `SessionEnd`, ...) work the same way: add a hook that runs `seh dispatch <event>`.
`<event>` is only used as a directory name, so any label works.

## Usage

```sh
seh add compact ./after-compact.sh          # register for the current session ($CLAUDE_CODE_SESSION_ID)
seh add compact ./after-compact.sh <sid>    # register for another session
ls ~/.claude/session-hooks/<sid>/compact/   # list
rm ~/.claude/session-hooks/<sid>/compact/after-compact.sh   # unregister
```

## Behavior

- Registrations are symlinks under `~/.claude/session-hooks/<session_id>/<event>/` (`$CLAUDE_CONFIG_DIR` is respected).
- `dispatch` reads the hook JSON from stdin, looks up its `session_id`, and runs the executables in that directory in name order, passing the same JSON on each script's stdin.
- Sessions with no registrations are a no-op (exit 0).
- A failing script does not stop the rest; the failure is reported on stderr.
- For `SessionStart` hooks, stdout is injected into the conversation context.

Registrations are not cleaned up when a session ends; remove them with `rm -rf ~/.claude/session-hooks/<sid>`.

## Test

```sh
./test.sh
```
