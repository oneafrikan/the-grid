#!/usr/bin/env bats
# Tests for scripts/epistemic-stop-probe.sh, the one-command probe that records what the
# real Claude Code Stop hook does (epistemic-enforcement task 3.1).
#
# Safety: `claude` is ALWAYS the local stub below, reached through GRID_CLAUDE. The default
# GRID_CLAUDE that common_setup exports is a tripwire path that cannot execute, so a test
# that forgets to set the stub fails instead of spending money. HOME, TMPDIR and the state
# (result) dir are temp dirs. No model is called.
#
# The stub lives in this file: its behaviour (it runs the Stop hook the probe's
# settings.json declares, the way the real CLI would) is specific to this probe.

load helpers/setup

setup() {
  # TMPDIR inside the per-test dir: the probe's own scratch dir lands there, so a leaked
  # scratch dir is visible to the test and cleaned up by bats.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  common_setup
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  export GRID_STATE_DIR="$MOCK_HOOK_ROOT/grid-state"
  PROBE="$REPO_ROOT/scripts/epistemic-stop-probe.sh"
  STUB="$BATS_TEST_TMPDIR/stub/claude"
  export STUB_LOG="$BATS_TEST_TMPDIR/claude.log"
  unset STUB_MODE STUB_LOGGED_IN
  make_stub
}

teardown() {
  common_teardown
}

# make_stub: a fake `claude`. `auth status --json` answers from STUB_LOGGED_IN. A `-p` call
# is logged, then the stub plays the CLI: it reads the Stop hook from ./.claude/settings.json,
# feeds it a Stop payload, and on exit 2 (with stderr as the reason) runs the turn again with
# a second payload, like the real CLI is expected to. STUB_MODE picks the behaviour:
#   twice (default)    hook runs twice, exit 2 then 0; reply to the reason contains AGAIN
#   never              the hook is never run
#   no-continue        hook runs once and the CLI ignores its exit 2
#   inactive-flag      as twice, but the second payload says stop_hook_active false
#   no-marker          as twice, but the final reply does not contain AGAIN
make_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ]; then
  if [ "${STUB_LOGGED_IN:-1}" = 0 ]; then echo '{"loggedIn":false}'; exit 1; fi
  echo '{"loggedIn":true}'; exit 0
fi
echo "cwd=$PWD argv=$*" >> "$STUB_LOG"
mode="${STUB_MODE:-twice}"
result=DONE
if [ "$mode" != never ]; then
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' .claude/settings.json)"
  : > "$PWD/transcript.jsonl"
  payload() {  # $1 = stop_hook_active
    jq -n --arg tp "$PWD/transcript.jsonl" --arg cwd "$PWD" --argjson a "$1" \
      '{session_id:"s1",transcript_path:$tp,cwd:$cwd,hook_event_name:"Stop",stop_hook_active:$a,last_assistant_message:"DONE"}'
  }
  rc=0; reason="$(payload false | sh -c "$cmd" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" = 2 ] && [ "$mode" != no-continue ]; then
    case "$mode" in inactive-flag) active=false ;; *) active=true ;; esac
    payload "$active" | sh -c "$cmd" >/dev/null 2>&1
    case "$reason" in *AGAIN*) [ "$mode" = no-marker ] || result=AGAIN ;; esac
  fi
fi
jq -n --arg r "$result" '{type:"result",subtype:"success",is_error:false,result:$r,num_turns:2,total_cost_usd:0.01}'
EOF
  chmod +x "$STUB"
}

# run_probe <args...>: the probe with the stub as claude; output in $output, status in $status.
run_probe() {
  GRID_CLAUDE="$STUB" run bash "$PROBE" "$@"
}

# result_dir: the one result dir the probe created.
result_dir() {
  find "$GRID_STATE_DIR/probes" -mindepth 1 -maxdepth 1 -type d | head -n 1
}

