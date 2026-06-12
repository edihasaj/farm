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

# --- claude: last permissionMode (bypass) -> --dangerously-skip-permissions ---
CL_DIR="$TMP/.claude/projects/-tmp-demo-proj"
mkdir -p "$CL_DIR"
CL="$CL_DIR/cccccccc-dddd-eeee-ffff-000000000000.jsonl"
cat > "$CL_DIR/cccccccc-dddd-eeee-ffff-000000000000.jsonl" <<'EOF'
{"type":"user","cwd":"/tmp/demo-proj","permissionMode":"auto","message":{"role":"user","content":"start"}}
{"type":"assistant","cwd":"/tmp/demo-proj","permissionMode":"bypassPermissions","message":{"role":"assistant","model":"claude-opus-4-8"}}
EOF
CLCMD="$(HOME="$TMP" "$RESUME" list --since 720 --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["cmd"] for x in d if x["tool"]=="claude"))')"
has 'claude --resume cccccccc-dddd-eeee-ffff-000000000000' "$CLCMD" "claude resumes by id"
has '--dangerously-skip-permissions'  "$CLCMD" "claude carries last mode (bypass)"
hasnt '--permission-mode'             "$CLCMD" "bypass uses the flag, not --permission-mode"

# --- claude: a session that ended in 'auto' -> --permission-mode auto ---
CL2_DIR="$TMP/.claude/projects/-tmp-demo-auto"
mkdir -p "$CL2_DIR"
cat > "$CL2_DIR/99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl" <<'EOF'
{"type":"user","cwd":"/tmp/demo-auto","permissionMode":"auto","message":{"role":"user","content":"go"}}
EOF
CLCMD2="$(HOME="$TMP" "$RESUME" list --since 720 --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["cmd"] for x in d if x["cwd"]=="/tmp/demo-auto"))')"
has '--permission-mode auto'          "$CLCMD2" "claude restores --permission-mode auto"
hasnt 'dangerously'                   "$CLCMD2" "auto mode does not add dangerously-skip"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
