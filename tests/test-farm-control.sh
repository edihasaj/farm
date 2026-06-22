#!/usr/bin/env bash
# Tests for farm-control + run-scoped farm-loop. Uses a scratch tmux session and
# a stubbed shipyard; never touches the real farm queue/session.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QCMD="$ROOT/bin/farm-queue"
LOOP="$ROOT/bin/farm-loop"
CTRL="$ROOT/bin/farm-control"

TMP="$(mktemp -d)"
SESSION="farm-control-test-$$"
QUEUE_SESSION="farm-control-queue-test-$$"
cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux kill-session -t "$QUEUE_SESSION" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

export FARM_HOME="$TMP/farm"
mkdir -p "$TMP/bin" "$TMP/work"

STUB_LOG="$TMP/ship-calls.log"
export STUB_LOG
cat > "$TMP/bin/shipyard" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "-p" ] && shift
echo "SHIP \$*" >> "$STUB_LOG"
manifest="\$(printf '%s\n' "\$*" | sed -n 's/.*write implementation subtasks to \\([^,]*\\),.*/\\1/p')"
if [ -n "\$manifest" ]; then
  mkdir -p "\$(dirname "\$manifest")"
  printf '%s\n' "wire controller API" "add status view" > "\$manifest"
fi
if [ -f "$TMP/fail-once" ]; then
  case "\$*" in
    *"retry flow"*) rm -f "$TMP/fail-once"; echo "planned failure"; exit 42 ;;
  esac
fi
[ -n "\${STUB_SLEEP:-}" ] && sleep "\$STUB_SLEEP"
echo "shipped: \$*"
STUB
chmod +x "$TMP/bin/shipyard"
export FARM_LOOP_SHIP="$TMP/bin/shipyard"

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}
count() { ls -1 "$FARM_HOME/queue/$1" 2>/dev/null | wc -l | tr -d ' '; }
has() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 — got: $2" ;; esac; }
wait_for_shell_pane() {
  local session="$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    tmux list-panes -s -t "$session" -F '#{pane_current_command}' 2>/dev/null \
      | grep -Eq '^(-?zsh|-?bash|-?sh|fish|login)$' && return 0
    sleep 0.2
  done
  return 1
}

echo "— run-scoped queue claims —"
R1="run-a"; R2="run-b"
"$QCMD" add --run "$R1" demo "a1" >/dev/null
"$QCMD" add --run "$R2" demo "b1" >/dev/null
"$QCMD" add --run "$R1" demo "a2" >/dev/null
: > "$STUB_LOG"
FARM_LOOP_RUN="$R1" "$LOOP" --drain >"$TMP/r1.out" 2>&1
check "run-a tasks done" 2 "$(grep -c '^SHIP demo a' "$STUB_LOG" | tr -d ' ')"
check "run-b left pending" 1 "$(count pending)"
grep -q '^SHIP demo b1$' "$STUB_LOG" && bad "run-b should not be claimed" || ok "run-b not claimed"

echo "— phase-scoped queue claims —"
R3="run-phase"
"$QCMD" add --run "$R3" --phase 1 demo "p1" >/dev/null
"$QCMD" add --run "$R3" --phase 2 demo "p2" >/dev/null
: > "$STUB_LOG"
FARM_LOOP_RUN="$R3" FARM_LOOP_PHASE=1 "$LOOP" --drain >"$TMP/phase.out" 2>&1
grep -q '^SHIP demo p1$' "$STUB_LOG" && ok "phase 1 task claimed" || bad "phase 1 task missing"
grep -q '^SHIP demo p2$' "$STUB_LOG" && bad "phase 2 should not be claimed" || ok "phase 2 not claimed early"

echo "— controller start without workers —"
TASKS="$TMP/tasks.txt"
cat > "$TASKS" <<'TASKS'
# split by the supervisor
part one
part two
TASKS
OUT="$(FARM_CONTROL_RUN_ID=controlled-1 "$CTRL" start --no-workers --agents 2 --task-file "$TASKS" demo)"
has "run: controlled-1" "$OUT" "start prints run id"
has "state: queued" "$OUT" "no-workers leaves run queued"
STATUS="$("$CTRL" status controlled-1)"
has "queue: pending 2" "$STATUS" "status counts pending tasks"
has "workers: none" "$STATUS" "status shows no workers"

