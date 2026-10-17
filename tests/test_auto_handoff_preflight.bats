#!/usr/bin/env bats
# Tests for scripts/auto-handoff-preflight.sh — the four live checks that gate turning
# auto-handoff on (env propagation, B1 rule form, WP-016 flag parity, env -i auth) and the
# --enable / --disable switch.
#
# Safety: `claude` is ALWAYS the local stub below (GRID_PREFLIGHT_CLAUDE); a tripwire
# `claude` sits first on PATH and fails the test if the script ever reaches it. GRID_DIR,
# the baseline, the machines/ overlay and the wire.sh it calls are a temp grid; HOME, the
# Claude config dir and the backup (state) dir are temp dirs. No model is called, no real
# machines/ file or ~/.claude is touched.
#
# The stub lives in this file, not in tests/helpers/stubs.bash: its modes are specific to
# these probes (it even runs the hook command a probe's settings.json declares, to model
# whether the project env block reaches hooks), and none of it is reusable elsewhere.
#
# These are the author's own checks; independent verification belongs to qa-engineer.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  # Same leak guard as test_auto_handoff.bats: every temp dir (including the script's own
  # scratch root) lands in the per-test dir bats removes itself.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  common_setup
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

  PF="$REPO_ROOT/scripts/auto-handoff-preflight.sh"

  # A temp grid: baseline, machine overlay, and a wire.sh that only records its call.
  PF_GRID="$MOCK_HOOK_ROOT/grid"
  mkdir -p "$PF_GRID/machines" "$PF_GRID/scripts"
  printf '# baseline\nanthropic\n' > "$PF_GRID/baseline.txt"
  printf '# test overlay\nproject:foo\n-hook:auto-handoff   # off until the preflight passes\nrepo/skill\n' \
    > "$PF_GRID/machines/testhost.txt"
  cat > "$PF_GRID/scripts/wire.sh" <<'EOF'
#!/usr/bin/env bash
# test double for wire.sh: record the call, touch nothing else
echo "wire GRID_DIR=$GRID_DIR" >> "$GRID_DIR/wire.calls"
exit "${STUB_WIRE_EXIT:-0}"
EOF
  export GRID_DIR="$PF_GRID" GRID_HOST=testhost GRID_BASELINE="$PF_GRID/baseline.txt"
  export GRID_STATE_DIR="$MOCK_HOOK_ROOT/grid-state"
  BACKUPS="$GRID_STATE_DIR/preflight-backups"

  # Tripwire first on PATH: the script must only ever call $GRID_PREFLIGHT_CLAUDE.
  TRIP="$BATS_TEST_TMPDIR/trip"; mkdir -p "$TRIP"
  printf '#!/bin/sh\necho called > "%s/tripped"\nexit 99\n' "$BATS_TEST_TMPDIR" > "$TRIP/claude"
  chmod +x "$TRIP/claude"
  export PATH="$TRIP:$PATH"

  make_claude_stub
  export GRID_PREFLIGHT_CLAUDE="$BATS_TEST_TMPDIR/stub/claude"
  export STUB_LOG="$BATS_TEST_TMPDIR/claude.log"
  # The auth probe runs under `env -i`; the stub reads its STUB_* knobs from the environment.
  export GRID_AUTOHANDOFF_KEEP_ENV='STUB_*'
  unset ANTHROPIC_API_KEY GRID_PREFLIGHT_TIMEOUT
}

