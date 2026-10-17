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
  export STUB_HANG_PID="$BATS_TEST_TMPDIR/hang.pid"
  # Default hook wait is 10 s; the tests that never see SessionEnd shorten it.
  export GRID_PREFLIGHT_HOOK_WAIT=3
  # The auth probe runs under `env -i`; the stub reads its STUB_* knobs from the environment.
  export GRID_AUTOHANDOFF_KEEP_ENV='STUB_*'
  unset ANTHROPIC_API_KEY GRID_PREFLIGHT_TIMEOUT GRID_PREFLIGHT_TIMEOUT_BIN
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
# tool_use <tool> <input key> <value>: one stream-json line like the real CLI's tool_use event.
tool_use() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"%s":"%s"}}]}}\n' "$1" "$2" "$3"
}
# hang_if <name>: STUB_HANG_ON=<name> makes that call record its pid and sleep (a hung claude).
hang_if() {
  if [ "${STUB_HANG_ON:-}" = "$1" ]; then echo $$ > "$STUB_HANG_PID"; exec sleep 20; fi
}
if [ "${1:-}" = "--help" ]; then
  hang_if HELP
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
    hang_if PREFLIGHT-ENV
    # Model Claude Code's hook runner: run every hook command the project's settings.json
    # declares. STUB_ENV_MODE: propagate (project env block applied), isolate (not applied),
    # nohook (no hook runs), start-only (SessionEnd never fires), delayed-end (SessionEnd
    # fires 1 s after claude exits, with the env applied per STUB_END_ENV=propagate|isolate).
    marker="$(sed -n 's/^ *"GRID_PREFLIGHT_MARKER": "\([^"]*\)" *$/\1/p' .claude/settings.json)"
    mode="${STUB_ENV_MODE:-isolate}"
    sed -n 's/^ *"command": "\(.*\)" *$/\1/p' .claude/settings.json | while IFS= read -r c; do
      case "$mode:$c" in
        nohook:*) ;;
        start-only:*end.out*) ;;
        delayed-end:*end.out*)
          ( sleep 1
            if [ "${STUB_END_ENV:-isolate}" = propagate ]; then GRID_PREFLIGHT_MARKER="$marker" sh -c "$c"
            else env -u GRID_PREFLIGHT_MARKER sh -c "$c"; fi ) > /dev/null 2>&1 < /dev/null &
          ;;
        propagate:*) GRID_PREFLIGHT_MARKER="$marker" sh -c "$c" ;;
        *)           env -u GRID_PREFLIGHT_MARKER sh -c "$c" ;;
      esac
    done
    echo ok; exit 0 ;;
  *outside.txt*)
    # B1 rule-form probe: cwd is the scratch repo. Like the real CLI in stream-json mode, the
    # stub prints a tool_use line for every action it ATTEMPTS (blocked or not); "lazy" modes
    # skip attempts, which the script must call INCONCLUSIVE, not a pass.
    hang_if PREFLIGHT-B1A
    # STUB_B1_EVENTS shapes the stream for the outside write: write (the real thing), or
    # look-alikes that are NOT an attempt at it (read, text block, other dir, relative
    # path, tool_result echo), the Edit/MultiEdit variants that are, and malformed noise.
    if [ "${STUB_B1_MODE:-good}" != skip-outside ]; then
      case "${STUB_B1_EVENTS:-writes}" in
        writes)     tool_use Write file_path "$PWD/outside.txt" ;;
        edit)      tool_use Edit file_path "$PWD/outside.txt" ;;
        multiedit) tool_use MultiEdit file_path "$PWD/outside.txt" ;;
        reads)      tool_use Read file_path "$PWD/outside.txt" ;;
        other-dir) tool_use Write file_path "/elsewhere$PWD/outside.txt" ;;
        relative)  tool_use Write file_path "outside.txt" ;;
        text-plus-tool)
          printf '{"type":"assistant","message":{"content":[{"type":"text","text":"about to write %s/outside.txt"},{"type":"tool_use","name":"Write","input":{"file_path":"%s/LOGS/inside.txt"}}]}}\n' "$PWD" "$PWD" ;;
        echoes)
          printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"wrote %s/outside.txt"}]}}\n' "$PWD" ;;
        malformed)
          echo 'not json {'; echo '{"type":"assis'; tool_use Write file_path "$PWD/outside.txt"; echo '[1,2'; echo ;;
      esac
    fi
    tool_use Write file_path "$PWD/LOGS/inside.txt"
    case "${STUB_B1_MODE:-good}" in
      good|skip-outside) echo x > LOGS/inside.txt ;;
      bad-outside)       echo x > LOGS/inside.txt; echo x > outside.txt ;;
      bad-inside)        : ;;
    esac
    exit 0 ;;
  *ok.txt*)
    # B1 second probe: .git deny and the Bash(ls:*) redirect question.
    tool_use Write file_path "$PWD/ok.txt"
    case "${STUB_B1B_MODE:-good}" in
      skip-git|lazy) ;;
      *) case "${STUB_GIT_EVENTS:-writes}" in
           writes) tool_use Write file_path "$PWD/.git/probe.txt" ;;
           edit)  tool_use Edit file_path "$PWD/.git/probe.txt" ;;
           reads)  tool_use Read file_path "$PWD/.git/probe.txt" ;;
           bash)  tool_use Bash command "echo x > $PWD/.git/probe.txt" ;;
         esac ;;
    esac
    case "${STUB_B1B_MODE:-good}" in
      skip-redirect|lazy) ;;
      *) case "${STUB_REDIR_EVENTS:-redirect}" in
           redirect) tool_use Bash command "ls $PWD > $PWD/redirect.txt" ;;
           append)   tool_use Bash command "ls $PWD >> \\\"$PWD/redirect.txt\\\"" ;;
           ls-only)  tool_use Bash command "ls $PWD/redirect.txt" ;;
           writes)    tool_use Write file_path "$PWD/redirect.txt" ;;
           other-dir) tool_use Bash command "ls $PWD > /elsewhere$PWD/redirect.txt" ;;
         esac ;;
    esac
    case "${STUB_B1B_MODE:-good}" in
      good|skip-git|skip-redirect|lazy) echo x > ok.txt ;;
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
# scratch_left: is a script scratch dir still under TMPDIR? (glob, not ls | grep: SC2010)
scratch_left() { compgen -G "$TMPDIR/grid-preflight.*" > /dev/null; }
# file mode, GNU or BSD stat
mode_of() { stat -c '%a' "$1" 2> /dev/null || stat -f '%Lp' "$1"; }
need_nonroot() { [ "$(id -u)" -ne 0 ] || skip "permission tests need a non-root user"; }
# a settings.json whose allow rules carry fake secrets (assembled so no scanner flags this file)
fake_settings() {
  local bearer="Bear""er" tok="FAKE-SECRET-TOKEN-1234567890" gh="GH_""TOKEN=FAKE-GHP-0000"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"permissions":{"defaultMode":"default","allow":["Bash(curl -H \\"Authorization: %s %s\\" https://x.example:*)","Bash(export %s && gh:*)","Read"]}}\n' \
    "$bearer" "$tok" "$gh" > "$CLAUDE_CONFIG_DIR/settings.json"
}

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
  ! scratch_left || false
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
  ! scratch_left || false
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