"$CTRL" pause controlled-1 >/dev/null
has "state: paused" "$("$CTRL" status controlled-1)" "pause updates state"
[ -f "$FARM_HOME/control/runs/controlled-1.pause" ] && ok "pause file created" || bad "pause file missing"
"$CTRL" resume controlled-1 >/dev/null
has "state: running" "$("$CTRL" status controlled-1)" "resume updates state"
[ ! -f "$FARM_HOME/control/runs/controlled-1.pause" ] && ok "pause file removed" || bad "pause file still present"

echo "— ship entrypoint starts pipeline run —"
OUT="$(FARM_CONTROL_RUN_ID=ship-1 "$CTRL" ship --no-workers demo "one command flow")"
has "run: ship-1" "$OUT" "ship prints run id"
SSTATUS="$("$CTRL" status ship-1)"
has "mode: pipeline" "$SSTATUS" "ship creates pipeline run"
has "phase: 1/5" "$SSTATUS" "ship starts at phase 1"

echo "— pipeline supervisor obeys pause / stop —"
: > "$STUB_LOG"
FARM_CONTROL_RUN_ID=pause-1 "$CTRL" start --pipeline --no-workers demo "pause me" >/dev/null
"$CTRL" pause pause-1 >/dev/null
"$CTRL" supervise pause-1 >"$TMP/pause.out" 2>&1 &
PAUSE_PID=$!
sleep 1.2
check "paused supervisor has not launched work" 0 "$(grep -c '^SHIP demo ' "$STUB_LOG" | tr -d ' ')"
has "state: paused" "$("$CTRL" status pause-1)" "paused supervisor reports paused"
"$CTRL" resume pause-1 >/dev/null
wait "$PAUSE_PID"
has "state: complete" "$("$CTRL" status pause-1)" "paused supervisor resumes to complete"

: > "$STUB_LOG"
FARM_CONTROL_RUN_ID=stop-1 "$CTRL" start --pipeline --no-workers demo "stop me" >/dev/null
"$CTRL" stop stop-1 >/dev/null
"$CTRL" supervise stop-1 >"$TMP/stop.out" 2>&1 \
  && bad "stopped supervisor should exit nonzero" || ok "stopped supervisor exits nonzero"
has "state: stopped" "$("$CTRL" status stop-1)" "stopped supervisor reports stopped"
check "stopped supervisor launched no work" 0 "$(grep -c '^SHIP demo ' "$STUB_LOG" | tr -d ' ')"

echo "— pipeline retry recovers failed phase —"
: > "$STUB_LOG"
touch "$TMP/fail-once"
FARM_CONTROL_RUN_ID=retry-1 "$CTRL" start --pipeline --no-workers demo "retry flow" >/dev/null
"$CTRL" supervise retry-1 >"$TMP/retry-fail.out" 2>&1 \
  && bad "first retry flow should fail" || ok "first retry flow fails"
RSTATUS="$("$CTRL" status retry-1)"
has "state: failed" "$RSTATUS" "failed run reports failed"
has "failed 1" "$RSTATUS" "failed run has failed task"
ROUT="$("$CTRL" retry retry-1)"
has "requeued=1" "$ROUT" "retry requeues failed task"
has "phase=1" "$ROUT" "retry targets current phase"
RSTATUS="$("$CTRL" status retry-1)"
has "pending 1" "$RSTATUS" "retried task is pending"
"$CTRL" supervise retry-1 >"$TMP/retry-ok.out" 2>&1
has "state: complete" "$("$CTRL" status retry-1)" "retried run completes"