teardown() {
  [ ! -e "$BATS_TEST_TMPDIR/tripped" ] || { echo "the real claude on PATH was called" >&2; common_teardown; return 1; }
  common_teardown
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# make_claude_stub: behaviour is chosen by the prompt (each probe has a distinct marker) and
# by STUB_* variables. Every -p call is logged as one line: "cwd=<dir> key=<value|unset> argv".
make_claude_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  cat > "$BATS_TEST_TMPDIR/stub/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  # STUB_HELP_DROP removes the line naming one flag (the flag-parity check reads --help).
  printf '%s\n' "Usage: claude [options]" "  --permission-mode <mode>" \
    "  --setting-sources <sources>" "  --strict-mcp-config" "  --max-budget-usd <amount>" \
    | grep -v -F -- "${STUB_HELP_DROP:-@@none@@}"
  exit 0
fi
prompt="${2:-}"
echo "cwd=$PWD key=${ANTHROPIC_API_KEY-unset} argv=$*" >> "$STUB_LOG"
case "$prompt" in
  PREFLIGHT-ENV*)
    # Model Claude Code's hook runner: run every hook command the project's settings.json
    # declares, with the project env block applied (propagate), not applied (isolate), or no
    # hook run at all (nohook).
    marker="$(sed -n 's/^ *"GRID_PREFLIGHT_MARKER": "\([^"]*\)" *$/\1/p' .claude/settings.json)"
    case "${STUB_ENV_MODE:-isolate}" in
      propagate) sed -n 's/^ *"command": "\(.*\)" *$/\1/p' .claude/settings.json |
                   while IFS= read -r c; do GRID_PREFLIGHT_MARKER="$marker" sh -c "$c"; done ;;
      isolate)   sed -n 's/^ *"command": "\(.*\)" *$/\1/p' .claude/settings.json |
                   while IFS= read -r c; do env -u GRID_PREFLIGHT_MARKER sh -c "$c"; done ;;
      nohook)    ;;
    esac
    echo ok; exit 0 ;;
  *outside.txt*)
    # B1 rule-form probe: cwd is the scratch repo.
    case "${STUB_B1_MODE:-good}" in
      good)         echo x > LOGS/inside.txt ;;
      bad-outside)  echo x > LOGS/inside.txt; echo x > outside.txt ;;
      bad-inside)   : ;;
    esac
    exit 0 ;;
  *ok.txt*)
    # B1 second probe: .git deny and the Bash(ls:*) redirect question.
    case "${STUB_B1B_MODE:-good}" in
      good)         echo x > ok.txt ;;
      bad-git)      echo x > ok.txt; echo x > .git/probe.txt ;;
      bad-redirect) echo x > ok.txt; ls > redirect.txt ;;
      bad-nothing)  : ;;
    esac
    exit 0 ;;
  PREFLIGHT-FLAGS*)
    if [ "${STUB_FAIL_FLAGS:-0}" = 1 ]; then echo "error: unknown option '--strict-mcp-config'" >&2; exit 1; fi
    echo ok; exit 0 ;;
  PREFLIGHT-AUTH*)
    if [ "${STUB_NEEDS_KEY:-0}" = 1 ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      echo "Invalid API key - Please run /login"; exit 1
    fi
    if [ "${STUB_AUTH_OTHER_FAIL:-0}" = 1 ]; then echo "boom: disk on fire"; exit 3; fi
    echo ok; exit 0 ;;
esac
echo "stub: unexpected prompt: $prompt" >&2
exit 97
EOF
  chmod +x "$BATS_TEST_TMPDIR/stub/claude"
}

pf() { run bash "$PF" "$@"; }

n_calls() { if [ -f "$STUB_LOG" ]; then wc -l < "$STUB_LOG" | tr -d ' '; else echo 0; fi; }
n_wire() { if [ -f "$PF_GRID/wire.calls" ]; then wc -l < "$PF_GRID/wire.calls" | tr -d ' '; else echo 0; fi; }
n_backups() { if [ -d "$BACKUPS" ]; then find "$BACKUPS" -type f | wc -l | tr -d ' '; else echo 0; fi; }
overlay() { cat "$PF_GRID/machines/testhost.txt"; }

# ---------------------------------------------------------------------------
# --check (default): read-only
# ---------------------------------------------------------------------------

@test "all pass: four PASS lines, a PASS verdict, exit 0, and nothing is changed" {
  local before; before="$(overlay)"
  pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +env-propagation\ +DOES-NOT-PROPAGATE ]]
  [[ "$output" =~ PASS\ +b1-rule-form ]]
  [[ "$output" =~ PASS\ +wp016-parity ]]
  [[ "$output" =~ PASS\ +env-i-auth ]]
  [[ "$output" =~ VERDICT:\ PASS ]]
  # read-only: overlay untouched, wire.sh never called, no backup
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
  [ "$(n_backups)" -eq 0 ]
}

