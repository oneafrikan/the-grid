#!/usr/bin/env bash
# Shared test helpers — sourced by each .bats file via `load helpers/setup`

# shellcheck disable=SC2034  # read by the .bats files that load this helper
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

common_setup() {
  # An empty/unset HOME makes `cd ""` succeed, turning the "real home" into the cwd and
  # disarming every comparison below; refuse before anything is derived from it.
  [ -n "${HOME:-}" ] || { echo "REFUSING: HOME is unset or empty" >&2; return 1; }
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
  # Machine-local state (~/.grid by default) and the user runtime dir (/run/user/<uid>,
  # where the live systemd manager's sockets live) are sandboxed too. REAL_XDG_RUNTIME_DIR
  # remembers the real one, as REAL_HOME does, because it is not under $HOME and so the
  # tripwire needs the value itself.
  export REAL_XDG_RUNTIME_DIR="${REAL_XDG_RUNTIME_DIR-${XDG_RUNTIME_DIR:-}}"
  mkdir -p "$MOCK_HOOK_ROOT/grid-state" "$MOCK_HOOK_ROOT/runtime"
  chmod 700 "$MOCK_HOOK_ROOT/runtime"
  export GRID_STATE_DIR="$MOCK_HOOK_ROOT/grid-state"
  export XDG_RUNTIME_DIR="$MOCK_HOOK_ROOT/runtime"
  # A path, not a file: the run log is created by the first append.
  export GRID_RUN_LOG="$MOCK_HOOK_ROOT/runs.jsonl"
  # Tripwire: the claude binary resolves to a path that cannot execute, so a test
  # that forgets to stub it fails loudly (exec fails, exit 127) instead of calling a
  # model. Tests that need a stub set GRID_CLAUDE themselves (see helpers/stubs.bash).
  export GRID_CLAUDE=/nonexistent/grid-claude-tripwire
  # Harness wiring (multi-harness): non-Claude skills/agents/rules dirs resolve under
  # GRID_HARNESS_HOME, so it is a temp dir. The "home dir" leaf contains a space on
  # purpose: any unquoted expansion in the wiring code then fails a test. The inherited
  # GRID_HARNESS / XDG_CONFIG_HOME / GRID_DRY_HOME are dropped (GRID_DRY_HOME would
  # otherwise override this sandbox base, and XDG would relocate OpenCode's dir).
  MOCK_HARNESS_ROOT=$(mktemp -d)
  MOCK_HARNESS_HOME="$MOCK_HARNESS_ROOT/home dir"
  mkdir -p "$MOCK_HARNESS_HOME"
  export GRID_HARNESS_HOME="$MOCK_HARNESS_HOME"
  unset GRID_HARNESS XDG_CONFIG_HOME GRID_DRY_HOME
  # wire.sh fails closed when policy.yaml is missing (exit 3), and most mock grids have none:
  # skip the audit by default. The audit's own tests (test_audit_integration.bats and the
  # grid_fixture users) unset it again.
  export GRID_SKIP_AUDIT=1
  assert_sandboxed
}

