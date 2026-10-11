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

# path_without GLOB... -> prints a temp dir holding a symlink to every executable
# found on the CURRENT $PATH whose basename matches none of the globs. The caller
# sets PATH to that dir to simulate a machine without a tool, e.g.
#   PATH="$(path_without 'python3*' python)" run bash wire.sh
# Earlier PATH entries win on duplicate names, like a normal lookup. The dir is
# created under BATS_TEST_TMPDIR when set (bats removes it), else TMPDIR or /tmp.
path_without() {
  local dir d f base g skip
  dir="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/pathwithout.XXXXXX")"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      base="$(basename "$f")"
      skip=0
      for g in "$@"; do
        # $g is deliberately an unquoted glob pattern.
        # shellcheck disable=SC2254
        case "$base" in $g) skip=1; break ;; esac
      done
      [ "$skip" = 0 ] || continue
      [ -e "$dir/$base" ] || [ -L "$dir/$base" ] || ln -s "$f" "$dir/$base"
    done
  done
  printf '%s\n' "$dir"
}
