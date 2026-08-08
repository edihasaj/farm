#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMX="$ROOT/bin/cmx"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/args"
for binary in cmux mosh; do
  cp /dev/null "$TMP/$binary"
done
cat >"$TMP/runner" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CMX_TEST_LOG"
EOF
chmod +x "$TMP/runner"
ln -sf "$TMP/runner" "$TMP/cmux"
ln -sf "$TMP/runner" "$TMP/mosh"
cat >"$TMP/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${CMX_TEST_SESSIONS:-}"
EOF
chmod +x "$TMP/ssh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
assert_line() {
  if grep -Fxq -- "$1" "$LOG"; then ok "$2"; else bad "$2"; fi
}
assert_project_dir() {
  if grep -Fq "directory=~/$1" "$LOG" || grep -Fq "directory=\\~/$1" "$LOG"; then
    ok "$2"
  else
    bad "$2"
  fi
}

CMX_MOSH_BIN="$TMP/mosh" CMX_SSH_BIN="$TMP/ssh" CMX_TEST_LOG="$LOG" "$CMX" projectx
assert_line '--predict=adaptive' 'uses resilient Mosh transport'
assert_line studio 'defaults to the Studio SSH alias'
if grep -Fq 'session=projectx' "$LOG"; then ok 'uses the project for the primary tmux session'; else bad 'uses the project for the primary tmux session'; fi
assert_project_dir Projects/projectx 'starts in the project directory'
if grep -Fq 'new-session -d -s "$session" -c "$directory" -e ZDOTDIR="$HOME"' "$LOG" && grep -Fq 'set-environment -t "$target" ZDOTDIR "$HOME"' "$LOG"; then ok 'loads the real zsh startup directory'; else bad 'loads the real zsh startup directory'; fi
if grep -Fq 'remain-on-exit off' "$LOG" && grep -Fq 'set-hook -uw' "$LOG"; then ok 'lets exit close a current-terminal session'; else bad 'lets exit close a current-terminal session'; fi
if grep -Fq 'target="=$session"; window_target="=$session:"' "$LOG" && grep -Fq 'attach-session -t "$target"' "$LOG"; then ok 'uses exact tmux session matching'; else bad 'uses exact tmux session matching'; fi

CMX_TEST_SESSIONS=$'oktapod\noktapod-2' CMX_MOSH_BIN="$TMP/mosh" CMX_SSH_BIN="$TMP/ssh" CMX_TEST_LOG="$LOG" "$CMX" oktapod --new
if grep -Fq 'session=oktapod-3' "$LOG"; then ok '--new selects the next independent session'; else bad '--new selects the next independent session'; fi
assert_project_dir Projects/oktapod '--new keeps the original project directory'

CMX_MOSH_BIN="$TMP/mosh" CMX_SSH_BIN="$TMP/ssh" CMX_TEST_LOG="$LOG" "$CMX" oktapod --slot review
if grep -Fq 'session=oktapod-review' "$LOG"; then ok '--slot creates an explicit independent session'; else bad '--slot creates an explicit independent session'; fi
assert_project_dir Projects/oktapod '--slot keeps the original project directory'

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" api --workspace --slot 2 --host gpu-box --dir '~/work/api' --name backend --no-focus
assert_line mosh-tmux '--workspace retains native cmux transport'
assert_line api-2 '--workspace uses the selected session slot'
assert_line gpu-box '--workspace accepts a host override'
assert_line backend '--workspace accepts a title override'
assert_line --no-focus '--workspace passes native cmux flags through'
if grep -Fq 'cd -- "$HOME"/work/api' "$LOG"; then ok '--workspace accepts a remote directory override'; else bad '--workspace accepts a remote directory override'; fi
if grep -Fq 'tmux set-environment ZDOTDIR "${CMUX_REAL_ZDOTDIR:-$HOME}"' "$LOG"; then ok '--workspace respawns with the real zsh startup directory'; else bad '--workspace respawns with the real zsh startup directory'; fi
if grep -Fq 'remain-on-exit on' "$LOG" && grep -Fq 'respawn-pane -k -t #{hook_pane}' "$LOG"; then ok '--workspace keeps its shell available for app restore'; else bad '--workspace keeps its shell available for app restore'; fi

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" api -w --slot 3
assert_line mosh-tmux '-w selects native cmux transport'
assert_line api-3 '-w preserves session-slot behavior'

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" restore
if [[ $(cat "$LOG") == restore-session ]]; then ok 'restore maps to the native app snapshot'; else bad 'restore maps to the native app snapshot'; fi

CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" list
if [[ $(paste -sd ' ' "$LOG") == 'workspace list' ]]; then ok 'list uses the current native workspace command'; else bad 'list uses the current native workspace command'; fi

if CMUX_BIN="$TMP/cmux" CMX_TEST_LOG="$LOG" "$CMX" 'bad:name' >/dev/null 2>&1; then
  bad 'rejects invalid tmux session names'
else
  ok 'rejects invalid tmux session names'
fi

if CMX_MOSH_BIN="$TMP/mosh" CMX_SSH_BIN="$TMP/ssh" CMX_TEST_LOG="$LOG" "$CMX" oktapod --new --slot 2 >/dev/null 2>&1; then
  bad 'rejects ambiguous --new plus --slot'
else
  ok 'rejects ambiguous --new plus --slot'
fi

printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
