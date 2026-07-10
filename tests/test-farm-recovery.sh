#!/usr/bin/env bash
# Regression tests for bin/farm post-reboot recovery. Uses a scratch tmux session
# (FARM_SESSION) so it never touches the real farm. Covers the power-outage bug:
# continuum restores a wrong-sized grid (e.g. 6 panes) and a plain `farm` must
# rebuild it to the full 4x8=32-pane tab set before staging resumes — instead of
# leaving the restored 6 and only staging into them.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FARM="$ROOT/bin/farm"
export FARM_VIEW="$ROOT/bin/farm-view"

TMP="$(mktemp -d)"
SESSION="farm-recovery-test-$$"
export FARM_SESSION="$SESSION"
cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Stub farm-resume so stage_resumes just records that it ran (and when), without
# typing into any pane.
STAGE_LOG="$TMP/stage.log"
cat > "$TMP/farm-resume" <<STUB
#!/usr/bin/env bash
echo "STAGE panes=\$(tmux list-panes -s -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" >> "$STAGE_LOG"
STUB
chmod +x "$TMP/farm-resume"
export FARM_RESUME_BIN="$TMP/farm-resume"
mkdir -p "$HOME/.farm-snapshots"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

panes() { tmux list-panes -s -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '; }
wins()  { tmux list-windows -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '; }

# Simulate a continuum-restored farm: one window, 6 bare-shell (idle) panes.
restore_six() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -x 400 -y 120 -n F1
  for _ in 1 2 3 4 5; do
    tmux split-window -t "$SESSION:F1" 2>/dev/null
    tmux select-layout -t "$SESSION:F1" tiled >/dev/null 2>&1
  done
}

# bin/farm ends in `exec tmux attach`; with no tty that fails fast AFTER the
# rebuild/stage work is done. Run detached and ignore the attach exit.
run_farm() { "$FARM" "$@" </dev/null >/dev/null 2>&1 || true; }

# --- Test 1: power-outage restore (6 idle panes) -> plain `farm` rebuilds to 32 ---
restore_six
[ "$(panes)" = "6" ] || bad "setup: expected 6 restored panes, got $(panes)"
run_farm
got_panes="$(panes)"; got_wins="$(wins)"
[ "$got_panes" = "32" ] && ok "recovery rebuilds restored 6-pane grid to 32 panes" \
  || bad "recovery: expected 32 panes, got $got_panes"
[ "$got_wins" = "4" ] && ok "recovery rebuilds into 4 tabs (4x8)" \
  || bad "recovery: expected 4 windows, got $got_wins"

# resumes must stage AFTER the rebuild, i.e. into the full 32-pane grid
if [ -f "$STAGE_LOG" ] && grep -q "STAGE panes=32" "$STAGE_LOG"; then
  ok "resumes stage into the rebuilt 32-pane grid"
else
  bad "recovery: stage_resumes did not run against 32 panes (log: $(cat "$STAGE_LOG" 2>/dev/null))"
fi

# --- Test 2: idempotent — a 2nd bare `farm` (already staged) must NOT re-kill ---
# @farm_resumed is set after the first recovery, so the grid the user is reviewing
# is left intact and resumes are not re-staged.
: > "$STAGE_LOG"
run_farm
[ "$(panes)" = "32" ] && ok "second bare farm leaves the 32-pane grid intact" \
  || bad "idempotency: expected 32 panes after 2nd run, got $(panes)"
[ ! -s "$STAGE_LOG" ] && ok "second bare farm does not re-stage resumes" \
  || bad "idempotency: resumes were re-staged (log: $(cat "$STAGE_LOG"))"

echo
echo "recovery tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