echo "— pipeline supervise: ordered gates —"
: > "$STUB_LOG"
OUT="$(FARM_CONTROL_RUN_ID=pipeline-1 "$CTRL" start --pipeline --no-workers demo "ship checkout flow")"
has "run: pipeline-1" "$OUT" "pipeline start prints run id"
PSTATUS="$("$CTRL" status pipeline-1)"
has "mode: pipeline" "$PSTATUS" "pipeline status shows mode"
has "phase: 1/5" "$PSTATUS" "pipeline starts at phase 1"
"$CTRL" supervise pipeline-1 >"$TMP/pipeline.out" 2>&1
PSTATUS="$("$CTRL" status pipeline-1)"
has "state: complete" "$PSTATUS" "pipeline completes"
has "queue: pending 0  running 0  failed 0  done 6" "$PSTATUS" "pipeline produced plan, two implementation tasks, and gates"
check "pipeline called shipyard six times" 6 "$(grep -c '^SHIP demo ' "$STUB_LOG" | tr -d ' ')"
has "Plan this project task" "$(sed -n '1p' "$STUB_LOG")" "phase 1 is plan"
has "Implement the planned change" "$(sed -n '2p' "$STUB_LOG")" "phase 2 is implement"
has "wire controller API" "$(sed -n '2,3p' "$STUB_LOG")" "phase 2 includes first planned subtask"
has "add status view" "$(sed -n '2,3p' "$STUB_LOG")" "phase 2 includes second planned subtask"
has "Security review" "$(sed -n '4p' "$STUB_LOG")" "phase 3 is security"
has "Code review pass" "$(sed -n '5p' "$STUB_LOG")" "phase 4 is code review"
has "Final gate" "$(sed -n '6p' "$STUB_LOG")" "phase 5 is final gate"
LOGS_OUT="$("$CTRL" logs pipeline-1 --lines 2)"
has "== " "$LOGS_OUT" "logs prints task log sections"
has "shipped:" "$LOGS_OUT" "logs includes shipyard output"
INSPECT_OUT="$("$CTRL" inspect pipeline-1 --lines 2)"
has "tasks:" "$INSPECT_OUT" "inspect includes task list"
has "logs:" "$INSPECT_OUT" "inspect includes logs"
has "panes:" "$INSPECT_OUT" "inspect includes pane section"

echo "— pipeline tmux supervisor controls worker panes —"
tmux new-session -d -s "$SESSION" -c "$TMP/work" -n F1
tmux split-window -d -t "$SESSION:1" -c "$TMP/work"
tmux split-window -d -t "$SESSION:1" -c "$TMP/work"
wait_for_shell_pane "$SESSION" || bad "pipeline tmux session did not expose a shell pane"
: > "$STUB_LOG"
FARM_CONTROL_RUN_ID=pipeline-2 "$CTRL" start --pipeline --agents 2 --session "$SESSION" --start-dir "$TMP/work" demo "ship pane pipeline" >"$TMP/pipeline-start.out"
has "state: running" "$(cat "$TMP/pipeline-start.out")" "pipeline supervisor launched"
PSTATUS=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PSTATUS="$("$CTRL" status pipeline-2)"
  case "$PSTATUS" in *"state: complete"*) break ;; esac
  sleep 1
done
has "state: complete" "$PSTATUS" "tmux pipeline completes"
has "queue: pending 0  running 0  failed 0  done 6" "$PSTATUS" "tmux pipeline drains all phases"
case "$PSTATUS" in *"supervisor: %"*) ok "status records supervisor pane id" ;; *) bad "status missing supervisor pane — got: $PSTATUS" ;; esac
case "$PSTATUS" in *"workers: %"*) ok "status records controlled pane ids" ;; *) bad "status missing worker panes — got: $PSTATUS" ;; esac
PANE_OUT="$("$CTRL" pane pipeline-2 all 5)"
has "== pane %" "$PANE_OUT" "pane command captures supervised panes"
has "farm-control" "$PANE_OUT" "pane capture includes controller output"
tmux kill-session -t "$SESSION" 2>/dev/null || true

echo "— controller launches into free tmux pane —"
tmux new-session -d -s "$QUEUE_SESSION" -c "$TMP/work" -n F1
wait_for_shell_pane "$QUEUE_SESSION" || bad "queue tmux session did not expose a shell pane"
FARM_CONTROL_RUN_ID=controlled-2 "$CTRL" start --agents 1 --session "$QUEUE_SESSION" --start-dir "$TMP/work" demo "pane task" >"$TMP/start.out"
has "state: running" "$(cat "$TMP/start.out")" "start launches worker"
sleep 1.2
STATUS2="$("$CTRL" status controlled-2)"
has "queue: pending 0" "$STATUS2" "launched worker drained run"
has "done 1" "$STATUS2" "run task done"
grep -q '^SHIP demo pane task$' "$STUB_LOG" && ok "worker called shipyard stub" || bad "shipyard stub not called"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
