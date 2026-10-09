#!/usr/bin/env bats
# Tests for submodule initialization and symlink health in ~/.claude/skills/

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"

@test "all repos/ submodules are initialized (not empty)" {
  local failed=0
  while IFS= read -r repo_dir; do
    if [ -z "$(ls -A "$repo_dir" 2>/dev/null)" ]; then
      echo "Uninitialized submodule: $repo_dir" >&3
      failed=1
    fi
  done < <(find "$GRID_ROOT/repos" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  [ "$failed" -eq 0 ]
}

@test "no broken symlinks in skills dir" {
  local failed=0
  while IFS= read -r link; do
    if [ ! -e "$link" ]; then
      echo "Broken symlink: $link -> $(readlink "$link")" >&3
      failed=1
    fi
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null)
  [ "$failed" -eq 0 ]
}

@test "all grid-owned symlinks in skills dir resolve correctly" {
  local failed=0
  while IFS= read -r link; do
    local target
    target=$(readlink "$link")
    # Only check symlinks that point into the-grid
    [[ "$target" == "$GRID_ROOT"* ]] || continue
    if [ ! -e "$link" ]; then
      echo "Broken grid symlink: $link -> $target" >&3
      failed=1
    fi
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null)
  [ "$failed" -eq 0 ]
}

@test "skills dir exists" {
  # A CI runner has no ~/.claude/skills; on a real machine this stays a hard
  # health check (an honest skip beats a forced pass).
  if [ "${CI:-}" = "true" ] && [ ! -d "$SKILLS_DIR" ]; then
    skip "no skills dir on a CI runner"
  fi
  [ -d "$SKILLS_DIR" ]
}

# CI-only guard: tests.yml must build the agent-factory venv, otherwise ~80
# venv-gated tests silently skip ("agent-factory venv not built") and the gate
# means less than it claims. Fails loudly if the workflow regresses.
@test "agent-factory venv exists when CI=true" {
  [ "${CI:-}" = "true" ] || skip "only meaningful on CI (CI is not 'true')"
  [ -x "$GRID_ROOT/agent-factory/.venv/bin/python" ]
}