# ---------------------------------------------------------------------------
# review round (PR #272 SEC VS1-VS8, QA VF1-VF6)
# ---------------------------------------------------------------------------

# --- QA VF1 / SEC VS7: the overlay write is checked, atomic, and refuses a symlink -------

@test "VF1: a read-only overlay -> --enable refuses, changes nothing, never says removed/enabled" {
  need_nonroot
  chmod 444 "$PF_GRID/machines/testhost.txt"
  local before; before="$(overlay)"
  pf --enable
  [ "$status" -ne 0 ]
  [[ "$output" =~ not\ writable ]]
  [[ ! "$output" =~ removed\ [0-9] ]]
  [[ ! "$output" =~ is\ enabled ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
  [ "$(n_backups)" -eq 0 ]
}

@test "VF1: a read-only overlay -> --disable refuses too" {
  need_nonroot
  printf 'repo/skill\n' > "$PF_GRID/machines/testhost.txt"
  chmod 444 "$PF_GRID/machines/testhost.txt"
  pf --disable
  [ "$status" -ne 0 ]
  [[ ! "$output" =~ is\ disabled ]]
  [ "$(overlay)" = "repo/skill" ]
  [ "$(n_wire)" -eq 0 ]
}

@test "VF1: an unwritable machines/ dir -> the write fails loudly, nothing is claimed" {
  need_nonroot
  local before; before="$(overlay)"
  chmod 555 "$PF_GRID/machines"
  pf --enable
  chmod 755 "$PF_GRID/machines"
  [ "$status" -ne 0 ]
  [[ ! "$output" =~ is\ enabled ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
  [ "$(n_backups)" -eq 0 ]
}

@test "VS7: a symlinked overlay is refused (not edited through the link), enable and disable" {
  mv "$PF_GRID/machines/testhost.txt" "$BATS_TEST_TMPDIR/real-overlay.txt"
  ln -s "$BATS_TEST_TMPDIR/real-overlay.txt" "$PF_GRID/machines/testhost.txt"
  local before; before="$(cat "$BATS_TEST_TMPDIR/real-overlay.txt")"
  pf --enable
  [ "$status" -ne 0 ]
  [[ "$output" =~ symlink ]]
  pf --disable
  [ "$status" -ne 0 ]
  [[ "$output" =~ symlink ]]
  [ "$(cat "$BATS_TEST_TMPDIR/real-overlay.txt")" = "$before" ]
  [ -L "$PF_GRID/machines/testhost.txt" ]
  [ "$(n_wire)" -eq 0 ]
}

@test "VS7: the write is a rename in the same dir: no temp file left, mode kept, backup holds the original" {
  chmod 640 "$PF_GRID/machines/testhost.txt"
  pf --enable
  [ "$status" -eq 0 ]
  [ "$(mode_of "$PF_GRID/machines/testhost.txt")" = 640 ]
  ! compgen -G "$PF_GRID/machines/*preflight*" > /dev/null || false
  [ "$(n_backups)" -eq 1 ]
}

@test "VF3: an unusable GRID_STATE_DIR (backup cannot be made) -> refuse, overlay unchanged, no wire" {
  : > "$BATS_TEST_TMPDIR/not-a-dir"
  local before; before="$(overlay)"
  GRID_STATE_DIR="$BATS_TEST_TMPDIR/not-a-dir" pf --enable
  [ "$status" -ne 0 ]
  [[ "$output" =~ could\ not\ back\ up ]]
  [[ ! "$output" =~ is\ enabled ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
}

@test "VF3: CRLF and commented overlay lines: only the -hook lines go, every other byte stays" {
  printf '# c1\r\nproject:foo\r\n  -hook:auto-handoff  # why\r\n-hook:auto-handoff-x\r\nrepo/skill   # keep\r\n' \
    > "$PF_GRID/machines/testhost.txt"
  pf --enable
  [ "$status" -eq 0 ]
  [ "$(cat "$PF_GRID/machines/testhost.txt")" = "$(printf '# c1\r\nproject:foo\r\n-hook:auto-handoff-x\r\nrepo/skill   # keep\r')" ]
  [[ "$output" =~ removed\ 1 ]]
}

# --- SEC VS8 / QA VF6: same line grammar as wire.sh -------------------------------------

@test "VS8: a -hook line with a trailing form feed is still read as OFF and removed" {
  printf 'project:foo\n-hook:auto-handoff\f\n' > "$PF_GRID/machines/testhost.txt"
  pf
  [[ "$output" =~ auto-handoff\ manifest\ state:\ OFF ]]
  pf --enable
  [ "$status" -eq 0 ]
  [[ "$output" =~ removed\ 1 ]]
  [ "$(overlay)" = "project:foo" ]
}

@test "VS8: whitespace inside the entry is ignored like wire.sh (tr -d [:space:])" {
  printf -- '- hook :\tauto-handoff\n' > "$PF_GRID/machines/testhost.txt"
  pf
  [[ "$output" =~ auto-handoff\ manifest\ state:\ OFF ]]
}

@test "VF6: an unterminated last line is not read (wire.sh's read loop skips it); --disable still adds a clean line" {
  printf 'repo/skill\n-hook:auto-handoff' > "$PF_GRID/machines/testhost.txt"
  pf
  [[ "$output" =~ auto-handoff\ manifest\ state:\ ON ]]
  pf --disable
  [ "$status" -eq 0 ]
  overlay | grep -q '^repo/skill$'
  overlay | grep -q '^-hook:auto-handoff$'
  overlay | grep -q '^-hook:auto-handoff   # added by'
}

# --- SEC VS1 / QA VF2: absent files only count when the attempt is evidenced -------------

@test "VS1: a model that never attempts the outside write -> INCONCLUSIVE, FAIL, with a rerun hint" {
  STUB_B1_MODE=skip-outside pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*outside\.txt ]]
  [[ "$output" =~ rerun ]]
}

@test "VS1: no .git write attempted -> INCONCLUSIVE" {
  STUB_B1B_MODE=skip-git pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*\.git ]]
}

@test "VS1: no redirect attempted -> INCONCLUSIVE" {
  STUB_B1B_MODE=skip-redirect pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*redirect ]]
}