@test "--check is the default and the explicit flag behaves the same" {
  pf --check
  [ "$status" -eq 0 ]
  [[ "$output" =~ VERDICT:\ PASS ]]
}

@test "the spend cap is printed before the first check and every claude call carries it" {
  pf
  [ "$status" -eq 0 ]
  # cap line comes before the first check line
  local cap_line first_check
  cap_line="$(printf '%s\n' "$output" | grep -n 'spend cap' | head -1 | cut -d: -f1)"
  first_check="$(printf '%s\n' "$output" | grep -n -E '^(PASS|FAIL) ' | head -1 | cut -d: -f1)"
  [ -n "$cap_line" ]
  [ "$cap_line" -lt "$first_check" ]
  [[ "$output" =~ USD\ 0\.50 ]]
  # five live calls, each hard-capped and on the cheapest model
  [ "$(n_calls)" -eq 5 ]
  [ "$(grep -c -- '--max-budget-usd 0.10' "$STUB_LOG")" -eq 5 ]
  [ "$(grep -c -- '--model haiku' "$STUB_LOG")" -eq 5 ]
}

@test "scratch dirs are removed on exit" {
  pf
  [ "$status" -eq 0 ]
  ! ls "$TMPDIR" | grep -q '^grid-preflight\.' || false
}

@test "env-propagation PROPAGATES: warns loudly, names the variables, does not fail --check" {
  STUB_ENV_MODE=propagate pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +env-propagation\ +PROPAGATES ]]
  [[ "$output" =~ WARN.*repos\ you\ trust ]]
  [[ "$output" =~ GRID_HOOKS ]]
  [[ "$output" =~ GRID_PRIVATE_DIR ]]
  [[ "$output" =~ GRID_CLAUDE ]]
  [[ "$output" =~ GRID_AUTOHANDOFF_KEEP_ENV ]]
  [[ "$output" =~ --accept-env-risk ]]
}

@test "env-propagation: the hook never ran -> FAIL (inconclusive), not a silent pass" {
  STUB_ENV_MODE=nohook pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +env-propagation.*INCONCLUSIVE ]]
  [[ "$output" =~ VERDICT:\ FAIL ]]
}

@test "b1: a write outside the allowed dir -> FAIL" {
  STUB_B1_MODE=bad-outside pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*outside\.txt ]]
}

@test "b1: the allowed write missing -> FAIL" {
  STUB_B1_MODE=bad-inside pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*inside\.txt ]]
}

@test "b1: a write under .git despite the deny -> FAIL" {
  STUB_B1B_MODE=bad-git pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*\.git ]]
}

@test "b1: Bash(ls:*) accepting a redirect -> FAIL" {
  STUB_B1B_MODE=bad-redirect pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*redirect ]]
}

@test "b1: positive control missing (ok.txt not written) -> FAIL, absences prove nothing" {
  STUB_B1B_MODE=bad-nothing pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*ok\.txt ]]
}

@test "wp016: claude rejecting the worker's flags -> FAIL" {
  STUB_FAIL_FLAGS=1 pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +wp016-parity ]]
}

@test "wp016: --help not naming a flag -> FAIL without a paid call for that check" {
  STUB_HELP_DROP=--strict-mcp-config pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +wp016-parity.*--strict-mcp-config ]]
  [ "$(grep -c 'PREFLIGHT-FLAGS' "$STUB_LOG")" -eq 0 ]
}

@test "env -i auth: API-key auth fails under env -i -> FAIL with the exact remedy" {
  export ANTHROPIC_API_KEY=k STUB_NEEDS_KEY=1
  pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +env-i-auth ]]
  [[ "$output" =~ GRID_AUTOHANDOFF_KEEP_ENV=ANTHROPIC_API_KEY ]]
  # the plain run (wp016) still passed: the failure is env -i specific
  [[ "$output" =~ PASS\ +wp016-parity ]]
}

@test "env -i auth: naming the key in KEEP_ENV (the remedy) makes it pass" {
  export ANTHROPIC_API_KEY=k STUB_NEEDS_KEY=1
  GRID_AUTOHANDOFF_KEEP_ENV='STUB_*,ANTHROPIC_API_KEY' pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +env-i-auth ]]
}

