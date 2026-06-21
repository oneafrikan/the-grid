#!/usr/bin/env bats
# Tests for wire.sh — the script that creates ~/.claude/skills/ symlinks

load helpers/setup

setup() {
  common_setup
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  make_skill "$MOCK_GRID/skills/skill-beta"  "skill-beta"
}

teardown() {
  common_teardown
}

@test "creates a symlink per skill in the target dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
}

@test "symlinks resolve to directories (not dangling)" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -d "$MOCK_SKILLS/skill-alpha" ]
  [ -d "$MOCK_SKILLS/skill-beta" ]
}

@test "running wire.sh twice is idempotent" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
}

@test "removes stale symlink when skill is deleted from the-grid" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  rm -rf "$MOCK_GRID/skills/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -e "$MOCK_SKILLS/skill-alpha" ]
  [ ! -L "$MOCK_SKILLS/skill-alpha" ]
}

@test "does not remove symlinks owned by other sources" {
  mkdir -p "$OTHER_DIR/external-skill"
  ln -s "$OTHER_DIR/external-skill" "$MOCK_SKILLS/external-skill"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/external-skill" ]
}

@test "wires skills found inside repos/ submodules (flat)" {
  make_skill "$MOCK_GRID/repos/gstack/skill-gstack" "skill-gstack"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-gstack" ]
  [ -d "$MOCK_SKILLS/skill-gstack" ]
}

@test "wires skills nested under skills/ subdir (mattpocock/superpowers style)" {
  make_skill "$MOCK_GRID/repos/mattpocock/skills/engineering/skill-deep" "skill-deep"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-deep" ]
  [ -d "$MOCK_SKILLS/skill-deep" ]
}

@test "skips repo-root SKILL.md (gstack style)" {
  mkdir -p "$MOCK_GRID/repos/gstack"
  printf -- "---\nname: gstack\ndescription: repo root\n---\n" > "$MOCK_GRID/repos/gstack/SKILL.md"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -L "$MOCK_SKILLS/gstack" ]
}

@test "does not create symlinks for repos/ dir itself or tests/ dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -L "$MOCK_SKILLS/repos" ]
  [ ! -L "$MOCK_SKILLS/tests" ]
}

@test "baseline-submodules.txt allowlist: only listed repos are wired" {
  make_skill "$MOCK_GRID/repos/wiredrepo/skill-w" "skill-w"
  make_skill "$MOCK_GRID/repos/libraryrepo/skill-l" "skill-l"
  printf 'wiredrepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-w" ]      # allowlisted repo → wired
  [ ! -e "$MOCK_SKILLS/skill-l" ]    # library repo → not wired
  [ -L "$MOCK_SKILLS/skill-alpha" ]  # root skills always wired
}

@test "moving a repo to library un-wires its skills on re-run" {
  make_skill "$MOCK_GRID/repos/r1/skill-x" "skill-x"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-x" ]
  printf 'otherrepo\n' > "$MOCK_GRID/baseline-submodules.txt"   # r1 now library
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -e "$MOCK_SKILLS/skill-x" ]    # teardown-rebuild drops the now-library link
}

@test "per-skill entry wires only the named skill, not others in the same repo" {
  make_skill "$MOCK_GRID/repos/myrepo/skill-one" "skill-one"
  make_skill "$MOCK_GRID/repos/myrepo/skill-two" "skill-two"
  printf 'myrepo/skill-one\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-one" ]     # listed → wired
  [ ! -e "$MOCK_SKILLS/skill-two" ]   # not listed → not wired
}

@test "per-skill entry coexists with whole-repo entry" {
  make_skill "$MOCK_GRID/repos/fullrepo/skill-a" "skill-a"
  make_skill "$MOCK_GRID/repos/partialrepo/skill-b" "skill-b"
  make_skill "$MOCK_GRID/repos/partialrepo/skill-c" "skill-c"
  printf 'fullrepo\npartialrepo/skill-b\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-a" ]       # whole-repo → wired
  [ -L "$MOCK_SKILLS/skill-b" ]       # listed per-skill → wired
  [ ! -e "$MOCK_SKILLS/skill-c" ]     # unlisted per-skill → not wired
}

# --- machine overlay (machines/<host>.txt) -----------------------------------

@test "machine overlay adds skills on top of the baseline" {
  make_skill "$MOCK_GRID/repos/baserepo/skill-base" "skill-base"
  make_skill "$MOCK_GRID/repos/extrarepo/skill-extra" "skill-extra"
  printf 'baserepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf 'extrarepo\n' > "$MOCK_GRID/machines/testbox.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-base" ]    # baseline → wired everywhere
  [ -L "$MOCK_SKILLS/skill-extra" ]   # overlay add → wired on this host
}

@test "unknown host wires the baseline only (no matching overlay)" {
  make_skill "$MOCK_GRID/repos/baserepo/skill-base" "skill-base"
  make_skill "$MOCK_GRID/repos/extrarepo/skill-extra" "skill-extra"
  printf 'baserepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf 'extrarepo\n' > "$MOCK_GRID/machines/otherbox.txt"   # overlay for a DIFFERENT host
  GRID_HOST=nosuchbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-base" ]    # baseline still wired
  [ ! -e "$MOCK_SKILLS/skill-extra" ] # other host's overlay → not applied here
}

@test "overlay subtraction (-repo) removes a baseline whole-repo entry" {
  make_skill "$MOCK_GRID/repos/keeprepo/skill-keep" "skill-keep"
  make_skill "$MOCK_GRID/repos/droprepo/skill-drop" "skill-drop"
  printf 'keeprepo\ndroprepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf -- '-droprepo\n' > "$MOCK_GRID/machines/testbox.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-keep" ]
  [ ! -e "$MOCK_SKILLS/skill-drop" ] # subtracted on this host
}

@test "overlay subtraction (-repo/skill) excludes one skill of a whole-repo entry" {
  make_skill "$MOCK_GRID/repos/bigrepo/skill-one" "skill-one"
  make_skill "$MOCK_GRID/repos/bigrepo/skill-two" "skill-two"
  printf 'bigrepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf -- '-bigrepo/skill-two\n' > "$MOCK_GRID/machines/testbox.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-one" ]
  [ ! -e "$MOCK_SKILLS/skill-two" ] # one skill subtracted, rest of repo kept
}

# --- composed-project gating (project:<name>) --------------------------------

@test "project gating wires only the listed composed projects" {
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents"
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents"
  printf -- '---\nname: agent-a\n---\n' > "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents/agent-a.md"
  printf -- '---\nname: agent-b\n---\n' > "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents/agent-b.md"
  printf 'project:team-a\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_AGENTS/agent-a.md" ]    # listed project → wired
  [ ! -e "$MOCK_AGENTS/agent-b.md" ]  # unlisted project → not wired
}

@test "no project: entries wires every composed project (legacy fallback)" {
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents"
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents"
  printf -- '---\nname: agent-a\n---\n' > "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents/agent-a.md"
  printf -- '---\nname: agent-b\n---\n' > "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents/agent-b.md"
  printf 'somerepo\n' > "$MOCK_GRID/baseline-submodules.txt"   # no project: entries
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_AGENTS/agent-a.md" ]
  [ -L "$MOCK_AGENTS/agent-b.md" ]
}
