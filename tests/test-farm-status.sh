#!/usr/bin/env bash
# Tests for bin/farm-status: terminal, JSON, and local web status.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS="$ROOT/bin/farm-status"
TMP="$(mktemp -d)"
cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export FARM_HOME="$TMP/farm"

mkdir -p "$FARM_HOME/control/runs" "$FARM_HOME/queue/pending" "$FARM_HOME/queue/done" "$FARM_HOME/queue/logs"

cat > "$FARM_HOME/control/runs/run-1.run" <<'RUN'
id: run-1
state: phase-2
mode: pipeline
repo: demo
task: ship status view
agents: 2
session: farm-test
phase: 2
max_phase: 5
manifest: /tmp/run-1.subtasks
supervisor_pane: %1
worker_panes: %2 %3
created: 2026-06-18T00:00:00Z
RUN

cat > "$FARM_HOME/queue/pending/task-a.task" <<'TASK'
repo: demo
task: implement status
run: run-1
phase: 2
TASK

cat > "$FARM_HOME/queue/done/task-b.task" <<'TASK'
repo: demo
task: plan work
run: run-1
phase: 1
TASK

echo "shipped" > "$FARM_HOME/queue/logs/task-b.log"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
has() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 — got: $2" ;; esac; }

echo "— text status —"
OUT="$("$STATUS")"
has "run-1" "$OUT" "text lists run"
has "pending 1" "$OUT" "text shows pending count"
has "workers %2 %3" "$OUT" "text shows workers"

echo "— json status —"
JSON="$("$STATUS" --json)"
python3 - "$JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
run = d["runs"][0]
assert run["id"] == "run-1"
assert run["counts"]["pending"] == 1
assert run["counts"]["done"] == 1
PY
[ $? -eq 0 ] && ok "json parses and counts" || bad "json parse/count failed"

echo "— run filter —"
EMPTY="$("$STATUS" --run missing)"
has "no runs" "$EMPTY" "missing run filter is empty"

echo "— web status —"
"$STATUS" serve --host 127.0.0.1 --port 18765 --refresh 1 >"$TMP/server.out" 2>"$TMP/server.err" &
SERVER_PID=$!
for _ in 1 2 3 4 5; do
  HTML="$(curl -fsS http://127.0.0.1:18765/ 2>/dev/null)" && break
  sleep 0.2
done
has "farm status" "${HTML:-}" "web page serves"
API="$(curl -fsS http://127.0.0.1:18765/api/runs 2>/dev/null)"
has '"id": "run-1"' "$API" "api serves json"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