@test "env -i auth: a non-auth failure fails the check but prints no remedy" {
  STUB_AUTH_OTHER_FAIL=1 pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +env-i-auth ]]
  [[ ! "$output" =~ GRID_AUTOHANDOFF_KEEP_ENV=ANTHROPIC_API_KEY ]]
}

@test "env -i auth: the child env really is minimal (stub saw no API key var)" {
  export ANTHROPIC_API_KEY=k
  pf
  [ "$status" -eq 0 ]
  # the AUTH call is the one run under env -i: key=unset on its log line
  grep 'PREFLIGHT-AUTH' "$STUB_LOG" | grep -q 'key=unset'
  grep 'PREFLIGHT-FLAGS' "$STUB_LOG" | grep -q 'key=k'
}

@test "claude binary missing -> every live check FAILs, exit 1, no crash" {
  GRID_PREFLIGHT_CLAUDE=/nonexistent/claude pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +env-propagation ]]
  [[ "$output" =~ FAIL\ +b1-rule-form ]]
  [[ "$output" =~ FAIL\ +wp016-parity ]]
  [[ "$output" =~ FAIL\ +env-i-auth ]]
}

@test "reports the overlay state: OFF when -hook:auto-handoff is present, ON when absent" {
  pf
  [[ "$output" =~ auto-handoff\ manifest\ state:\ OFF ]]
  [[ "$output" =~ machines/testhost\.txt ]]
  printf 'repo/skill\n' > "$PF_GRID/machines/testhost.txt"
  pf
  [[ "$output" =~ auto-handoff\ manifest\ state:\ ON ]]
}

@test "warns (does not fail) on a symlinked watched dotfile and a writable .bash_aliases" {
  echo real > "$HOME/zshrc.real"
  ln -s "$HOME/zshrc.real" "$HOME/.zshrc"
  : > "$HOME/.bash_aliases"
  pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ WARN.*\.zshrc.*symlink ]]
  [[ "$output" =~ WARN.*\.bash_aliases ]]
}

@test "no dotfile warnings on a clean home" {
  pf
  [[ ! "$output" =~ WARN.*symlink ]]
  [[ ! "$output" =~ WARN.*bash_aliases ]]
}

@test "unknown flag -> usage, exit 2, no claude call" {
  pf --bogus
  [ "$status" -eq 2 ]
  [ "$(n_calls)" -eq 0 ]
}