# Abort the test (loudly) if a wire/catalog/hook target points at the real ~/.claude,
# ~/.grid or ~/.the-grid-private, or if the claude tripwire has been unset.
assert_sandboxed() {
  # An empty/unset HOME makes `cd ""` succeed, turning the "real home" into the cwd and
  # disarming every comparison below; refuse before anything is derived from it.
  [ -n "${HOME:-}" ] || { echo "REFUSING: HOME is unset or empty" >&2; return 1; }
  local real d real_dirs r
  real="${REAL_HOME:-$HOME}/.claude"
  # Resolve symlinks on both sides (macOS /var -> /private/var) so spelling can't dodge the guard.
  real="$(cd "$real" 2>/dev/null && pwd -P || echo "$real")"
  for d in "${SKILLS_DIR:-}" "${AGENTS_DIR:-}" "${RULES_DIR:-}"; do
    [ -n "$d" ] || continue
    case "$(cd "$d" 2>/dev/null && pwd -P || echo "$d")" in
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
  # Whole-home targets: state, learning store and scheduler unit dirs default to places
  # under ~ that are NOT one of the three roots above (~/.config/systemd/user,
  # ~/Library/LaunchAgents), so these are compared against the real home itself.
  r="$(cd "${REAL_HOME:-$HOME}" 2>/dev/null && pwd -P || echo "${REAL_HOME:-$HOME}")"
  for d in "${GRID_STATE_DIR:-}" "${GRID_LEARNING_DIR:-}" "${LAUNCH_AGENTS_DIR:-}" "${SYSTEMD_USER_DIR:-}"; do
    [ -n "$d" ] || continue
    d="$(cd "$d" 2>/dev/null && pwd -P || echo "$d")"
    case "$d" in
      "$r"|"$r"/*) echo "REFUSING: test dir $d is inside the real home $r" >&2; return 1 ;;
    esac
  done
  # The live user runtime dir holds the systemd manager's private socket: a test that
  # runs systemd-analyze/systemctl against it can unlink that socket.
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    d="$(cd "$XDG_RUNTIME_DIR" 2>/dev/null && pwd -P || echo "$XDG_RUNTIME_DIR")"
    for r in "${REAL_XDG_RUNTIME_DIR:-}" "/run/user/$(id -u)"; do
      [ -n "$r" ] || continue
      r="$(cd "$r" 2>/dev/null && pwd -P || echo "$r")"
      case "$d" in
        "$r"|"$r"/*) echo "REFUSING: XDG_RUNTIME_DIR $d is the real runtime dir $r (or inside it)" >&2; return 1 ;;
      esac
    done
  fi
  # GRID_HARNESS_HOME must be set and must stay out of the real home: it is the base of
  # every non-Claude harness dir (~/.agents/skills, ~/.codex/agents, ...).
  if [ -z "${GRID_HARNESS_HOME:-}" ]; then
    echo "REFUSING: GRID_HARNESS_HOME is unset or empty (harness dirs would resolve into the real home)" >&2
    return 1
  fi
  r="$(cd "${REAL_HOME:-$HOME}" 2>/dev/null && pwd -P || echo "${REAL_HOME:-$HOME}")"
  d="$(cd "$GRID_HARNESS_HOME" 2>/dev/null && pwd -P || echo "$GRID_HARNESS_HOME")"
  case "$d" in
    "$r"|"$r"/*) echo "REFUSING: GRID_HARNESS_HOME $d is the real home $r (or inside it)" >&2; return 1 ;;
  esac
  # GRID_CLAUDE must be set (to the tripwire or a stub), never empty.
  if [ -z "${GRID_CLAUDE:-}" ]; then
    echo "REFUSING: GRID_CLAUDE is unset or empty (the claude tripwire must stay armed)" >&2
    return 1
  fi
}

common_teardown() {
  rm -rf "$MOCK_GRID" "$MOCK_SKILLS" "$OTHER_DIR" "$MOCK_AGENTS" "$MOCK_HOOK_ROOT" "$MOCK_RULES" \
         "${MOCK_HARNESS_ROOT:-}"
  unset AGENTS_DIR SKILLS_DIR RULES_DIR GRID_PRIVATE_ROLES_DIR CLAUDE_CONFIG_DIR GRID_HOOK_LOG_DIR \
        GRID_HOOK_STATE_DIR GRID_HANDOFF_FALLBACK_DIR GRID_PRIVATE_DIR GRID_RUN_LOG GRID_CLAUDE \
        GRID_HARNESS_HOME GRID_HARNESS MOCK_HARNESS_ROOT MOCK_HARNESS_HOME \
        GRID_STATE_DIR XDG_RUNTIME_DIR REAL_XDG_RUNTIME_DIR GRID_SKIP_AUDIT
}

# systemd_verify_private <unit file>... — `run` `systemd-analyze --user verify` against a
# PRIVATE runtime dir (R16.qa.F2, R06.qa.F12). verify talks to a user manager through
# $XDG_RUNTIME_DIR/systemd/private: with the real runtime dir set it can unlink the live
# manager's socket, with it unset it fails outright. So the runtime dir (and config dir)
# are temp dirs under $BATS_TEST_TMPDIR, and the test SKIPS, not fails, when a probe of a
# known-good unit cannot succeed there (no user-mode systemd, or the AF_UNIX socket path
# is too long for a deep TMPDIR). Sets $status/$output via `run`.
systemd_verify_private() {
  local rt="$BATS_TEST_TMPDIR/xdg-rt"
  mkdir -p "$rt/config"
  chmod 700 "$rt"
  printf '[Unit]\nDescription=probe\n[Service]\nType=oneshot\nExecStart=/bin/true\n' > "$rt/probe.service"
  if ! env XDG_RUNTIME_DIR="$rt" XDG_CONFIG_HOME="$rt/config" \
       systemd-analyze --user verify "$rt/probe.service" >/dev/null 2>&1; then
    skip "systemd-analyze --user cannot run in a private runtime dir here"
  fi
  run env XDG_RUNTIME_DIR="$rt" XDG_CONFIG_HOME="$rt/config" systemd-analyze --user verify "$@"
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
# Speed (R15.qa.F5): the basename is cut with ${f##*/} (a `basename` fork per executable
# on PATH made one call take ~22-24 s), and when BATS_FILE_TMPDIR is set the result is
# cached there per file, keyed by cksum of "$PATH|$*", so a repeated call is instant. A
# cached dir is shared by every test in the file, so callers must only READ it (use it as
# PATH), never add to or remove from it.
path_without() {
  local dir d f base g skip key="" hit pyfam=0
  # A caller that names a python glob wants "no python at all": hide the whole family too, or
  # python2.7 / pydoc3 stay on PATH and the "no python" test proves nothing (R16.qa.F11).
  # Callers that name no python glob keep the plain model.
  for g in "$@"; do case "$g" in python*) pyfam=1 ;; esac; done
  if [ -n "${BATS_FILE_TMPDIR:-}" ] && command -v cksum >/dev/null; then
    key="$(printf '%s|%s' "$PATH" "$*" | cksum)"; key="${key%% *}"
    # a finished cache dir carries a .complete marker (a half-built one is never reused)
    for hit in "$BATS_FILE_TMPDIR"/pathwithout."$key".*; do
      if [ -e "$hit/.complete" ]; then printf '%s\n' "$hit"; return 0; fi
    done
    dir="$(mktemp -d "$BATS_FILE_TMPDIR/pathwithout.$key.XXXXXX")"
  else
    dir="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/pathwithout.XXXXXX")"
  fi
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      base="${f##*/}"
      skip=0
      for g in "$@"; do
        # $g is deliberately an unquoted glob pattern.
        # shellcheck disable=SC2254
        case "$base" in $g) skip=1; break ;; esac
      done
      if [ "$pyfam" = 1 ]; then case "$base" in python*|pydoc*) skip=1 ;; esac; fi
      [ "$skip" = 0 ] || continue
      [ -e "$dir/$base" ] || [ -L "$dir/$base" ] || ln -s "$f" "$dir/$base"
    done
  done
  [ -z "$key" ] || : > "$dir/.complete"
  printf '%s\n' "$dir"
}