@test "VS1: the lazy stub (writes only inside.txt and ok.txt) can no longer PASS or enable" {
  local before; before="$(overlay)"
  STUB_B1_MODE=skip-outside STUB_B1B_MODE=lazy pf --enable
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE ]]
  [[ "$output" =~ enable\ refused ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
}

@test "VS1: the b1 probes ask for stream-json so attempts are visible" {
  pf
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--output-format stream-json --verbose' "$STUB_LOG")" -eq 2 ]
}

# --- SEC VS5: wait for SessionEnd before concluding ----------------------------------------

@test "VS5: SessionEnd never fires (SessionStart only) -> INCONCLUSIVE, not DOES-NOT-PROPAGATE" {
  GRID_PREFLIGHT_HOOK_WAIT=2 STUB_ENV_MODE=start-only pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +env-propagation.*INCONCLUSIVE.*SessionEnd ]]
  [[ ! "$output" =~ DOES-NOT-PROPAGATE ]]
}

@test "VS5: a delayed SessionEnd is waited for: DOES-NOT-PROPAGATE only once it has run" {
  STUB_ENV_MODE=delayed-end STUB_END_ENV=isolate pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +env-propagation\ +DOES-NOT-PROPAGATE ]]
}

@test "VS5: SessionStart sees no env but the delayed SessionEnd does -> PROPAGATES" {
  STUB_ENV_MODE=delayed-end STUB_END_ENV=propagate pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +env-propagation\ +PROPAGATES ]]
  [[ "$output" =~ WARN ]]
}