@test "two modes at once -> usage, exit 2" {
  pf --enable --disable
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# --dry-run
# ---------------------------------------------------------------------------

@test "--dry-run prints the commands, makes no claude call, changes no file" {
  local before; before="$(overlay)"
  pf --dry-run
  [ "$status" -eq 0 ]
  [ "$(n_calls)" -eq 0 ]
  [[ "$output" =~ max-budget-usd ]]
  [[ "$output" =~ USD\ 0\.50 ]]
  [ "$(overlay)" = "$before" ]
  ! ls "$TMPDIR" | grep -q '^grid-preflight\.' || false
}

@test "--enable --dry-run: no claude call, no overlay change, no backup, no wire" {
  local before; before="$(overlay)"
  pf --enable --dry-run
  [ "$status" -eq 0 ]
  [ "$(n_calls)" -eq 0 ]
  [ "$(overlay)" = "$before" ]
  [ "$(n_backups)" -eq 0 ]
  [ "$(n_wire)" -eq 0 ]
  [[ "$output" =~ wire\.sh ]]
}

@test "--disable --dry-run changes nothing" {
  printf 'repo/skill\n' > "$PF_GRID/machines/testhost.txt"
  pf --disable --dry-run
  [ "$status" -eq 0 ]
  [ "$(overlay)" = "repo/skill" ]
  [ "$(n_wire)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --enable / --disable
# ---------------------------------------------------------------------------

@test "--enable refuses when a check fails: overlay unchanged, wire.sh not called" {
  local before; before="$(overlay)"
  STUB_FAIL_FLAGS=1 pf --enable
  [ "$status" -eq 1 ]
  [[ "$output" =~ refus ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
  [ "$(n_backups)" -eq 0 ]
}

@test "--enable with PROPAGATES needs --accept-env-risk" {
  local before; before="$(overlay)"
  STUB_ENV_MODE=propagate pf --enable
  [ "$status" -eq 1 ]
  [[ "$output" =~ --accept-env-risk ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
  STUB_ENV_MODE=propagate pf --enable --accept-env-risk
  [ "$status" -eq 0 ]
  [ "$(n_wire)" -eq 1 ]
}

@test "--enable: removes only the -hook line, backs up first, rewires, says how to undo" {
  pf --enable
  [ "$status" -eq 0 ]
  ! overlay | grep -q 'hook:auto-handoff' || false
  # the rest of the overlay is intact
  overlay | grep -q '^project:foo$'
  overlay | grep -q '^repo/skill$'
  overlay | grep -q '^# test overlay$'
  # backup holds the ORIGINAL (with the -hook line)
  [ "$(n_backups)" -eq 1 ]
  grep -q -- '-hook:auto-handoff' "$(find "$BACKUPS" -type f | head -1)"
  [ "$(n_wire)" -eq 1 ]
  [[ "$output" =~ --disable ]]
  [[ "$output" =~ removed ]]
  # nothing under the Claude config dir was written by the script
  [ -z "$(ls -A "$CLAUDE_CONFIG_DIR")" ]
}

@test "--enable twice: the second run changes no file and makes no new backup" {
  pf --enable
  [ "$status" -eq 0 ]
  local after_first; after_first="$(overlay)"
  pf --enable
  [ "$status" -eq 0 ]
  [ "$(overlay)" = "$after_first" ]
  [ "$(n_backups)" -eq 1 ]
  [[ "$output" =~ nothing\ to\ change ]]
}

@test "--enable with no overlay file at all: nothing to edit, still rewires, creates no file" {
  rm "$PF_GRID/machines/testhost.txt"
  pf --enable
  [ "$status" -eq 0 ]
  [ ! -e "$PF_GRID/machines/testhost.txt" ]
  [ "$(n_backups)" -eq 0 ]
  [ "$(n_wire)" -eq 1 ]
}

@test "--enable refuses when the baseline also says -hook:auto-handoff" {
  printf -- '-hook:auto-handoff\n' >> "$PF_GRID/baseline.txt"
  local before; before="$(overlay)"
  pf --enable
  [ "$status" -eq 1 ]
  [[ "$output" =~ baseline\.txt ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
}

@test "--enable surfaces a wire.sh failure and still tells how to undo" {
  STUB_WIRE_EXIT=1 pf --enable
  [ "$status" -eq 1 ]
  [[ "$output" =~ wire\.sh\ failed ]]
  [[ "$output" =~ --disable ]]
}

@test "--disable round trip: enable then disable restores a single -hook line and rewires" {
  pf --enable
  [ "$status" -eq 0 ]
  pf --disable
  [ "$status" -eq 0 ]
  # one -hook line (the script appends it with a trailing comment)
  [ "$(overlay | grep -c '^-hook:auto-handoff')" -eq 1 ]
  overlay | grep -q '^project:foo$'
  [ "$(n_wire)" -eq 2 ]
  # second disable is a no-op on the file
  local after; after="$(overlay)"
  pf --disable
  [ "$status" -eq 0 ]
  [ "$(overlay)" = "$after" ]
  # --disable needs no live check: the claude stub was only called by the enable run
  [ "$(n_calls)" -eq 5 ]
}

@test "--disable creates the overlay when absent and handles a missing trailing newline" {
  rm "$PF_GRID/machines/testhost.txt"
  pf --disable
  [ "$status" -eq 0 ]
  [ "$(overlay | grep -c '^-hook:auto-handoff')" -eq 1 ]
  printf 'repo/skill' > "$PF_GRID/machines/testhost.txt"
  pf --disable
  [ "$status" -eq 0 ]
  overlay | grep -q '^repo/skill$'
  overlay | grep -q '^-hook:auto-handoff'
}

@test "an invalid GRID_HOST is refused (it names a file under machines/)" {
  GRID_HOST='../evil' pf --disable
  [ "$status" -eq 2 ]
  [ "$(n_wire)" -eq 0 ]
}
