#!/usr/bin/env bash
# Tests for bin/farm-queue + bin/farm-loop. No real agents: shipyard is stubbed.
# Run: tests/test-farm-loop.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QCMD="$ROOT/bin/farm-queue"
LOOP="$ROOT/bin/farm-loop"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FARM_HOME="$TMP/farm"
mkdir -p "$TMP/demo-repo"

# shipyard stub: records args, optional sleep, fails on "boom"
export STUB_LOG="$TMP/ship-calls.log"
cat > "$TMP/shipyard" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-p" ] && shift
echo "SHIP $*" >> "$STUB_LOG"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
case "$*" in *boom*) echo "kaboom" ; exit 1 ;; esac
echo "shipped: $*"
EOF
chmod +x "$TMP/shipyard"
export FARM_LOOP_SHIP="$TMP/shipyard"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}
count() { ls -1 "$FARM_HOME/queue/$1" 2>/dev/null | wc -l | tr -d ' '; }

echo "— add / validate —"
ID1="$("$QCMD" add demo "small thing" use ../agent-scripts tooling)"
check "add returns an id" 0 $?
check "pending has 1" 1 "$(count pending)"
ID2="$("$QCMD" add arbitrary "shipyard resolves this")" \
  && ok "add accepts repo keys without local config" || bad "add should defer repo validation to shipyard"
"$QCMD" rm "$ID2"
"$QCMD" add demo >/dev/null 2>&1 \
  && bad "add without task should fail" || ok "add without task fails"
LISTED="$("$QCMD" list pending)"
case "$LISTED" in
  *demo*"small thing"*) ok "list shows repo + task" ;;
  *) bad "list shows repo + task — got: $LISTED" ;;
esac

echo "— claim / done —"
GOT="$("$QCMD" next)"
check "next claims FIFO head" "$ID1" "$GOT"
check "running has 1" 1 "$(count running)"
"$QCMD" next >/dev/null 2>&1 && bad "next on empty should fail" || ok "next on empty fails"
"$QCMD" done "$ID1"
check "done moved task" 1 "$(count done)"
check "running empty after done" 0 "$(count running)"

echo "— loop --drain: mixed batch (incl. URL task + failure) —"
: > "$STUB_LOG"
"$QCMD" add demo "task-a" >/dev/null
"$QCMD" add demo "boom please" >/dev/null
"$QCMD" add https://github.com/edihasaj/farm/issues/1 >/dev/null
"$LOOP" --drain >"$TMP/loop.out" 2>&1
check "drain exits nonzero when a task failed" 1 $?
check "2 done (was 1)" 3 "$(count done)"
check "1 failed" 1 "$(count failed)"
check "pending empty" 0 "$(count pending)"
check "shipyard called 3x" 3 "$(wc -l < "$STUB_LOG" | tr -d ' ')"
grep -q '^SHIP demo task-a$' "$STUB_LOG" \
  && ok "repo task args passed through" || bad "repo task args passed through"
grep -q '^SHIP https://github.com/edihasaj/farm/issues/1$' "$STUB_LOG" \
  && ok "URL task passed as single arg (shipyard infers repo)" || bad "URL task arg wrong"
BOOM_ID="$(ls -1 "$FARM_HOME/queue/failed" | sed 's/\.task$//')"
grep -q kaboom "$FARM_HOME/queue/logs/$BOOM_ID.log" \
  && ok "failed task captured shipyard output in log" || bad "missing failure log"

echo "— notes pass through as extra words —"
: > "$STUB_LOG"
NID="$("$QCMD" add demo "task-n" focus on perf)"
"$LOOP" --once >/dev/null 2>&1
grep -q '^SHIP demo task-n focus on perf$' "$STUB_LOG" \
  && ok "notes appended after task" || bad "notes lost: $(cat "$STUB_LOG")"

echo "— retry —"
"$QCMD" retry "$BOOM_ID"
check "retry: failed -> pending" 1 "$(count pending)"
check "failed empty after retry" 0 "$(count failed)"
"$QCMD" rm "$BOOM_ID"
check "rm drops the task" 0 "$(count pending)"

echo "— show —"
SID="$("$QCMD" add demo "show-me")"
OUT="$("$QCMD" show "$SID")"
case "$OUT" in
  *"state: pending"*"task: show-me"*) ok "show prints state + fields" ;;
  *) bad "show output wrong: $OUT" ;;
esac
"$QCMD" rm "$SID"

echo "— concurrency: 2 workers, no double-claims —"
: > "$STUB_LOG"
for i in 1 2 3 4 5 6; do "$QCMD" add demo "ctask-$i" >/dev/null; done
STUB_SLEEP=0.2 "$LOOP" --drain >/dev/null 2>&1 &
W1=$!
STUB_SLEEP=0.2 "$LOOP" --drain >/dev/null 2>&1 &
W2=$!
wait "$W1"; wait "$W2"
check "all 6 processed exactly once" 6 "$(sort "$STUB_LOG" | uniq | wc -l | tr -d ' ')"
check "shipyard called exactly 6x" 6 "$(wc -l < "$STUB_LOG" | tr -d ' ')"
check "pending drained" 0 "$(count pending)"
check "nothing stuck in running" 0 "$(count running)"

echo "— farm-loop uses configured shipyard command —"
: > "$STUB_LOG"
"$QCMD" add demo "shipyard-task" >/dev/null
"$LOOP" --once >/dev/null 2>&1
grep -q '^SHIP demo shipyard-task$' "$STUB_LOG"   && ok "farm-loop invokes shipyard-compatible command" || bad "shipyard stub not called: $(cat "$STUB_LOG")"

echo "— interrupt requeues the in-flight task —"
# TERM, not INT: shells started with & ignore SIGINT (POSIX async-child rule)
"$QCMD" add demo "interrupt-me" >/dev/null
STUB_SLEEP=1 "$LOOP" >/dev/null 2>&1 &
WPID=$!
sleep 0.4   # long enough for the worker to claim and start ship
kill -TERM "$WPID" 2>/dev/null
wait "$WPID"
check "INT mid-task: back in pending" 1 "$(count pending)"
check "INT mid-task: running empty" 0 "$(count running)"
"$QCMD" rm "$(ls -1 "$FARM_HOME/queue/pending" | sed 's/\.task$//')"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
