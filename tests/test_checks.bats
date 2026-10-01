#!/usr/bin/env bats
# Tests for the read-only drift detectors: catalog.sh --check, wire.sh --check,
# and the sandbox tripwire in tests/helpers/setup.bash.

load helpers/setup

setup() {
  common_setup
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
}

teardown() {
  common_teardown
}

# --- catalog.sh --check -------------------------------------------------------

@test "catalog --check passes when SKILLS.md is current" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 0 ]
}

@test "catalog --check fails when a skill was added after the last run" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"
  make_skill "$MOCK_GRID/skills/skill-new" "skill-new"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
}

@test "catalog --check writes nothing" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"
  before="$(cat "$MOCK_GRID/SKILLS.md")"
  make_skill "$MOCK_GRID/skills/skill-new" "skill-new"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$(cat "$MOCK_GRID/SKILLS.md")" = "$before" ]
}

# --- wire.sh --check ----------------------------------------------------------

@test "wire --check passes right after a wire" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}

@test "wire --check reports a missing link and changes nothing" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  rm "$MOCK_SKILLS/skill-alpha"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skill-alpha"* ]]
  [ ! -e "$MOCK_SKILLS/skill-alpha" ]   # still missing: --check never repairs
}

@test "wire --check reports a stale grid-owned link" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  ln -s "$MOCK_GRID/skills/gone" "$MOCK_SKILLS/gone"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"gone"* ]]
}

@test "wire --check ignores foreign symlinks" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  ln -s "$OTHER_DIR" "$MOCK_SKILLS/foreign"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}

# --- sandbox tripwire ---------------------------------------------------------

@test "tripwire refuses a target inside the real ~/.claude" {
  mkdir -p "$HOME/.claude"
  SKILLS_DIR="$HOME/.claude" run assert_sandboxed
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]]
}

@test "tripwire accepts the sandbox dirs" {
  run assert_sandboxed
  [ "$status" -eq 0 ]
}

@test "wire --check does not flag a name shadowed by a real (unmanaged) dir" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  rm "$MOCK_SKILLS/skill-alpha"
  mkdir "$MOCK_SKILLS/skill-alpha"          # user's own real dir shadows the grid skill
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}
