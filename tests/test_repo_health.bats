#!/usr/bin/env bats
# Tests for submodule initialization and symlink health in a fixture skills dir.

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

load helpers/venv

# A fixture skills dir, never the real ~/.claude/skills: the suite must not read (or depend
# on the state of) a developer's own home. It holds one grid-owned symlink that resolves.
setup_file() {
  mkdir -p "$BATS_FILE_TMPDIR/skills"
  ln -s "$GRID_ROOT/tests" "$BATS_FILE_TMPDIR/skills/fixture-skill"
  export SKILLS_DIR="$BATS_FILE_TMPDIR/skills"
}

# Sandbox lint (R16.qa.F8). A test file is protected from touching the real ~/.claude,
# ~/.grid or ~/.the-grid-private only if it calls common_setup (the assert_sandboxed
# tripwire) or is listed here with the reason it is safe without it. A NEW file that does
# neither fails the lint below, so the convention no longer depends on remembering it.
# Entry format: "<file>|<why it is safe without common_setup>".
SANDBOX_EXCEPTIONS=(
  "test_check_personal.bats|scans a throwaway git repo under BATS_TEST_TMPDIR with HOME and the denylist redirected there"
  "test_depersonalise.bats|read-only git ls-files/grep of the repo; writes nothing"
  "test_docs_factories.bats|read-only grep of tracked docs; writes nothing"
  "test_instincts_analyse.bats|HOME, state and learning dirs under BATS_TEST_TMPDIR, stubbed claude"
  "test_instincts_capture.bats|state and learning dirs env-redirected under BATS_TEST_TMPDIR"
  "test_instincts_desk.bats|text assertions on role files plus one run on a temp fixture store"
  "test_instincts_eval.bats|HOME under BATS_TEST_TMPDIR, stubbed claude"
  "test_instincts_inject.bats|state and learning dirs env-redirected under BATS_TEST_TMPDIR"
  "test_instincts_lib.bats|state and learning dirs env-redirected under BATS_TEST_TMPDIR"
  "test_instincts_schedule.bats|HOME and state under BATS_TEST_TMPDIR, stubbed schedulers that log and do nothing"
  "test_pages_site.bats|fixture GRID_DIR in a temp dir; the last two cases only read the real repo"
  "test_path_without.bats|pure helper test: PATH replaced by a fixture dir under BATS_TEST_TMPDIR, writes only there and BATS_FILE_TMPDIR"
  "test_render_schedule.bats|pure renderer, HOME in a temp dir; systemd-analyze runs in a private runtime dir"
  "test_repo_health.bats|reads the repo and a fixture skills dir under BATS_FILE_TMPDIR; writes nothing"
  "test_skill_format.bats|wire.sh runs into a throwaway GRID_DRY_HOME (helpers/wired.bash); the repo is only read"
  "test_submodule_sources.bats|read-only checks of .gitmodules and the tracked example baseline"
)

# sandbox_status <bats file> prints how the file relates to common_setup (R16.qa.F8, VF3):
#   sandboxed       setup() calls common_setup (a call line, not a comment or a name in text)
#   outside-setup   a call line exists, but not inside setup(): it is in a helper or a @test,
#                   so it may never run before the tests (a function that is defined and
#                   never called looked "sandboxed" to the earlier whole-file grep)
#   none            no call line at all
# POSIX awk: tracks whether the current top-level block is setup().
sandbox_status() {
  awk '
    /^[A-Za-z_@]/ { in_setup = ($0 ~ /^setup\(\)/) }
    /^[[:space:]]*common_setup([[:space:]]|$)/ { if (in_setup) ins = 1; else outs = 1 }
    END { print (ins ? "sandboxed" : (outs ? "outside-setup" : "none")) }
  ' "$1"
}