# --- SEC VS3: no raw allow rules in the output ---------------------------------------------

@test "VS3: allow rules are shown as shapes with values masked, in --check" {
  fake_settings
  pf
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ FAKE-SECRET ]]
  [[ ! "$output" =~ FAKE-GHP ]]
  [[ ! "$output" =~ Bearer ]]
  [[ ! "$output" =~ GH_TOKEN ]]
  [[ "$output" =~ 3\ allow\ rule ]]
  [[ "$output" == *'Bash(***)'* ]]
}

@test "VS3: and in --dry-run" {
  fake_settings
  pf --dry-run
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ FAKE-SECRET ]]
  [[ ! "$output" =~ FAKE-GHP ]]
  [[ "$output" == *'Bash(***)'* ]]
}

# --- SEC VS6 / QA VF3,VF4: wall-clock limit on every call; signals kill only our probe ------

@test "VS6: a hung probe is killed at GRID_PREFLIGHT_TIMEOUT and reported as timed out" {
  GRID_PREFLIGHT_TIMEOUT=2 STUB_HANG_ON=PREFLIGHT-ENV pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +env-propagation.*timed\ out\ after\ 2s ]]
  [[ "$output" =~ PASS\ +wp016-parity ]]
  ! kill -0 "$(cat "$STUB_HANG_PID")" 2> /dev/null || false
}

@test "VF4: claude --help is under the timeout too" {
  GRID_PREFLIGHT_TIMEOUT=2 STUB_HANG_ON=HELP pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +wp016-parity.*timed\ out\ after\ 2s ]]
}

