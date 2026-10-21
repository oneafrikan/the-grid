#!/usr/bin/env bats
# The REAL hooks/catalogue.json gates the epistemic-stop Stop handler by profile:
# `strict` emits it, `standard` and `off` do not, and --check / --list agree.
# Covers openspec/changes/epistemic-enforcement task 3.6 (spec completion-warrant-hook,
# scenarios "Profile gating" and "Default off").
#
# No venv needed: deploy_hooks.py imports PyYAML lazily and only to read a project's
# .grid/project.yaml. Every project here is a bare temp dir driven by --profile, so the
# system python3 is enough. Do NOT add a project.yaml: that would pull PyYAML back in.
# tests/test_deploy_hooks.bats covers the emitter against a fixture catalogue and skips
# without the venv, which is why this lives in its own file.

load helpers/setup

setup() {
  common_setup
  # A temp HOME (set AFTER common_setup, which captured REAL_HOME for the sandbox check).
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  # The real catalogue and the real hook scripts, not a fixture grid.
  export GRID_DIR="$REPO_ROOT"
  EMIT="$REPO_ROOT/agent-factory/deploy_hooks.py"
}

teardown() {
  common_teardown
}

# emit_into <name> <profile> [extra args...]
# Makes a fresh-or-existing project dir under the test tmpdir and runs the emitter on it
# with --profile (never project.yaml). Sets $P to the project dir and $F to the file the
# emitter writes; $status/$output come from `run`.
emit_into() {
  local name="$1" profile="$2"
  shift 2
  P="$BATS_TEST_TMPDIR/$name"
  F="$P/.claude/settings.local.json"
  mkdir -p "$P"
  run python3 "$EMIT" "$P" --profile "$profile" "$@"
}

@test "emit: strict writes the epistemic-stop Stop handler; standard and off do not" {
  # strict: one Stop handler (timeout 5, no matcher) plus the two PreToolUse guards.
  emit_into strict strict
  [ "$status" -eq 0 ]
  [ -f "$F" ]
  [ "$(jq '.hooks.Stop | length' "$F")" -eq 1 ]
  # The entry carries no matcher: Stop has no tool to match on.
  jq -e '.hooks.Stop[0] | has("matcher") | not' "$F"
  [ "$(jq '[.hooks.Stop[].hooks[]] | length' "$F")" -eq 1 ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$F")" != "" ]
  jq -e '.hooks.Stop[0].hooks[0].command | contains("hooks/run.sh") and contains("epistemic-stop")' "$F"
  [ "$(jq '.hooks.Stop[0].hooks[0].timeout' "$F")" -eq 5 ]
  # The strict file still carries both guards.
  [ "$(jq '[.hooks.PreToolUse[].hooks[]] | length' "$F")" -eq 2 ]

  # standard (fresh project): the file exists but has no Stop key.
  emit_into standard standard
  [ "$status" -eq 0 ]
  [ -f "$F" ]
  jq -e '.hooks | has("Stop") | not' "$F"

  # off: nothing is written, not even the .claude directory.
  emit_into off off
  [ "$status" -eq 0 ]
  [ ! -e "$P/.claude" ]
}

@test "emit: --check passes after a strict emit, flags a standard re-check, and --list shows the entry" {
  emit_into proj strict
  [ "$status" -eq 0 ]

  # Same profile: the file matches the catalogue.
  emit_into proj strict --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches the catalogue"* ]]

  # standard no longer wants the Stop handler, so the emitted file drifts.
  emit_into proj standard --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"epistemic-stop"* ]]

  # --list reads the real catalogue: project scope, strict min profile, no model cost.
  run python3 "$EMIT" --list
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep '^epistemic-stop ')"
  [[ "$line" == *project* ]]
  [[ "$line" == *strict* ]]
  [[ "$line" == *" no "* ]]
}
