#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'tmux kill-session -t cmx-event-test 2>/dev/null || true; rm -rf "$TMP"' EXIT

tmux new-session -d -s cmx-event-test "printf '%s' '{\"prompt\":\"Fix checkout retries without losing queued jobs in production\"}' | CMX_SUMMARIZER=/bin/true XDG_STATE_HOME='$TMP/state' '$ROOT/bin/cmx-agent-event' working codex"
for _ in 1 2 3 4 5; do
  [[ -f $TMP/state/farm/agents/cmx-event-test ]] && break
  sleep 0.1
done
grep -Fxq 'state=working' "$TMP/state/farm/agents/cmx-event-test"
grep -Fxq 'agent=codex' "$TMP/state/farm/agents/cmx-event-test"
grep -Fxq 'summary=Fix checkout retries without losing queued jobs in production' "$TMP/state/farm/agents/cmx-event-test"

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
printf 'state=done\nagent=codex\nevent=old\nsummary=Deploy immutable release\nscreen=working\n'
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
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f $TMP/watch.log ]] && grep -Fq 'rename-workspace' "$TMP/watch.log" && break
  sleep 0.1
done
kill "$watch_pid"
wait "$watch_pid" 2>/dev/null || true
grep -Fq 'workspace loading on' "$TMP/watch.log"
grep -Fq 'rename-workspace --workspace workspace-test Deploy immutable release' "$TMP/watch.log"
grep -Fq 'set-status farm-task Deploy immutable release' "$TMP/watch.log"
if grep -Fq 'notify' "$TMP/watch.log"; then
  printf 'stale completion unexpectedly notified\n' >&2
  exit 1
fi

mkdir -p "$TMP/summary/bin" "$TMP/summary/agents"
cat >"$TMP/summary/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CMX_MODEL_LOG"
printf 'Fix checkout retries\n'
EOF
cat >"$TMP/summary/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CMX_MODEL_LOG"
while (( $# )); do
  if [[ $1 == --output-last-message ]]; then
    printf 'Deploy immutable release\n' >"$2"
    break
  fi
  shift
done
cat >/dev/null
EOF
chmod +x "$TMP/summary/bin/claude" "$TMP/summary/bin/codex"
printf 'state=working\nsummary=Fallback\nsummary_key=claude-key\n' >"$TMP/summary/agents/claude"
printf 'checkout prompt' | PATH="$TMP/summary/bin:$PATH" CMX_MODEL_LOG="$TMP/summary/models.log" \
  "$ROOT/bin/cmx-summarize" claude claude "$TMP/summary/agents/claude" claude-key
grep -Fxq 'summary=Fix checkout retries' "$TMP/summary/agents/claude"
grep -Fq -- '--model haiku' "$TMP/summary/models.log"
printf 'state=working\nsummary=Fallback\nsummary_key=codex-key\n' >"$TMP/summary/agents/codex"
printf 'deploy prompt' | PATH="$TMP/summary/bin:$PATH" CMX_MODEL_LOG="$TMP/summary/models.log" \
  "$ROOT/bin/cmx-summarize" codex codex "$TMP/summary/agents/codex" codex-key
grep -Fxq 'summary=Deploy immutable release' "$TMP/summary/agents/codex"
grep -Fq -- '--model gpt-5.6-luna' "$TMP/summary/models.log"

printf 'cmx event tests passed\n'
