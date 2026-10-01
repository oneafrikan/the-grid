#!/usr/bin/env bash
# Shared test helpers — sourced by each .bats file via `load helpers/setup`

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

common_setup() {
  MOCK_GRID=$(mktemp -d)
  MOCK_SKILLS=$(mktemp -d)
  OTHER_DIR=$(mktemp -d)
  mkdir -p "$MOCK_GRID/repos"
  # Point wire.sh's agents dir at a temp dir too, so tests never touch the real
  # ~/.claude/agents. Exported so child `bash wire.sh` invocations inherit it
  # even though test lines only set GRID_DIR/SKILLS_DIR inline.
  MOCK_AGENTS=$(mktemp -d)
  export AGENTS_DIR="$MOCK_AGENTS"
  # Isolation tripwire: default every target dir to a sandbox so a test that
  # forgets an inline override cannot reach the real ~/.claude, then refuse to
  # run at all if either target still resolves into it.
  export SKILLS_DIR="$MOCK_SKILLS"
  # Likewise isolate from the real private roles (~/.the-grid-private/roles is picked
  # up by default); an EMPTY value disables the fallback. Tests inject their own.
  export GRID_PRIVATE_ROLES_DIR=
  assert_sandboxed
}

# Abort the test (loudly) if a wire/catalog target points at the real ~/.claude.
assert_sandboxed() {
  local real d
  real="${REAL_HOME:-$HOME}/.claude"
  # Resolve symlinks on both sides (macOS /var -> /private/var) so spelling can't dodge the guard.
  real="$(cd "$real" 2>/dev/null && pwd -P || echo "$real")"
  for d in "${SKILLS_DIR:-}" "${AGENTS_DIR:-}"; do
    [ -n "$d" ] || continue
    case "$(cd "$d" 2>/dev/null && pwd -P)" in
      "$real"|"$real"/*) echo "REFUSING: test target $d is inside the real $real" >&2; return 1 ;;
    esac
  done
}

common_teardown() {
  rm -rf "$MOCK_GRID" "$MOCK_SKILLS" "$OTHER_DIR" "$MOCK_AGENTS"
  unset AGENTS_DIR SKILLS_DIR GRID_PRIVATE_ROLES_DIR
}

# Write a minimal valid skill dir to a given path
make_skill() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  printf -- "---\nname: %s\ndescription: Test skill %s\n---\n" "$name" "$name" > "$dir/SKILL.md"
}
