#!/usr/bin/env bash
# Tests for bin/farm-schedule. Never touches the real crontab: only `line`,
# `run`, and the overlap lock are exercised (install/remove are thin crontab
# plumbing around the tested `line` output).
# Run: tests/test-farm-schedule.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QCMD="$ROOT/bin/farm-queue"
SCHED="$ROOT/bin/farm-schedule"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FARM_HOME="$TMP/farm"
mkdir -p "$TMP/demo-repo"

# shipyard stub (same shape as test-farm-loop): records calls, optional sleep
export STUB_LOG="$TMP/ship-calls.log"
cat > "$TMP/shipyard" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-p" ] && shift
echo "SHIP $*" >> "$STUB_LOG"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
echo "shipped: $*"
EOF
chmod +x "$TMP/shipyard"
export FARM_LOOP_SHIP="$TMP/shipyard"

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
count() { ls -1 "$FARM_HOME/queue/$1" 2>/dev/null | wc -l | tr -d ' '; }

echo "— line: crontab line generation —"
L="$("$SCHED" line)"
case "$L" in
  "*/30 * * * * "*farm-schedule" run >> "*"scheduler.log 2>&1 # farm-schedule") ok "default 30m line with marker" ;;
  *) bad "default line wrong: $L" ;;
esac
L15="$("$SCHED" line --interval 15)"
case "$L15" in "*/15 * * * * "*) ok "interval honored" ;; *) bad "interval wrong: $L15" ;; esac
"$SCHED" line --interval 0   >/dev/null 2>&1 && bad "interval 0 should fail"  || ok "rejects interval 0"
"$SCHED" line --interval 99  >/dev/null 2>&1 && bad "interval 99 should fail" || ok "rejects interval > 59"
"$SCHED" line --interval foo >/dev/null 2>&1 && bad "non-numeric should fail" || ok "rejects non-numeric interval"

echo "— run: drains the queue —"
: > "$STUB_LOG"
"$QCMD" add demo "task-1" >/dev/null
"$QCMD" add demo "task-2" >/dev/null
"$SCHED" run >"$TMP/run.out" 2>&1
[ "$(count pending)" = 0 ] && ok "run emptied pending" || bad "pending left: $(count pending)"
[ "$(count done)" = 2 ]    && ok "run shipped both tasks" || bad "done=$(count done)"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 2 ] && ok "shipyard called twice" || bad "ship calls=$(cat "$STUB_LOG")"
grep -q 'drain start' "$TMP/run.out" && grep -q 'drain end' "$TMP/run.out" \
  && ok "run logs start/end markers" || bad "run missing markers: $(cat "$TMP/run.out")"

echo "— run: releases its lock —"
[ -d "$FARM_HOME/queue/.scheduler.lock" ] && bad "lock not released" || ok "lock released after run"

echo "— run: overlap is skipped (lock held) —"
: > "$STUB_LOG"
for i in 1 2 3; do "$QCMD" add demo "octask-$i" >/dev/null; done
STUB_SLEEP=0.3 "$SCHED" run >/dev/null 2>&1 &
RP=$!
sleep 0.1   # first run has claimed the lock and is mid-drain
SECOND="$("$SCHED" run 2>&1)"
wait "$RP"
case "$SECOND" in *"already running"*) ok "second concurrent run skips via lock" ;; *) bad "no skip: $SECOND" ;; esac
[ "$(count pending)" = 0 ] && ok "first run still drained everything" || bad "pending left: $(count pending)"

echo "— status: reports queue + schedule state —"
OUT="$("$SCHED" status 2>&1)"
case "$OUT" in *"queue:"*) ok "status shows queue line" ;; *) bad "status output: $OUT" ;; esac

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
