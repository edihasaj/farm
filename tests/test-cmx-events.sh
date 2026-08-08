#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'tmux kill-session -t cmx-event-test 2>/dev/null || true; rm -rf "$TMP"' EXIT

tmux new-session -d -s cmx-event-test "XDG_STATE_HOME='$TMP/state' '$ROOT/bin/cmx-agent-event' working codex </dev/null"
for _ in 1 2 3 4 5; do
  [[ -f $TMP/state/farm/agents/cmx-event-test ]] && break
  sleep 0.1
done
grep -Fxq 'state=working' "$TMP/state/farm/agents/cmx-event-test"
grep -Fxq 'agent=codex' "$TMP/state/farm/agents/cmx-event-test"

mkdir -p "$TMP/home/.codex" "$TMP/home/.codex-work" "$TMP/home/.claude"
printf '{"hooks":{"SessionStart":[],"UserPromptSubmit":[],"Stop":[]}}\n' >"$TMP/home/.codex/hooks.json"
cp "$TMP/home/.codex/hooks.json" "$TMP/home/.codex-work/hooks.json"
printf '{"hooks":{}}\n' >"$TMP/home/.claude/settings.json"
HOME="$TMP/home" "$ROOT/bin/cmx-setup" >/dev/null
HOME="$TMP/home" "$ROOT/bin/cmx-setup" >/dev/null
jq -e '.hooks.UserPromptSubmit[] | select(.hooks[0].command | contains("cmx-agent-event working codex"))' "$TMP/home/.codex/hooks.json" >/dev/null
jq -e '.hooks.Stop[] | select(.hooks[0].command | contains("cmx-agent-event done claude"))' "$TMP/home/.claude/settings.json" >/dev/null
[[ $(jq '[.hooks.UserPromptSubmit[] | select(.hooks[0].command | contains("cmx-agent-event working codex"))] | length' "$TMP/home/.codex/hooks.json") == 1 ]]

cat >"$TMP/fake-ssh" <<'EOF'
#!/usr/bin/env bash
printf 'state=done\nagent=codex\nevent=old\nscreen=working\n'
EOF
cat >"$TMP/fake-cmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CMX_TEST_LOG"
EOF
chmod +x "$TMP/fake-ssh" "$TMP/fake-cmux"
CMUX_BIN="$TMP/fake-cmux" CMX_SSH_BIN="$TMP/fake-ssh" CMX_TEST_LOG="$TMP/watch.log" \
  XDG_STATE_HOME="$TMP/watch-state" CMX_WATCH_INTERVAL=0.1 \
  "$ROOT/bin/cmx-watch" legacy workspace-test studio &
watch_pid=$!
sleep 0.4
kill "$watch_pid"
wait "$watch_pid" 2>/dev/null || true
grep -Fq 'workspace loading on' "$TMP/watch.log"
if grep -Fq 'notify' "$TMP/watch.log"; then
  printf 'stale completion unexpectedly notified\n' >&2
  exit 1
fi

printf 'cmx event tests passed\n'