@test "VS6: no timeout(1): said up front, checks still run, --enable refuses" {
  local before; before="$(overlay)"
  GRID_PREFLIGHT_TIMEOUT_BIN=/nonexistent/timeout pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ WARN.*timeout ]]
  GRID_PREFLIGHT_TIMEOUT_BIN=/nonexistent/timeout pf --enable
  [ "$status" -ne 0 ]
  [[ "$output" =~ enable\ refused.*timeout ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
}

@test "VS6: SIGTERM stops the running probe (only it), removes the scratch dir and exits" {
  STUB_HANG_ON=PREFLIGHT-ENV GRID_PREFLIGHT_TIMEOUT=60 bash "$PF" > "$BATS_TEST_TMPDIR/sig.out" 2>&1 &
  local pfpid=$! i
  for ((i = 0; i < 100; i++)); do [ -s "$STUB_HANG_PID" ] && break; sleep 0.1; done
  [ -s "$STUB_HANG_PID" ]
  local stubpid; stubpid="$(cat "$STUB_HANG_PID")"
  kill -TERM "$pfpid"
  for ((i = 0; i < 100; i++)); do kill -0 "$pfpid" 2> /dev/null || break; sleep 0.1; done
  ! kill -0 "$pfpid" 2> /dev/null || { kill -9 "$pfpid" "$stubpid" 2> /dev/null; false; }
  for ((i = 0; i < 50; i++)); do kill -0 "$stubpid" 2> /dev/null || break; sleep 0.1; done
  ! kill -0 "$stubpid" 2> /dev/null || { kill -9 "$stubpid"; false; }
  ! scratch_left || false
}

# --- SEC VS2: worker flags on the probes where the semantics allow it ------------------------

@test "VS2: b1 probes run with the worker's three flags; the env probe with all but --setting-sources" {
  pf
  [ "$status" -eq 0 ]
  local b1 envline
  b1="$(grep -- 'outside.txt' "$STUB_LOG")"
  [[ "$b1" =~ --permission-mode\ default ]]
  [[ "$b1" =~ --setting-sources\ user ]]
  [[ "$b1" =~ --strict-mcp-config ]]
  b1="$(grep -- 'ok.txt' "$STUB_LOG")"
  [[ "$b1" =~ --setting-sources\ user ]]
  envline="$(grep -- 'PREFLIGHT-ENV' "$STUB_LOG")"
  [[ "$envline" =~ --permission-mode\ default ]]
  [[ "$envline" =~ --strict-mcp-config ]]
  # the env probe MUST load project settings: that is what it tests
  [[ ! "$envline" =~ --setting-sources ]]
  # and the output says which flags each probe used and why the env probe differs
  [[ "$output" =~ probe\ flags\ \(env-propagation\).*without\ --setting-sources ]]
  [[ "$output" =~ probe\ flags\ \(b1-rule-form\).*--setting-sources\ user ]]
}

# --- SEC VS4: the H-02 conditions gate --enable --------------------------------------------

@test "VS4: a symlinked watched dotfile: --check warns and passes, --enable refuses without --accept-dotfile-risk" {
  echo real > "$HOME/zshrc.real"
  ln -s "$HOME/zshrc.real" "$HOME/.zshrc"
  local before; before="$(overlay)"
  pf
  [ "$status" -eq 0 ]
  pf --enable
  [ "$status" -ne 0 ]
  [[ "$output" =~ --accept-dotfile-risk ]]
  [ "$(overlay)" = "$before" ]
  [ "$(n_wire)" -eq 0 ]
  pf --enable --accept-dotfile-risk
  [ "$status" -eq 0 ]
  [ "$(n_wire)" -eq 1 ]
}

@test "VS4: a writable ~/.bash_aliases: --enable refuses without --accept-dotfile-risk" {
  : > "$HOME/.bash_aliases"
  local before; before="$(overlay)"
  pf --enable
  [ "$status" -ne 0 ]
  [[ "$output" =~ --accept-dotfile-risk ]]
  [ "$(overlay)" = "$before" ]
  pf --enable --accept-dotfile-risk
  [ "$status" -eq 0 ]
}

@test "VS4: --disable is never blocked by the dotfile conditions" {
  : > "$HOME/.bash_aliases"
  printf 'repo/skill\n' > "$PF_GRID/machines/testhost.txt"
  pf --disable
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# review round 2 (N1: attempt evidence must be ONE write-capable tool_use on the exact path)
# ---------------------------------------------------------------------------

@test "N1: a Read tool_use naming outside.txt is not an attempt -> INCONCLUSIVE" {
  STUB_B1_EVENTS=reads pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*outside\.txt ]]
}