@test "every test file sandboxes or is excepted" {
  local failed=0 f base e listed status
  for f in "$GRID_ROOT"/tests/*.bats; do
    base="$(basename "$f")"
    listed=0
    for e in ${SANDBOX_EXCEPTIONS[@]+"${SANDBOX_EXCEPTIONS[@]}"}; do
      [ "${e%%|*}" = "$base" ] && listed=1
    done
    status="$(sandbox_status "$f")"
    if [ "$status" = "outside-setup" ]; then
      echo "Calls common_setup outside setup(): $base" >&3; failed=1
    elif [ "$status" = "sandboxed" ]; then
      if [ "$listed" -eq 1 ]; then
        echo "Stale exception (now calls common_setup): $base" >&3; failed=1
      fi
    elif [ "$listed" -eq 0 ]; then
      echo "Neither calls common_setup nor is excepted: $base" >&3; failed=1
    fi
  done
  # An exception for a file that no longer exists is also stale.
  for e in ${SANDBOX_EXCEPTIONS[@]+"${SANDBOX_EXCEPTIONS[@]}"}; do
    [ -f "$GRID_ROOT/tests/${e%%|*}" ] || { echo "Exception for a missing file: ${e%%|*}" >&3; failed=1; }
  done
  [ "$failed" -eq 0 ]
}

@test "sandbox lint tells a setup() call from a helper that is never called" {
  printf 'setup() {\n  common_setup\n}\n@test "x" {\n  true\n}\n' > "$BATS_TEST_TMPDIR/ok.bats"
  [ "$(sandbox_status "$BATS_TEST_TMPDIR/ok.bats")" = "sandboxed" ]
  # Defined but never called: setup() does something else.
  printf 'helper() {\n  common_setup\n}\nsetup() {\n  true\n}\n' > "$BATS_TEST_TMPDIR/helper.bats"
  [ "$(sandbox_status "$BATS_TEST_TMPDIR/helper.bats")" = "outside-setup" ]
  # Called from a test body, not setup().
  printf 'setup() {\n  true\n}\n@test "x" {\n  common_setup\n}\n' > "$BATS_TEST_TMPDIR/intest.bats"
  [ "$(sandbox_status "$BATS_TEST_TMPDIR/intest.bats")" = "outside-setup" ]
  # Only named in a comment.
  printf '# common_setup is not called here\nsetup() {\n  true\n}\n' > "$BATS_TEST_TMPDIR/comment.bats"
  [ "$(sandbox_status "$BATS_TEST_TMPDIR/comment.bats")" = "none" ]
}

@test "all repos/ submodules are initialized (not empty)" {
  local failed=0 seen=0
  while IFS= read -r repo_dir; do
    seen=$((seen + 1))
    if [ -z "$(ls -A "$repo_dir" 2>/dev/null)" ]; then
      echo "Uninitialized submodule: $repo_dir" >&3
      failed=1
    fi
  done < <(find "$GRID_ROOT/repos" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  # A loop over zero dirs passes: an empty or missing repos/ must not read as healthy.
  [ "$seen" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "no broken symlinks in skills dir" {
  local failed=0 seen=0
  while IFS= read -r link; do
    seen=$((seen + 1))
    if [ ! -e "$link" ]; then
      echo "Broken symlink: $link -> $(readlink "$link")" >&3
      failed=1
    fi
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null)
  # The fixture holds one link, so zero means the fixture (or the find) broke.
  [ "$seen" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "all grid-owned symlinks in skills dir resolve correctly" {
  local failed=0 seen=0
  while IFS= read -r link; do
    local target
    target=$(readlink "$link")
    # Only check symlinks that point into the-grid
    [[ "$target" == "$GRID_ROOT"* ]] || continue
    seen=$((seen + 1))
    if [ ! -e "$link" ]; then
      echo "Broken grid symlink: $link -> $target" >&3
      failed=1
    fi
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null)
  [ "$seen" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "skills dir exists" {
  # SKILLS_DIR is the fixture dir from setup_file, so this only proves the fixture
  # was built; the CI skip stays for a runner where it could not be.
  if [ "${CI:-}" = "true" ] && [ ! -d "$SKILLS_DIR" ]; then
    skip "no skills dir on a CI runner"
  fi
  [ -d "$SKILLS_DIR" ]
}

# Venv guard (R16.qa.F5). tests.yml must build the agent-factory venv and the local gate
# (GRID_REQUIRE_VENV=1) needs it too: ~215 tests across 15 files are venv-gated, and
# without it they all skip while bats still exits 0. So when either variable is set the
# venv must exist AND import PyYAML (a bare "python is executable" passed a half-built
# venv). Runs the same helper the gated files use, so the two cannot disagree.
@test "agent-factory venv is usable when CI=true or GRID_REQUIRE_VENV=1" {
  [ "${CI:-}" = "true" ] || [ "${GRID_REQUIRE_VENV:-}" = "1" ] \
    || skip "only meaningful when CI=true or GRID_REQUIRE_VENV=1"
  require_venv "$GRID_ROOT/agent-factory/.venv/bin/python"
}

# require_venv itself, driven in a child bash with a stub `skip` (bats' own skip cannot be
# observed from inside `run`). $1 = the python to pass; the rest are env assignments.
# Prints "SKIPPED: <why>" if the helper skipped, "REACHED" if it returned 0.
run_require_venv() {
  local py="$1"; shift
  run env -u CI -u GRID_REQUIRE_VENV "$@" bash -c '
    skip() { echo "SKIPPED: $*"; exit 0; }
    source "$1"; require_venv "$2" && echo REACHED' _ "$GRID_ROOT/tests/helpers/venv.bash" "$py"
}

# A python stand-in: exit status of `-c import yaml` is the one thing the helper looks at.
fake_python() { # $1 = exit status of the stub
  printf '#!/bin/sh\nexit %s\n' "$1" > "$BATS_TEST_TMPDIR/python"
  chmod +x "$BATS_TEST_TMPDIR/python"
  printf '%s\n' "$BATS_TEST_TMPDIR/python"
}

@test "require_venv skips (does not fail) a missing venv when nothing demands it" {
  run_require_venv "$BATS_TEST_TMPDIR/no-such-python"
  [ "$status" -eq 0 ]
  [[ "$output" == "SKIPPED: agent-factory venv not built" ]] || false
}

@test "require_venv fails a missing venv under GRID_REQUIRE_VENV=1" {
  run_require_venv "$BATS_TEST_TMPDIR/no-such-python" GRID_REQUIRE_VENV=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"venv required (agent-factory venv not built)"* ]] || false
}

@test "require_venv fails a missing venv under CI=true" {
  run_require_venv "$BATS_TEST_TMPDIR/no-such-python" CI=true
  [ "$status" -eq 1 ]
  [[ "$output" == *"venv required"* ]] || false
}

@test "require_venv treats an executable python without PyYAML as missing" {
  local py; py="$(fake_python 1)"
  run_require_venv "$py" GRID_REQUIRE_VENV=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"venv required (agent-factory venv has no PyYAML)"* ]] || false
  run_require_venv "$py"
  [ "$status" -eq 0 ]
  [[ "$output" == "SKIPPED: agent-factory venv has no PyYAML" ]] || false
}

@test "require_venv passes a python that imports PyYAML, with or without the demand" {
  local py; py="$(fake_python 0)"
  run_require_venv "$py" GRID_REQUIRE_VENV=1
  [ "$status" -eq 0 ]
  [ "$output" = "REACHED" ]
  run_require_venv "$py"
  [ "$output" = "REACHED" ]
}

# Dead-assertion lint (R16.qa.F3). Under bats a command that is neither the last one of a
# @test nor guarded can fail without failing the test: `set -e` ignores a failing `! cmd`
# and every non-final member of an `A && B` list, so `! grep -q x f` or
# `[ A ] && [ B ]` in the middle of a test asserts nothing. The fix is the form that does
# fail: `! cmd || false`, or two separate `[ ]` lines. Prints "<file>:<line>: <text>" for
# each offender in tests/*.bats; $1 is "negation" or "andlist".
#
# What it does NOT cover: a bare `[[ ... ]]` in mid-test only goes dead on bash 3.2
# (macOS /bin/bash), which CI does not run, so those ~200 lines are left alone rather than
# converted blind with no failing run to prove the change.
#
# Scans @test bodies and the helper functions defined in the .bats files (a failing `! cmd`
# is just as dead there). Statement-level: lines ending in a backslash are joined, heredoc
# bodies and comments are skipped, and the last command before the closing `}` is exempt
# because its status IS the test's (or function's) status. POSIX awk only (macOS awk has no \s or gawk extensions).
dead_assertions() {
  local f
  for f in "$GRID_ROOT"/tests/*.bats; do
    awk -v file="$(basename "$f")" -v kind="$1" '
      function check(i,   s) {
        s = stmt[i]
        # Guarded forms that DO fail: `|| false`, `|| return N`, `|| exit N`, `|| { ...; false; }`.
        if (s ~ /\|\|[[:space:]]*(\{.*)?(false|return|exit)([[:space:]]|;|\}|$)/) return
        if (kind == "negation" && s ~ /^[[:space:]]+! /) print file ":" ln[i] ": " s
        if (kind == "andlist" && s ~ /\] && \[/ && s !~ /^[[:space:]]*(if|elif|while|until)[[:space:]]/)
          print file ":" ln[i] ": " s
      }
      # First, so a `}` at column 0 inside a heredoc body cannot end the function early.
      term != "" { t = $0; sub(/^[[:space:]]+/, "", t); if (t == term) term = ""; next }
      /^(@test |[A-Za-z_][A-Za-z0-9_]*\(\))/ && /[\{\(]([[:space:]]*#.*)?[[:space:]]*$/ { intest = 1; n = 0; cont = ""; next }
      intest && /^[})]/ {
        for (i = 1; i < n; i++) check(i)   # the final command is exempt
        intest = 0; next
      }
      !intest { next }
      /^[[:space:]]*(#.*)?$/ { next }
      {
        line = $0
        if (cont == "") start = NR
        if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); cont = cont line " "; next }
        n++; stmt[n] = cont line; ln[n] = start; cont = ""
        # A heredoc opened on this statement swallows lines up to its terminator.
        if (line !~ /<<</ && line ~ /<<-?[[:space:]]*["\047]?[A-Za-z_]+/) {
          t = line; sub(/^.*<<-?[[:space:]]*["\047]?/, "", t); sub(/["\047]?([^A-Za-z_].*)?$/, "", t); term = t
        }
      }
    ' "$f"
  done
}

@test "no mid-test bare negation (it can never fail the test)" {
  run dead_assertions negation
  [ -z "$output" ] || { echo "$output" >&3; false; }
}

@test "no mid-test && assertion (only the last member can fail the test)" {
  run dead_assertions andlist
  [ -z "$output" ] || { echo "$output" >&3; false; }
}
