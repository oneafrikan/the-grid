#!/usr/bin/env bash
# tests/helpers/stubs.bash — THE stub helper for every bats test that needs fake
# external commands (G5: extend this file, never fork it).
#
#   load helpers/stubs
#   make_stubs [--claude-in-local-bin]     # in setup(); needs $HOME already pointed at a temp dir
#   clean_stubs                            # in teardown()
#
# make_stubs creates a temp stub dir, PREPENDS it to PATH and writes fake
#   gh  claude  loginctl  timeout
# Every stub appends one line of its argv to $STUB_LOG (empty args are shown as
# "", newlines as spaces, so one call is one line and `--tools ""` greps
# literally). Nothing here makes a network call or a model call.
# `claude` is also exported as $GRID_CLAUDE (agent-factory/run_evals.py
# convention), so code that honours that variable reaches the stub.
# With --claude-in-local-bin the claude stub lives in $HOME/.local/bin and that
# dir is NOT added to PATH (to test the runner's own PATH handling for a native
# install).
#
# Variables a test may set (all optional; read at call time by the stubs):
#   STUB_LOG                 where calls are logged (default $STUB_DIR/calls.log)
#
#   claude
#     STUB_CLAUDE_EXIT       exit status of a `-p` call (default 0)
#     STUB_CLAUDE_JSON       stdout of a `-p ... --output-format json` call
#                            (default a success result with total_cost_usd 0.01)
#     STUB_CLAUDE_HELP       text printed for `claude --help` (default: no --max-turns)
#     STUB_CLAUDE_LOGGED_IN  1 (default) or 0: `claude auth status --json`
#     `claude --help` and `claude auth status` are NOT logged: they are not model calls.
#
#   gh
#     STUB_PR_NUMBER         number printed by `gh pr view --json number -q .number`
#                            (default empty: exit 1 "no pull requests found")
#     STUB_LABELS            JSON printed by `gh label list ... --json name` (default [])
#     STUB_GH_STORED_LOGIN   1 makes `gh auth status` succeed (default: it fails)
#
#   loginctl
#     STUB_LINGER            value printed for `show-user ... --value` (default yes)
#     STUB_LOGINCTL_FAIL     1 makes every loginctl call exit 1
#
#   timeout
#     Drops `-k N` / `--kill-after N` and the SECS argument, then execs the rest.

make_stubs() {
  local claude_in_local_bin=0
  [ "${1:-}" = "--claude-in-local-bin" ] && claude_in_local_bin=1

  STUB_DIR="$(mktemp -d)"
  export STUB_DIR
  : "${STUB_LOG:=$STUB_DIR/calls.log}"
  export STUB_LOG
  : > "$STUB_LOG"

  local claude_dir="$STUB_DIR"
  if [ "$claude_in_local_bin" = 1 ]; then
    claude_dir="$HOME/.local/bin"
    mkdir -p "$claude_dir"
  fi

  # ---- shared logging library, sourced by every stub (absolute path) ----
  # stub_log <name> <args...>: one line per call, empty args as "", newlines as spaces.
  local lib="$STUB_DIR/.stub-lib.sh"
  cat > "$lib" <<'EOF'
stub_log() {
  local line="$1"; shift
  local a
  for a in "$@"; do
    if [ -z "$a" ]; then line="$line \"\""; else line="$line ${a//$'\n'/ }"; fi
  done
  printf '%s\n' "$line" >> "${STUB_LOG:-/dev/null}"
}
EOF

  # ---- claude ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
case "${1:-}" in
  --help|-h)
    if [ -n "${STUB_CLAUDE_HELP:-}" ]; then printf '%s\n' "$STUB_CLAUDE_HELP"
    else printf 'Usage: claude [options]\n  --model <m>\n  --max-budget-usd <n>\n  --output-format <f>\n'; fi
    exit 0 ;;
  auth)
    if [ "${STUB_CLAUDE_LOGGED_IN:-1}" = 1 ]; then echo '{"loggedIn": true, "authMethod": "stub"}'
    else echo '{"loggedIn": false}'; fi
    exit 0 ;;
esac
stub_log claude "$@"
# A real `claude -p` waits for EOF on stdin; the stub drains it the same way.
cat > /dev/null
want_json=0
prev=""
for a in "$@"; do
  if [ "$prev" = "--output-format" ] && [ "$a" = "json" ]; then want_json=1; fi
  prev="$a"
done
if [ "$want_json" = 1 ]; then
  default_json='{"type":"result","subtype":"success","is_error":false,"result":"stub result","total_cost_usd":0.01}'
  printf '%s\n' "${STUB_CLAUDE_JSON:-$default_json}"
else
  echo "- [nit] stub review"
  echo "VERDICT: approve"
fi
exit "${STUB_CLAUDE_EXIT:-0}"
EOF
  } > "$claude_dir/claude"
  chmod +x "$claude_dir/claude"
  GRID_CLAUDE="$claude_dir/claude"
  export GRID_CLAUDE

  # ---- gh ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
stub_log gh "$@"
case "${1:-} ${2:-}" in
  "pr view")
    if [ -n "${STUB_PR_NUMBER:-}" ]; then echo "$STUB_PR_NUMBER"; exit 0; fi
    echo "no pull requests found" >&2; exit 1 ;;
  "label list") printf '%s\n' "${STUB_LABELS:-[]}"; exit 0 ;;
  "auth status")
    if [ "${STUB_GH_STORED_LOGIN:-0}" = 1 ]; then exit 0; fi
    echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
esac
exit 0
EOF
  } > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"

  # ---- loginctl ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
stub_log loginctl "$@"
if [ "${STUB_LOGINCTL_FAIL:-0}" = 1 ]; then exit 1; fi
case "${1:-}" in
  show-user) echo "${STUB_LINGER:-yes}" ;;
esac
exit 0
EOF
  } > "$STUB_DIR/loginctl"
  chmod +x "$STUB_DIR/loginctl"

  # ---- timeout (GNU semantics we rely on: [-k N] SECS cmd...) ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
stub_log timeout "$@"
while [ "${1:-}" = "-k" ] || [ "${1:-}" = "--kill-after" ]; do
  shift 2
done
shift   # SECS
exec "$@"
EOF
  } > "$STUB_DIR/timeout"
  chmod +x "$STUB_DIR/timeout"

  PATH="$STUB_DIR:$PATH"
  export PATH
}

clean_stubs() {
  if [ -n "${STUB_DIR:-}" ]; then rm -rf "$STUB_DIR"; fi
  unset STUB_DIR STUB_LOG GRID_CLAUDE
}
