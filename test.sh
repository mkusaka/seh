#!/usr/bin/env bash
set -euo pipefail
seh="$(cd "$(dirname "$0")" && pwd)/bin/seh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp/config"

# shellcheck disable=SC2016 # expanded by the generated script, not here
printf '#!/bin/sh\necho "a:$(jq -r .source)"\n' > "$tmp/a.sh"
printf '#!/bin/sh\nexit 3\n' > "$tmp/b.sh"
printf '#!/bin/sh\necho c\n' > "$tmp/c.sh"
chmod +x "$tmp"/*.sh

"$seh" add compact "$tmp/a.sh" sid1 >/dev/null
"$seh" add compact "$tmp/b.sh" sid1 >/dev/null
CLAUDE_CODE_SESSION_ID=sid1 "$seh" add compact "$tmp/c.sh" >/dev/null

out="$(echo '{"session_id":"sid1","source":"compact"}' | "$seh" dispatch compact 2>"$tmp/err")"
[[ "$out" == $'a:compact\nc' ]] || { echo "FAIL: order/stdin/continue-on-failure: $out"; exit 1; }
grep -q 'b.sh exited 3' "$tmp/err" || { echo "FAIL: failure not reported"; exit 1; }

out="$(echo '{"session_id":"other"}' | "$seh" dispatch compact)"
[[ -z "$out" ]] || { echo "FAIL: unregistered session ran scripts"; exit 1; }

echo ok