@test "dry run without --yes spends nothing, prints the cap first and exits 0" {
  # The tripwire GRID_CLAUDE (not the stub) is deliberately left in place: a dry run must
  # not even look for claude.
  run bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "WORST-CASE SPEND: USD 0.10 (one claude call: --model haiku --max-budget-usd 0.10, hard timeout 120s)." ]
  [[ "$output" == *"Dry run: nothing spent"* ]]
  # and with the stub present, still no call and nothing written
  run_probe
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG" ]
  [ ! -e "$GRID_STATE_DIR/probes" ]
}

@test "unknown argument exits 2" {
  run_probe --bogus
  [ "$status" -eq 2 ]
}

@test "hook run twice (exit 2 then 0): three PASS, exit 0" {
  run_probe --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"(a) payload fields:           PASS"* ]]
  [[ "$output" == *"(b) exit 2 continues turn:    PASS"* ]]
  [[ "$output" == *"(c) stop 2 stop_hook_active:  PASS"* ]]
  [[ "$output" == *"RESULT: all three PASS"* ]]
  # the payload keys and the transcript/last-message facts are reported
  [[ "$output" == *"keys: session_id, transcript_path, cwd, hook_event_name, stop_hook_active, last_assistant_message"* ]]
  [[ "$output" == *"last-message field: last_assistant_message"* ]]
  # exactly one claude -p call, with the cap and the safe flags
  [ "$(wc -l < "$STUB_LOG" | tr -d ' ')" -eq 1 ]
  grep -q -- '--max-budget-usd 0.10' "$STUB_LOG"
  grep -q -- '--setting-sources project' "$STUB_LOG"
  grep -q -- '--tools' "$STUB_LOG"
  # the call ran in the scratch dir, not the repo
  ! grep -q "cwd=$REPO_ROOT" "$STUB_LOG" || false
  # captured files: mode 700 dir, raw payloads and verdict, path printed
  d="$(result_dir)"
  [ -n "$d" ]
  [[ "$output" == *"$d"* ]]
  [ -s "$d/stop-1.json" ]
  [ -s "$d/stop-2.json" ]
  [ -s "$d/verdict.txt" ]
  ls -ld "$d" | grep -q '^drwx------'
  # the scratch dir is gone, and the real HOME was not touched
  ! ls "$TMPDIR" | grep -q grid-stop-probe || false
}

@test "hook never runs: INCONCLUSIVE for all three, exit 1" {
  STUB_MODE=never run_probe --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"(a) payload fields:           INCONCLUSIVE"* ]]
  [[ "$output" == *"(b) exit 2 continues turn:    INCONCLUSIVE"* ]]
  [[ "$output" == *"(c) stop 2 stop_hook_active:  INCONCLUSIVE"* ]]
  [[ "$output" == *"the Stop hook never ran"* ]]
  [[ "$output" != *"all three PASS"* ]]
}

@test "exit 2 ignored by the CLI: (b) FAIL, (c) INCONCLUSIVE, exit 1" {
  STUB_MODE=no-continue run_probe --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"(a) payload fields:           PASS"* ]]
  [[ "$output" == *"(b) exit 2 continues turn:    FAIL"* ]]
  [[ "$output" == *"(c) stop 2 stop_hook_active:  INCONCLUSIVE"* ]]
}

@test "second payload without stop_hook_active true: (c) FAIL, exit 1" {
  STUB_MODE=inactive-flag run_probe --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"(c) stop 2 stop_hook_active:  FAIL"* ]]
  [[ "$output" == *"stop 1 = false, stop 2 = false"* ]]
}

@test "turn continued but the reply lacks the marker: (b) FAIL, exit 1" {
  STUB_MODE=no-marker run_probe --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"(b) exit 2 continues turn:    FAIL"* ]]
  [[ "$output" == *"lacks 'AGAIN'"* ]]
}

@test "missing claude exits 2 and spends nothing" {
  GRID_CLAUDE="$BATS_TEST_TMPDIR/no-such-claude" run bash "$PROBE" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"claude not found"* ]]
  [ ! -e "$STUB_LOG" ]
  [ ! -e "$GRID_STATE_DIR/probes" ]
}

@test "logged-out claude exits 2 and makes no model call" {
  STUB_LOGGED_IN=0 run_probe --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"not logged in"* ]]
  [ ! -e "$STUB_LOG" ]
}
