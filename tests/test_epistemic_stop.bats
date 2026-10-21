#!/usr/bin/env bats
# Tests for the epistemic-stop Stop hook (hooks/scripts/epistemic-stop.sh): it asks once
# for a RAN, READ or UNTESTED warrant when the last message claims completion without one.
# Scenarios: openspec/changes/epistemic-enforcement, spec completion-warrant-hook,
# requirement "Ask once for a warrant".

bats_require_minimum_version 1.5.0   # `run --separate-stderr`

load helpers/setup
load helpers/hooks

setup() {
  common_setup
  # Temp HOME, set AFTER common_setup (which has captured REAL_HOME for the sandbox check).
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
}

teardown() {
  common_teardown
}

# stop_payload <message> [active]: a Stop payload built with jq --arg, never hand-typed JSON.
# The key names are the ones observed from the real claude; the values are placeholders.
stop_payload() {
  jq -n --arg m "$1" --argjson a "${2:-false}" '{
    session_id: "test-session",
    transcript_path: "/tmp/none.jsonl",
    cwd: "/tmp",
    prompt_id: "test-prompt",
    permission_mode: "default",
    effort: "medium",
    hook_event_name: "Stop",
    stop_hook_active: $a,
    last_assistant_message: $m,
    background_tasks: [],
    session_crons: []
  }'
}

# shellcheck disable=SC2154  # status/output/stderr are set by bats' `run`
@test "epistemic-stop: a completion claim with no RAN, READ or UNTESTED exits 2 with the one-line reason" {
  local reason="State RAN, READ or UNTESTED for each completion claim (see AGENTS_base)"
  local msg
  # The last two prove the warrant is case-sensitive and whole-word.
  for msg in \
    "Fixed the bug and all tests pass." \
    "done, I ran it" \
    "Done. The RANDOM seed and READABLE logs are fine."; do
    run --separate-stderr bash -c 'printf "%s" "$1" | bash "$2/hooks/run.sh" epistemic-stop' \
      _ "$(stop_payload "$msg")" "$REPO_ROOT"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ "$stderr" = "$reason" ]
  done
}

# shellcheck disable=SC2154  # status/output are set by bats' `run`
@test "epistemic-stop: a warranted claim and a message with no claim exit 0 silently" {
  local msg
  for msg in \
    "Fixed. RAN: bash scripts/gate.sh, exit 0." \
    "Done. READ the config, did not run it." \
    "Done. UNTESTED on macOS." \
    "Which of the two branches do you want me to use?"; do
    run_hook epistemic-stop "$(stop_payload "$msg")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}
