#!/usr/bin/env bats
# Tests for wire.sh — the script that creates ~/.claude/skills/ symlinks

load helpers/setup

setup() {
  common_setup
  make_skill "$MOCK_GRID/skill-alpha" "skill-alpha"
  make_skill "$MOCK_GRID/skill-beta"  "skill-beta"
}

teardown() {
  common_teardown
}

@test "creates a symlink per skill in the target dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
}

@test "symlinks resolve to directories (not dangling)" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -d "$MOCK_SKILLS/skill-alpha" ]
  [ -d "$MOCK_SKILLS/skill-beta" ]
}

@test "running wire.sh twice is idempotent" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
}

@test "removes stale symlink when skill is deleted from the-grid" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  rm -rf "$MOCK_GRID/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ ! -e "$MOCK_SKILLS/skill-alpha" ]
  [ ! -L "$MOCK_SKILLS/skill-alpha" ]
}

@test "does not remove symlinks owned by other sources" {
  mkdir -p "$OTHER_DIR/external-skill"
  ln -s "$OTHER_DIR/external-skill" "$MOCK_SKILLS/external-skill"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -L "$MOCK_SKILLS/external-skill" ]
}

@test "wires skills found inside repos/ submodules" {
  make_skill "$MOCK_GRID/repos/gstack/skill-gstack" "skill-gstack"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -L "$MOCK_SKILLS/skill-gstack" ]
  [ -d "$MOCK_SKILLS/skill-gstack" ]
}

@test "does not create symlinks for repos/ dir itself or tests/ dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ ! -L "$MOCK_SKILLS/repos" ]
  [ ! -L "$MOCK_SKILLS/tests" ]
}
