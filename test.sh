#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031 # generated scripts expand their own $vars; HOME is subshell-local on purpose
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"
seh="$repo/bin/seh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export SEH_ROOT="$tmp/registry"
unset PI_SESSION_ID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID DEVIN_SESSION_ID
fail() { echo "FAIL: $*"; exit 1; }

printf '#!/bin/sh\necho "a:$(jq -r .source)"\n' > "$tmp/a.sh"
printf '#!/bin/sh\nexit 3\n' > "$tmp/b.sh"
printf '#!/bin/sh\necho c\n' > "$tmp/c.sh"
chmod +x "$tmp"/*.sh

# dispatch: name order, stdin passthrough, continue on failure
"$seh" add compact "$tmp/a.sh" sid1 >/dev/null
"$seh" add compact "$tmp/b.sh" sid1 >/dev/null
"$seh" add compact "$tmp/c.sh" sid1 >/dev/null
out="$(echo '{"session_id":"sid1","source":"compact"}' | "$seh" dispatch compact 2>"$tmp/err")"
[[ "$out" == $'a:compact\nc' ]] || fail "dispatch output: $out"
grep -q 'b.sh exited 3' "$tmp/err" || fail "failure not reported"
[[ -z "$(echo '{"session_id":"other"}' | "$seh" dispatch compact)" ]] || fail "unregistered session ran scripts"
[[ -z "$(echo '{"session_id":"sid1"}' | "$seh" dispatch stop)" ]] || fail "other event ran scripts"

# add: session id from each CLI's env, inner CLI first
for var in PI_SESSION_ID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID; do
  env "$var=env-$var" "$seh" add stop "$tmp/c.sh" | grep -q "/env-$var/stop/" || fail "add via $var"
done
env CLAUDE_CODE_SESSION_ID=outer PI_SESSION_ID=inner "$seh" add stop "$tmp/c.sh" | grep -q /inner/ || fail "nested precedence"
"$seh" add stop "$tmp/c.sh" 2>/dev/null && fail "add without session id should fail"

# show / remove
[[ "$("$seh" show sid1)" == "sid1/compact/a.sh -> $tmp/a.sh"$'\n'"sid1/compact/b.sh -> $tmp/b.sh"$'\n'"sid1/compact/c.sh -> $tmp/c.sh" ]] || fail "show session"
[[ "$("$seh" show | wc -l)" -eq 7 ]] || fail "show all outside a session"
CLAUDE_CODE_SESSION_ID=env-CLAUDE_CODE_SESSION_ID "$seh" show | grep -q '^env-CLAUDE_CODE_SESSION_ID/stop/c.sh ->' || fail "show current"
"$seh" remove compact a.sh sid1 >/dev/null
[[ "$("$seh" show sid1 | wc -l)" -eq 2 ]] || fail "remove one"
"$seh" remove compact a.sh sid1 2>/dev/null && fail "remove missing should fail"
PI_SESSION_ID=inner "$seh" remove stop "$tmp/c.sh" >/dev/null
[[ ! -e "$SEH_ROOT/inner" ]] || fail "remove should drop empty session dir"

# Devin: no env var; found via a devin ancestor process and its session DB
(
  export HOME="$tmp/dhome"; db="$HOME/.local/share/devin/cli/sessions.db"
  mkdir -p "$(dirname "$db")" "$tmp/proj/sub" "$tmp/dbin"
  sqlite3 "$db" "CREATE TABLE sessions (id TEXT, working_directory TEXT, hidden INTEGER, last_activity_at INTEGER);
    INSERT INTO sessions VALUES ('old', '$tmp/proj', 0, 1), ('devin-sid', '$tmp/proj', 0, 2),
      ('hidden', '$tmp/proj', 1, 3), ('elsewhere', '$tmp/other', 0, 4);"
  ln -s "$(command -v bash)" "$tmp/dbin/devin"
  cd "$tmp/proj/sub"
  out="$(CLAUDE_CODE_SESSION_ID=outer "$tmp/dbin/devin" -c "'$seh' add stop '$tmp/c.sh'; true")"
  [[ "$out" == "$SEH_ROOT/devin-sid/stop/c.sh" ]] || fail "devin session id: $out"
)

# Pi extension: drive handlers with a fake pi and check what seh receives
mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncat > "%s/pi-$2.json"\necho "ctx-$2"\n' "$tmp" > "$tmp/bin/seh"
chmod +x "$tmp/bin/seh"
PATH="$tmp/bin:$PATH" node --input-type=module -e "
import ext from '$repo/pi/seh.js';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const h = {};
ext({ on: (name, fn) => { h[name] = fn; } });
const ctx = { sessionManager: { getSessionId: () => 'pi-sid', getCwd: () => '/w' } };
h.session_compact({ reason: 'threshold', signal: new AbortController().signal }, ctx);
assert.deepEqual(JSON.parse(readFileSync('$tmp/pi-compact.json', 'utf8')),
  { hook_event_name: 'compact', session_id: 'pi-sid', cwd: '/w', source: 'threshold' });
h.session_start({ reason: 'startup' }, ctx);
const r = h.before_agent_start({ prompt: 'hi' }, ctx);
assert.equal(r.message.content, 'ctx-compact\n\nctx-session-start\n\nctx-prompt');
assert.equal(h.before_agent_start({ prompt: 'again' }, ctx).message.content, 'ctx-prompt');
" || fail "pi extension"

# init: wires found CLIs, is idempotent, keeps other hooks
(
  export HOME="$tmp/home"; unset CLAUDE_CONFIG_DIR CODEX_HOME
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.pi/agent"
  echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  "$seh" init >/dev/null && "$seh" init >/dev/null
  s="$HOME/.claude/settings.json"
  [[ "$(jq -r .model "$s")" == x ]] || fail "init dropped settings"
  [[ "$(jq '[.hooks.Stop[].hooks[].command] | length' "$s")" == 2 ]] || fail "init not idempotent / dropped hook"
  jq -e '.hooks.Stop[].hooks[].command | select(. == "keep-me")' "$s" >/dev/null || fail "init dropped other hook"
  jq -e --arg c "'$seh' dispatch compact" '.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command == $c' "$s" >/dev/null || fail "claude compact wiring"
  [[ "$(jq '[.hooks[][]] | length' "$HOME/.codex/hooks.json")" == 7 ]] || fail "codex wiring"
  [[ ! -e "$HOME/.config/devin" ]] || fail "init touched a CLI that is not installed"
  "$seh" init devin >/dev/null
  jq -e '.hooks.PostCompaction[0].matcher == ""' "$HOME/.config/devin/config.json" >/dev/null || fail "devin wiring"
  [[ "$(readlink "$HOME/.pi/agent/extensions/seh.js")" == "$repo/pi/seh.js" ]] || fail "pi link"
  "$seh" init nope 2>/dev/null && fail "unknown CLI should fail"

  # configs seh cannot rewrite safely are left byte-for-byte unchanged, with no backup or temp file
  for bad in '{"hooks": {"Stop": "not-an-array"}}' '{"hooks": [1]}' '{ broken json'; do
    printf '%s' "$bad" > "$HOME/.codex/hooks.json"
    rm -f "$HOME/.codex/hooks.json".*
    "$seh" init codex 2>/dev/null && fail "init accepted: $bad"
    [[ "$(cat "$HOME/.codex/hooks.json")" == "$bad" ]] || fail "init modified: $bad"
    compgen -G "$HOME/.codex/hooks.json.*" >/dev/null && fail "init left files for: $bad"
  done
  true
)

echo ok
