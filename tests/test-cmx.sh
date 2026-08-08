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
if [[ $* == *list-sessions* ]]; then
  printf '%s\n' "${CMX_TEST_SESSIONS:-}"
else
  printf '%s\n' "$@" >"$CMX_TEST_LOG"
fi
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

CMX_SSH_BIN="$TMP/runner" CMX_TEST_LOG="$LOG" "$CMX" projectx
assert_line '-tt' 'uses foreground SSH transport'
assert_line 'ServerAliveInterval=20' 'keeps SSH failures bounded'
assert_line 'ControlMaster=auto' 'enables cmux drag-and-drop uploads'
assert_line studio 'defaults to the Studio SSH alias'
if grep -Fq 'session=projectx' "$LOG"; then ok 'uses the project for the primary tmux session'; else bad 'uses the project for the primary tmux session'; fi
assert_project_dir Projects/projectx 'starts in the project directory'
if grep -Fq 'ZDOTDIR' "$LOG" && grep -Fq 'set-environment' "$LOG"; then ok 'loads the real zsh startup directory'; else bad 'loads the real zsh startup directory'; fi
if grep -Fq 'remain-on-exit' "$LOG" && grep -Fq 'pane-died' "$LOG"; then ok 'lets exit close a current-terminal session'; else bad 'lets exit close a current-terminal session'; fi
if grep -Fq 'window-size' "$LOG" && grep -Fq 'latest' "$LOG"; then ok 'resizes restored tmux windows to the current client'; else bad 'resizes restored tmux windows to the current client'; fi
if grep -Fq 'target=' "$LOG" && grep -Fq 'attach-session' "$LOG"; then ok 'uses exact tmux session matching'; else bad 'uses exact tmux session matching'; fi

CMX_TEST_SESSIONS=$'oktapod\noktapod-2' CMX_MOSH_BIN="$TMP/mosh" CMX_SSH_BIN="$TMP/ssh" CMX_TEST_LOG="$LOG" "$CMX" oktapod --new
if grep -Fq 'session=oktapod-3' "$LOG"; then ok '--new selects the next independent session'; else bad '--new selects the next independent session'; fi
assert_project_dir Projects/oktapod '--new keeps the original project directory'

CMX_MOSH_BIN="$TMP/mosh" CMX_SSH_BIN="$TMP/ssh" CMX_TEST_LOG="$LOG" "$CMX" oktapod --slot review
if grep -Fq 'session=oktapod-review' "$LOG"; then ok '--slot creates an explicit independent session'; else bad '--slot creates an explicit independent session'; fi
assert_project_dir Projects/oktapod '--slot keeps the original project directory'

CMUX_BIN="$TMP/cmux" XDG_CONFIG_HOME="$TMP/config" CMX_TEST_LOG="$LOG" "$CMX" api --workspace --slot 2 --host gpu-box --dir '~/work/api' --name backend --no-focus
assert_line 'workspace' '--workspace creates a local cmux workspace'
assert_line 'create' '--workspace uses workspace create'
assert_line backend '--workspace accepts a title override'
assert_line false '--no-focus keeps the new workspace in the background'
if grep -Fq -- '--attach' "$LOG" && grep -Fq 'gpu-box' "$LOG" && grep -Fq 'api-2' "$TMP/config/farm/cmx-workspaces.tsv"; then ok '--workspace registers an SSH/tmux restore command'; else bad '--workspace registers an SSH/tmux restore command'; fi

CMUX_BIN="$TMP/cmux" XDG_CONFIG_HOME="$TMP/config" CMX_TEST_LOG="$LOG" "$CMX" api -w --slot 3
assert_line 'workspace' '-w selects local cmux workspace mode'
if grep -Fq 'api-3' "$TMP/config/farm/cmx-workspaces.tsv"; then ok '-w preserves session-slot behavior'; else bad '-w preserves session-slot behavior'; fi

if CMUX_BIN="$TMP/cmux" CMX_SSH_BIN="$TMP/ssh" XDG_CONFIG_HOME="$TMP/empty" CMX_TEST_LOG="$LOG" "$CMX" restore >/dev/null 2>&1; then
  bad 'restore reports a missing registry'
else
  ok 'restore reports a missing registry'
fi

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
