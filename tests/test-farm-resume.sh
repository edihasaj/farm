#!/usr/bin/env bash
# Tests for bin/farm-resume — specifically that a resumed codex session carries
# forward the model + reasoning effort it was last using (read from the rollout's
# `turn_context`), instead of falling back to codex's default (medium).
# Hermetic: points HOME at a temp dir with a synthetic rollout; never touches the
# real ~/.codex or tmux (list/--json mode needs neither).
# Run: tests/test-farm-resume.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESUME="$ROOT/bin/farm-resume"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
has()  { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 (got: $2)" ;; esac; }
hasnt(){ case "$2" in *"$1"*) bad "$3 (got: $2)" ;; *) ok "$3" ;; esac; }

# --- synthetic codex rollout: two turn_contexts; the LAST (high) must win ---
SESS_DIR="$TMP/.codex/sessions/2026/06/12"
mkdir -p "$SESS_DIR"
ROLL="$SESS_DIR/rollout-2026-06-12T10-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
cat > "$ROLL" <<'EOF'
{"timestamp":"2026-06-12T10:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/demo-proj","model_provider":"openai"}}
{"timestamp":"2026-06-12T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5","reasoning_effort":"medium","effort":"medium"}}
{"timestamp":"2026-06-12T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"refactor the queue"}}
{"timestamp":"2026-06-12T10:05:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","reasoning_effort":"high","effort":"high"}}
EOF

CMD="$(HOME="$TMP" "$RESUME" list --since 720 --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["cmd"] for x in d if x["tool"]=="codex"))')"

has 'codex resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' "$CMD" "resumes by session id"
has '-c model="gpt-5.5"'                 "$CMD" "carries the model"
has '-c model_reasoning_effort="high"'   "$CMD" "carries last effort (high, not the earlier medium)"
hasnt 'model_reasoning_effort="medium"'  "$CMD" "does not regress to the earlier medium turn"

# --- a rollout with no turn_context must degrade gracefully (plain resume) ---
SESS2="$TMP/.codex/sessions/2026/06/12/rollout-2026-06-12T11-00-00-11111111-2222-3333-4444-555555555555.jsonl"
cat > "$SESS2" <<'EOF'
{"timestamp":"2026-06-12T11:00:00.000Z","type":"session_meta","payload":{"id":"11111111-2222-3333-4444-555555555555","cwd":"/tmp/demo-proj","model_provider":"openai"}}
EOF
# newest per (tool,cwd) dedupes to this one (11:00 > 10:00), so it should appear bare
CMD2="$(HOME="$TMP" "$RESUME" list --since 720 --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["cmd"] for x in d if x["tool"]=="codex"))')"
has 'codex resume 11111111-2222-3333-4444-555555555555' "$CMD2" "no turn_context: still resumes"
hasnt '-c model'                          "$CMD2" "no turn_context: no model override appended"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
