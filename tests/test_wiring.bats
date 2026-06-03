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

@test "wires skills found inside repos/ submodules (flat)" {
  make_skill "$MOCK_GRID/repos/gstack/skill-gstack" "skill-gstack"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -L "$MOCK_SKILLS/skill-gstack" ]
  [ -d "$MOCK_SKILLS/skill-gstack" ]
}

@test "wires skills nested under skills/ subdir (mattpocock/superpowers style)" {
  make_skill "$MOCK_GRID/repos/mattpocock/skills/engineering/skill-deep" "skill-deep"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -L "$MOCK_SKILLS/skill-deep" ]
  [ -d "$MOCK_SKILLS/skill-deep" ]
}

@test "skips repo-root SKILL.md (gstack style)" {
  mkdir -p "$MOCK_GRID/repos/gstack"
  printf -- "---\nname: gstack\ndescription: repo root\n---\n" > "$MOCK_GRID/repos/gstack/SKILL.md"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ ! -L "$MOCK_SKILLS/gstack" ]
}

@test "does not create symlinks for repos/ dir itself or tests/ dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ ! -L "$MOCK_SKILLS/repos" ]
  [ ! -L "$MOCK_SKILLS/tests" ]
}

@test "wired-submodules.txt allowlist: only listed repos are wired" {
  make_skill "$MOCK_GRID/repos/wiredrepo/skill-w" "skill-w"
  make_skill "$MOCK_GRID/repos/libraryrepo/skill-l" "skill-l"
  printf 'wiredrepo\n' > "$MOCK_GRID/wired-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -L "$MOCK_SKILLS/skill-w" ]      # allowlisted repo → wired
  [ ! -e "$MOCK_SKILLS/skill-l" ]    # library repo → not wired
  [ -L "$MOCK_SKILLS/skill-alpha" ]  # root skills always wired
}

@test "moving a repo to library un-wires its skills on re-run" {
  make_skill "$MOCK_GRID/repos/r1/skill-x" "skill-x"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -L "$MOCK_SKILLS/skill-x" ]
  printf 'otherrepo\n' > "$MOCK_GRID/wired-submodules.txt"   # r1 now library
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ ! -e "$MOCK_SKILLS/skill-x" ]    # teardown-rebuild drops the now-library link
}
