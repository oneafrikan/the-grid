#!/usr/bin/env bash
# Shared test helpers — sourced by each .bats file via `load helpers/setup`

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

common_setup() {
  # Capture the real home FIRST: a test may later point HOME at a temp dir, and the
  # sandbox check below must still know where the real ~/.claude, ~/.grid and
  # ~/.the-grid-private live.
  export REAL_HOME="${REAL_HOME:-$HOME}"
  MOCK_GRID=$(mktemp -d)
  MOCK_SKILLS=$(mktemp -d)
  OTHER_DIR=$(mktemp -d)
  mkdir -p "$MOCK_GRID/repos"
  # Point wire.sh's agents dir at a temp dir too, so tests never touch the real
  # ~/.claude/agents. Exported so child `bash wire.sh` invocations inherit it
  # even though test lines only set GRID_DIR/SKILLS_DIR inline.
  MOCK_AGENTS=$(mktemp -d)
  export AGENTS_DIR="$MOCK_AGENTS"
  # Rule packs (rule-packs): wire.sh's rules tier writes under $RULES_DIR/grid, so a
  # test that forgets an override must land in a temp dir, never the real ~/.claude/rules.
  MOCK_RULES=$(mktemp -d)
  export RULES_DIR="$MOCK_RULES"
  # Isolation tripwire: default every target dir to a sandbox so a test that
  # forgets an inline override cannot reach the real ~/.claude, then refuse to
  # run at all if either target still resolves into it.
  export SKILLS_DIR="$MOCK_SKILLS"
  # Likewise isolate from the real private roles (~/.the-grid-private/roles is picked
  # up by default); an EMPTY value disables the fallback. Tests inject their own.
  export GRID_PRIVATE_ROLES_DIR=
  # Hook and user-settings state (hook-profiles): every location the hooks, the
  # auto-handoff worker or wire.sh could write to is a temp dir, so a test that
  # forgets an override fails the sandbox check instead of touching the real
  # ~/.claude, ~/.grid or ~/.the-grid-private.
  MOCK_HOOK_ROOT=$(mktemp -d)
  mkdir -p "$MOCK_HOOK_ROOT/claude" "$MOCK_HOOK_ROOT/logs" "$MOCK_HOOK_ROOT/state" \
           "$MOCK_HOOK_ROOT/fallback" "$MOCK_HOOK_ROOT/private"
  export CLAUDE_CONFIG_DIR="$MOCK_HOOK_ROOT/claude"
  export GRID_HOOK_LOG_DIR="$MOCK_HOOK_ROOT/logs"
  export GRID_HOOK_STATE_DIR="$MOCK_HOOK_ROOT/state"
  export GRID_HANDOFF_FALLBACK_DIR="$MOCK_HOOK_ROOT/fallback"
  export GRID_PRIVATE_DIR="$MOCK_HOOK_ROOT/private"
  # A path, not a file: the run log is created by the first append.
  export GRID_RUN_LOG="$MOCK_HOOK_ROOT/runs.jsonl"
  # Tripwire: the claude binary resolves to a path that cannot execute, so a test
  # that forgets to stub it fails loudly (exec fails, exit 127) instead of calling a
  # model. Tests that need a stub set GRID_CLAUDE themselves (see helpers/stubs.bash).
  export GRID_CLAUDE=/nonexistent/grid-claude-tripwire
  assert_sandboxed
}

# Abort the test (loudly) if a wire/catalog/hook target points at the real ~/.claude,
# ~/.grid or ~/.the-grid-private, or if the claude tripwire has been unset.
assert_sandboxed() {
  local real d real_dirs r
  real="${REAL_HOME:-$HOME}/.claude"
  # Resolve symlinks on both sides (macOS /var -> /private/var) so spelling can't dodge the guard.
  real="$(cd "$real" 2>/dev/null && pwd -P || echo "$real")"
  for d in "${SKILLS_DIR:-}" "${AGENTS_DIR:-}" "${RULES_DIR:-}"; do
    [ -n "$d" ] || continue
    case "$(cd "$d" 2>/dev/null && pwd -P)" in
      "$real"|"$real"/*) echo "REFUSING: test target $d is inside the real $real" >&2; return 1 ;;
    esac
  done
  # The hook-profiles dirs may not be set by a caller that predates them: only the
  # ones that are set are checked. Each must stay out of all three real roots.
  real_dirs=("$real" "${REAL_HOME:-$HOME}/.grid" "${REAL_HOME:-$HOME}/.the-grid-private")
  for d in "${CLAUDE_CONFIG_DIR:-}" "${GRID_HOOK_LOG_DIR:-}" "${GRID_HOOK_STATE_DIR:-}" \
           "${GRID_HANDOFF_FALLBACK_DIR:-}" "${GRID_PRIVATE_DIR:-}"; do
    [ -n "$d" ] || continue
    d="$(cd "$d" 2>/dev/null && pwd -P || echo "$d")"
    for r in "${real_dirs[@]}"; do
      r="$(cd "$r" 2>/dev/null && pwd -P || echo "$r")"
      case "$d" in
        "$r"|"$r"/*) echo "REFUSING: test dir $d is inside the real $r" >&2; return 1 ;;
      esac
    done
  done
  # GRID_CLAUDE must be set (to the tripwire or a stub), never empty.
  if [ -z "${GRID_CLAUDE:-}" ]; then
    echo "REFUSING: GRID_CLAUDE is unset or empty (the claude tripwire must stay armed)" >&2
    return 1
  fi
}

common_teardown() {
  rm -rf "$MOCK_GRID" "$MOCK_SKILLS" "$OTHER_DIR" "$MOCK_AGENTS" "$MOCK_HOOK_ROOT" "$MOCK_RULES"
  unset AGENTS_DIR SKILLS_DIR RULES_DIR GRID_PRIVATE_ROLES_DIR CLAUDE_CONFIG_DIR GRID_HOOK_LOG_DIR \
        GRID_HOOK_STATE_DIR GRID_HANDOFF_FALLBACK_DIR GRID_PRIVATE_DIR GRID_RUN_LOG GRID_CLAUDE
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