@test "N1: a text block naming the path plus an unrelated tool_use is not an attempt" {
  STUB_B1_EVENTS=text-plus-tool pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*outside\.txt ]]
}

@test "N1: a Write to the same basename in ANOTHER directory is not an attempt" {
  STUB_B1_EVENTS=other-dir pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*outside\.txt ]]
}

@test "N1: a relative path is not an attempt on the exact path (fail safe)" {
  STUB_B1_EVENTS=relative pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*outside\.txt ]]
}

@test "N1: a tool_result echo of the path is not an attempt" {
  STUB_B1_EVENTS=echoes pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*outside\.txt ]]
}

@test "N1: a Write tool_use on the exact path, file absent -> PASS" {
  STUB_B1_EVENTS=writes pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +b1-rule-form ]]
}

@test "N1: Edit and MultiEdit tool_use on the exact path count too" {
  STUB_B1_EVENTS=edit pf
  [ "$status" -eq 0 ]
  STUB_B1_EVENTS=multiedit pf
  [ "$status" -eq 0 ]
  STUB_GIT_EVENTS=edit pf
  [ "$status" -eq 0 ]
}

@test "N1: malformed JSON lines mixed into the stream are ignored" {
  STUB_B1_EVENTS=malformed pf
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +b1-rule-form ]]
}

@test "N1: the path written despite the tool_use -> still a FAIL (violation, not inconclusive)" {
  STUB_B1_MODE=bad-outside STUB_B1_EVENTS=reads pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*outside\.txt\ written ]]
}

@test "N1: redirect probe: a Bash command with > to the exact path counts, >> with quotes too" {
  pf
  [ "$status" -eq 0 ]
  STUB_REDIR_EVENTS=append pf
  [ "$status" -eq 0 ]
}

@test "N1: redirect probe: ls of the file without a redirect is not an attempt" {
  STUB_REDIR_EVENTS=ls-only pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*redirect ]]
}

@test "N1: redirect probe: a Write tool_use (not Bash) for redirect.txt is not the redirect attempt" {
  STUB_REDIR_EVENTS=writes pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*redirect ]]
}

@test "N1: redirect probe: a redirect to another directory's redirect.txt is not an attempt" {
  STUB_REDIR_EVENTS=other-dir pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*redirect ]]
}

@test "N1: .git probe: Read or a Bash echo are not the write attempt" {
  STUB_GIT_EVENTS=reads pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*\.git ]]
  STUB_GIT_EVENTS=bash pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*\.git ]]
}

@test "N1: the evidence is per action: a missing .git attempt does not hide a proven redirect" {
  STUB_B1B_MODE=skip-git pf
  [ "$status" -eq 1 ]
  [[ "$output" =~ INCONCLUSIVE.*\.git ]]
  [[ ! "$output" =~ attempted\ the\ \'ls ]]
}

@test "N1: no python3 to parse the stream -> INCONCLUSIVE with a clear message, never PASS" {
  GRID_PREFLIGHT_PYTHON=/nonexistent/python3 pf --enable
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +b1-rule-form.*INCONCLUSIVE.*python3 ]]
  [[ "$output" =~ enable\ refused ]]
  [ "$(n_wire)" -eq 0 ]
}

# --- N3: refuse a pathological overlay line before any spend; N4: stale temp file ----------

@test "N3: a manifest line over 64 KB is refused up front, before any claude call" {
  head -c 70000 /dev/zero | tr '\0' 'a' > "$BATS_TEST_TMPDIR/long"
  { cat "$BATS_TEST_TMPDIR/long"; echo; } >> "$PF_GRID/machines/testhost.txt"
  pf
  [ "$status" -eq 2 ]
  [[ "$output" =~ 64\ KB ]]
  [ "$(n_calls)" -eq 0 ]
}

@test "N4: a leftover overlay temp file from a killed run is removed by the next --enable, not by --check" {
  : > "$PF_GRID/machines/testhost.txt.preflight.AbC123"
  pf
  [ -e "$PF_GRID/machines/testhost.txt.preflight.AbC123" ]
  pf --enable
  [ "$status" -eq 0 ]
  [ ! -e "$PF_GRID/machines/testhost.txt.preflight.AbC123" ]
  [[ "$output" =~ leftover ]]
}
