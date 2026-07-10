#!/usr/bin/env bash
# Regression test for farm-view trim_idle_tail: a busy session that has accumulated
# extra all-idle tabs past the 32-pane target gets those trailing tabs dropped by a
# repack pass, WITHOUT killing any agent pane. Uses a scratch tmux session.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/bin/farm-view"

SESSION="farm-view-trim-test-$$"
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
wins()  { tmux list-windows -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '; }
panes() { tmux list-panes -s -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '; }

# Build a "busy" farm: 5 tabs x 8 panes = 40. Put a long-running non-shell (a
# `tail -f` stands in for an agent) in the FIRST pane of tab 1 so is_idle()==false
# and the session is treated as busy (never rebuilt, only repacked+trimmed).
tmux new-session -d -s "$SESSION" -x 400 -y 120 -n F1
for _ in 1 2 3 4 5 6 7; do tmux split-window -t "$SESSION:F1"; tmux select-layout -t "$SESSION:F1" tiled >/dev/null 2>&1; done
for t in 2 3 4 5; do
  tmux new-window -d -t "$SESSION" -n "F$t"
  for _ in 1 2 3 4 5 6 7; do tmux split-window -t "$SESSION:F$t"; tmux select-layout -t "$SESSION:F$t" tiled >/dev/null 2>&1; done
done
# make tab 1 "busy" with a fake agent in one pane; wait until it is actually live
# (otherwise farm-view sees an idle session and takes the rebuild path, not repack).
apane=$(tmux list-panes -t "$SESSION:F1" -F '#{pane_id}' | head -1)
tmux send-keys -t "$apane" 'exec tail -f /dev/null' Enter
for _ in $(seq 1 30); do
  [ "$(tmux display -p -t "$apane" '#{pane_current_command}')" = "tail" ] && break
  sleep 0.2
done
[ "$(tmux display -p -t "$apane" '#{pane_current_command}')" = "tail" ] \
  && ok "setup: fake agent is live (busy session)" \
  || bad "setup: fake agent never started; test would exercise the wrong path"

[ "$(panes)" = "40" ] && ok "setup: 40 panes across 5 tabs" || bad "setup: expected 40 panes, got $(panes)"

# repack + trim: extras (tab 5, all idle) should be dropped down to 4 tabs / 32 panes.
"$VIEW" 8 "$SESSION" "$HOME" >/dev/null 2>&1

got_w="$(wins)"; got_p="$(panes)"
[ "$got_w" = "4" ] && ok "trim drops the extra idle tab to 4 tabs" || bad "expected 4 tabs, got $got_w"
[ "$got_p" = "32" ] && ok "trim leaves the full 32-pane grid" || bad "expected 32 panes, got $got_p"

# the fake agent must survive the trim
if tmux list-panes -s -t "$SESSION" -F '#{pane_current_command}' | grep -q '^tail$'; then
  ok "agent pane survived the repack+trim"
else
  bad "agent pane was killed by trim"
fi

echo
echo "trim tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
