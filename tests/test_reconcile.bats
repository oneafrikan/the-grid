#!/usr/bin/env bats
# Tests for scripts/reconcile.sh — the "remove real dirs that shadow grid skills, then re-wire"
# helper. The default run is documented as a read-only dry run; these tests pin that.
#
# The mock grid holds one skill. scripts/ is a symlink to the real scripts/ so reconcile.sh and
# the wire.sh it calls are the real ones. SKILLS_DIR / AGENTS_DIR / CLAUDE_CONFIG_DIR come from
# common_setup (all temp dirs, GRID_SKIP_AUDIT=1), so nothing here can reach a real home.
# These are the author's own checks; independent verification belongs to qa-engineer.

load helpers/setup

setup() {
  common_setup
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  ln -s "$REPO_ROOT/scripts" "$MOCK_GRID/scripts"
  export GRID_HOST=testbox
}

teardown() {
  unset GRID_HOST
  common_teardown
}

# snapshot DIR: every entry with mode, size, mtime and link target, C-sorted.
snapshot() { find "$1" -exec ls -ld {} + | LC_ALL=C sort; }

# reconcile [args...]: the real reconcile.sh against the mock grid.
reconcile() {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/reconcile.sh" "$@"
}

@test "no --force: lists the shadow and creates no link, no settings.json, no SKILLS.md, no .wired.manifest" {
  # A real dir that shadows the grid skill, plus a sentinel.
  mkdir -p "$MOCK_SKILLS/skill-alpha"
  : > "$MOCK_SKILLS/skill-alpha/stale.txt"
  local before_s before_a before_c before_g
  before_s="$(snapshot "$MOCK_SKILLS")"; before_a="$(snapshot "$MOCK_AGENTS")"
  before_c="$(snapshot "$CLAUDE_CONFIG_DIR")"; before_g="$(snapshot "$MOCK_GRID")"
  reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"Shadowing real dirs"* ]]
  [[ "$output" == *"- skill-alpha"* ]]
  [[ "$output" == *"Dry run"* ]]
  [ "$(snapshot "$MOCK_SKILLS")" = "$before_s" ]
  [ "$(snapshot "$MOCK_AGENTS")" = "$before_a" ]
  [ "$(snapshot "$CLAUDE_CONFIG_DIR")" = "$before_c" ]
  [ "$(snapshot "$MOCK_GRID")" = "$before_g" ]
  # Spelled out, so a snapshot helper that silently matched nothing cannot hide a write.
  [ -d "$MOCK_SKILLS/skill-alpha" ] && [ ! -L "$MOCK_SKILLS/skill-alpha" ]
  [ -f "$MOCK_SKILLS/skill-alpha/stale.txt" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/settings.json" ]
  [ ! -e "$MOCK_GRID/SKILLS.md" ] && [ ! -e "$MOCK_GRID/.wired.manifest" ]
  [ "$(find "$MOCK_SKILLS" "$MOCK_AGENTS" -type l | wc -l | tr -d ' ')" -eq 0 ]
}

@test "--force removes the shadow dir and the slot becomes a grid symlink" {
  mkdir -p "$MOCK_SKILLS/skill-alpha"
  : > "$MOCK_SKILLS/skill-alpha/stale.txt"
  reconcile --force
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ "$(readlink "$MOCK_SKILLS/skill-alpha")" = "$MOCK_GRID/skills/skill-alpha/" ]
  [ ! -e "$MOCK_SKILLS/skill-alpha/stale.txt" ]
  [[ "$output" == *"ok: skill-alpha -> grid"* ]]
}

@test "a real dir in a runtime-root slot (gstack) is not offered as a shadow" {
  # wire.sh links $SKILLS_DIR/gstack -> repos/gstack (the runtime root) and leaves an occupied
  # slot alone on purpose (gstack's own setup makes it a real dir): reconcile must agree.
  make_skill "$MOCK_GRID/repos/gstack/skill-g" "skill-g"
  mkdir -p "$MOCK_SKILLS/gstack"
  : > "$MOCK_SKILLS/gstack/keep.txt"
  reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to reconcile"* ]]
  [ -f "$MOCK_SKILLS/gstack/keep.txt" ]
}

@test "clean machine prints 'Nothing to reconcile' and exits 0, twice (second run identical)" {
  reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to reconcile"* ]]
  local first="$output" snap; snap="$(snapshot "$MOCK_SKILLS")"
  reconcile
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(snapshot "$MOCK_SKILLS")" = "$snap" ]
  [ "$(find "$MOCK_SKILLS" -type l | wc -l | tr -d ' ')" -eq 0 ]   # still nothing linked
}
