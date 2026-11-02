#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031 # generated scripts expand their own $vars; HOME is subshell-local on purpose
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"
seh="$repo/bin/seh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export SEH_ROOT="$tmp/registry"
unset PI_SESSION_ID OMP_SESSION_ID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
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
for var in PI_SESSION_ID OMP_SESSION_ID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID; do
  env "$var=env-$var" "$seh" add stop "$tmp/c.sh" | grep -q "/env-$var/stop/" || fail "add via $var"
done
env CLAUDE_CODE_SESSION_ID=outer PI_SESSION_ID=inner "$seh" add stop "$tmp/c.sh" | grep -q /inner/ || fail "nested precedence"
"$seh" add stop "$tmp/c.sh" 2>/dev/null && fail "add without session id should fail"

# show / remove
[[ "$("$seh" show sid1)" == "sid1/compact/a.sh -> $tmp/a.sh"$'\n'"sid1/compact/b.sh -> $tmp/b.sh"$'\n'"sid1/compact/c.sh -> $tmp/c.sh" ]] || fail "show session"
[[ "$("$seh" show | wc -l)" -eq 8 ]] || fail "show all outside a session"
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

# Pi / Oh My Pi extensions: drive handlers with a fake pi and a fake bundled seh
mkdir -p "$tmp/pkg/bin"
cp -R "$repo/pi" "$repo/package.json" "$tmp/pkg/"
printf '#!/bin/sh\ncat > "%s/pi-$2.json"\necho "ctx-$2"\n' "$tmp" > "$tmp/pkg/bin/seh"
chmod +x "$tmp/pkg/bin/seh"
node --input-type=module -e "
import pi from '$tmp/pkg/pi/seh.ts';
import omp from '$tmp/pkg/pi/omp.ts';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const load = (ext) => { const h = {}; ext({ on: (name, fn) => { h[name] = fn; } }); return h; };
const ctx = { cwd: '/w', sessionManager: { getSessionId: () => 'pi-sid' } };
const h = load(pi);
h.session_compact({ reason: 'threshold', signal: new AbortController().signal }, ctx);
assert.deepEqual(JSON.parse(readFileSync('$tmp/pi-compact.json', 'utf8')),
  { hook_event_name: 'compact', session_id: 'pi-sid', cwd: '/w', source: 'threshold' });
h.session_start({ reason: 'startup' }, ctx);
assert.equal(h.before_agent_start({ prompt: 'hi' }, ctx).message.content, 'ctx-compact\n\nctx-session-start\n\nctx-prompt');
assert.equal(h.before_agent_start({ prompt: 'again' }, ctx).message.content, 'ctx-prompt');
assert.ok(h.agent_settled && !h.agent_end);
assert.equal(h.tool_call({ toolName: 'bash', input: { command: 'ls' } }, ctx), undefined);
const o = load(omp);
assert.ok(o.agent_end && !o.agent_settled);
assert.equal(o.tool_call({ toolName: 'bash', input: { command: 'ls' } }, ctx), undefined);
" || fail "pi extensions"

# init: wires found CLIs, is idempotent, keeps other hooks
(
  export HOME="$tmp/home"; unset CLAUDE_CONFIG_DIR CODEX_HOME
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.pi/agent" "$HOME/.omp/agent" "$tmp/fbin"
  for c in pi omp; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/installs"\n' "$c" "$tmp" > "$tmp/fbin/$c"
    chmod +x "$tmp/fbin/$c"
  done
  export PATH="$tmp/fbin:$PATH"
  echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  "$seh" init >/dev/null && "$seh" init >/dev/null
  s="$HOME/.claude/settings.json"
  [[ "$(jq -r .model "$s")" == x ]] || fail "init dropped settings"
  [[ "$(jq '[.hooks.Stop[].hooks[].command] | length' "$s")" == 2 ]] || fail "init not idempotent / dropped hook"
  jq -e '.hooks.Stop[].hooks[].command | select(. == "keep-me")' "$s" >/dev/null || fail "init dropped other hook"
  jq -e --arg c "'$seh' dispatch compact" '.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command == $c' "$s" >/dev/null || fail "claude compact wiring"
  [[ "$(jq '[.hooks[][]] | length' "$HOME/.codex/hooks.json")" == 7 ]] || fail "codex wiring"
  # plugin hooks wire the same events and matchers as init
  for p in "claude $s hooks.json" "codex $HOME/.codex/hooks.json codex.json"; do
    read -r c cfg plugin <<<"$p"
    jq -e --slurpfile p "$repo/hooks/$plugin" --arg seh "'$seh'" '
      def norm: .hooks | map_values(map(.hooks |= map(select(.command != "keep-me")
        | .command |= sub("^\"\\$\\{CLAUDE_PLUGIN_ROOT\\}/bin/seh\""; $seh) | del(.timeout))) | map(select(.hooks != [])));
      norm == ($p[0] | norm)' "$cfg" >/dev/null || fail "$c plugin hooks differ from init"
  done
  [[ ! -e "$HOME/.config/devin" ]] || fail "init touched a CLI that is not installed"
  "$seh" init devin >/dev/null
  jq -e '.hooks.PostCompaction[0].matcher == ""' "$HOME/.config/devin/config.json" >/dev/null || fail "devin wiring"
  [[ "$(sort -u "$tmp/installs")" == "omp install npm:omp-shell-context $repo"$'\n'"pi install $repo" ]] || fail "pi/omp install: $(cat "$tmp/installs")"
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

# Plugins load in the real CLIs (no auth needed). CI installs both; skipped locally when missing.
if command -v claude >/dev/null; then
  CLAUDE_CONFIG_DIR="$tmp/claude-cfg" claude plugin validate "$repo" >/dev/null || fail "claude plugin validate"
else echo "skip: claude not found"; fi
if command -v codex >/dev/null; then
  (
    export CODEX_HOME="$tmp/codex-home"; mkdir -p "$CODEX_HOME"
    codex plugin marketplace add "$repo" >/dev/null || fail "codex marketplace add"
    codex plugin add seh@seh >/dev/null || fail "codex plugin add"
    # Ask the app server which hooks it loaded; stop it once the answer arrives (30s cap).
    # shellcheck disable=SC2094 # the loop polls the file the pipeline writes, on purpose
    { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t","version":"0"}}}' \
        '{"jsonrpc":"2.0","method":"initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"hooks/list","params":{"cwds":["'"$repo"'"]}}'
      for _ in $(seq 150); do [[ -s "$tmp/hooks-list" ]] && break; sleep 0.2; done
    } | codex app-server 2>/dev/null | jq --unbuffered -c 'select(.id == 2)' | head -n 1 > "$tmp/hooks-list"
    jq -e '.result.data[0]
      | .warnings == [] and ([.hooks[] | select(.pluginId == "seh@seh")] | length == 7
        and all(.key | startswith("seh@seh:hooks/codex.json:")) and all(.command | test("^\"/[^$]*/bin/seh\" dispatch [a-z-]+$")))' \
      "$tmp/hooks-list" >/dev/null || fail "codex plugin hooks: $(cat "$tmp/hooks-list")"
  )
else echo "skip: codex not found"; fi

echo ok
