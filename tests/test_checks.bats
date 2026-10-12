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
  [[ "$output" == *"stale"* ]] || false
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
  [[ "$output" == *"skill-alpha"* ]] || false
  [ ! -e "$MOCK_SKILLS/skill-alpha" ]   # still missing: --check never repairs
}

@test "wire --check reports a stale grid-owned link" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  ln -s "$MOCK_GRID/skills/gone" "$MOCK_SKILLS/gone"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"gone"* ]] || false
}

@test "wire --check ignores foreign symlinks" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  ln -s "$OTHER_DIR" "$MOCK_SKILLS/foreign"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}

# --- sandbox tripwire ---------------------------------------------------------

@test "tripwire refuses a target inside the real ~/.claude" {
  fake_home=$(mktemp -d); mkdir -p "$fake_home/.claude"
  REAL_HOME="$fake_home" SKILLS_DIR="$fake_home/.claude" run assert_sandboxed
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

# An empty/unset HOME made `cd ""` succeed, so the "real home" silently became the
# cwd and every real-home comparison was against the wrong place (R16.qa.F7).
# The subshell function keeps `unset HOME` away from the rest of the test.
assert_sandboxed_without_home() ( unset HOME; assert_sandboxed )

@test "tripwire refuses an empty HOME" {
  HOME= run assert_sandboxed
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses an unset HOME" {
  run assert_sandboxed_without_home
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "common_setup refuses an empty HOME" {
  # Subshell so the failed setup cannot leak exports into the next test.
  run bash -c 'HOME=; unset REAL_HOME; BATS_TEST_FILENAME="$1"; source "$2"; common_setup' \
    _ "$BATS_TEST_FILENAME" "$REPO_ROOT/tests/helpers/setup.bash"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

# One test per guarded variable (R16.qa.F6): the loops in assert_sandboxed were only
# exercised through SKILLS_DIR, so deleting any other variable from them went
# unnoticed. tripwire_attempt <VAR> <subpath-of-fake-real-home> points VAR at that
# subpath and runs the tripwire; the subshell keeps the exports away from the test.
tripwire_attempt() (
  fake_home=$(mktemp -d); mkdir -p "$fake_home/$2"
  export REAL_HOME="$fake_home"
  export "$1=$fake_home/$2"
  assert_sandboxed
)

@test "tripwire refuses AGENTS_DIR inside the real home" {
  run tripwire_attempt AGENTS_DIR .claude/agents
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses RULES_DIR inside the real home" {
  run tripwire_attempt RULES_DIR .claude/rules
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses CLAUDE_CONFIG_DIR inside the real home" {
  run tripwire_attempt CLAUDE_CONFIG_DIR .claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses GRID_HOOK_LOG_DIR inside the real home" {
  run tripwire_attempt GRID_HOOK_LOG_DIR .grid/logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses GRID_HOOK_STATE_DIR inside the real home" {
  run tripwire_attempt GRID_HOOK_STATE_DIR .grid/state
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses GRID_HANDOFF_FALLBACK_DIR inside the real home" {
  run tripwire_attempt GRID_HANDOFF_FALLBACK_DIR .grid/fallback
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses GRID_PRIVATE_DIR inside the real home" {
  run tripwire_attempt GRID_PRIVATE_DIR .the-grid-private
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses GRID_STATE_DIR inside the real home" {
  run tripwire_attempt GRID_STATE_DIR .grid
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses GRID_LEARNING_DIR inside the real home" {
  run tripwire_attempt GRID_LEARNING_DIR .the-grid-private/learning
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses LAUNCH_AGENTS_DIR inside the real home" {
  run tripwire_attempt LAUNCH_AGENTS_DIR Library/LaunchAgents
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "tripwire refuses SYSTEMD_USER_DIR inside the real home" {
  run tripwire_attempt SYSTEMD_USER_DIR .config/systemd/user
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

# ~/.the-grid-private is one of the three roots in real_dirs: a dir inside it must
# be refused even when the variable is not the private-dir one.
@test "tripwire refuses a hook dir inside a real ~/.the-grid-private" {
  run tripwire_attempt GRID_HOOK_LOG_DIR .the-grid-private/logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

# XDG_RUNTIME_DIR is outside $HOME (/run/user/<uid>), so it is compared against the
# real runtime dir captured by common_setup, not against the real home.
@test "tripwire refuses XDG_RUNTIME_DIR equal to the real runtime dir" {
  fake_rt=$(mktemp -d)
  REAL_XDG_RUNTIME_DIR="$fake_rt" XDG_RUNTIME_DIR="$fake_rt" run assert_sandboxed
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

@test "common_setup points GRID_STATE_DIR and XDG_RUNTIME_DIR at sandbox dirs" {
  [ -n "$GRID_STATE_DIR" ]
  [ -n "$XDG_RUNTIME_DIR" ]
  [[ "$GRID_STATE_DIR" == "$MOCK_HOOK_ROOT"/* ]] || false
  [[ "$XDG_RUNTIME_DIR" == "$MOCK_HOOK_ROOT"/* ]] || false
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

@test "wire --check detects agent-side drift" {
  mkdir -p "$MOCK_GRID/agents"
  printf -- '---\nname: a1\n---\n' > "$MOCK_GRID/agents/a1.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/wire.sh"
  rm "$MOCK_AGENTS/a1.md"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"a1.md"* ]] || false
}
