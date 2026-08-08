#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMX="$ROOT/bin/cmx"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/args"
cat >"$TMP/cmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CMX_TEST_LOG"
EOF
chmod +x "$TMP/cmux"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
assert_line() {
  if grep -Fxq -- "$1" "$LOG"; then ok "$2"; else bad "$2"; fi
}

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" projectx
assert_line mosh-tmux 'uses native mosh-tmux transport'
assert_line studio 'defaults to the Studio SSH alias'
assert_line projectx 'uses the project for the tmux session and title'
assert_line 'cd -- "$HOME"/Projects/projectx 2>/dev/null || cd -- "$HOME/Projects"' 'starts in the project with a safe fallback'

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" api --host gpu-box --dir '~/work/api' --name backend --no-focus
assert_line gpu-box 'accepts a host override'
assert_line backend 'accepts a title override'
assert_line --no-focus 'passes native cmux flags through'
assert_line 'cd -- "$HOME"/work/api' 'accepts a remote directory override'

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" restore
if [[ $(cat "$LOG") == restore-session ]]; then ok 'restore maps to the native app snapshot'; else bad 'restore maps to the native app snapshot'; fi

if CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" 'bad:name' >/dev/null 2>&1; then
  bad 'rejects invalid tmux session names'
else
  ok 'rejects invalid tmux session names'
fi

printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
