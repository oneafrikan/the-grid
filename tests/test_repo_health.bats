#!/usr/bin/env bats
# Tests for submodule initialization and symlink health in a fixture skills dir.

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

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
  "test_gh_app_token.bats|HOME and TMPDIR in temp dirs, stub curl, throwaway keys; no network"
  "test_instantiate.bats|HOME, SYSTEMD_USER_DIR and LAUNCH_AGENTS_DIR in temp dirs, stubbed gh/claude/schedulers"
  "test_instincts_analyse.bats|HOME, state and learning dirs under BATS_TEST_TMPDIR, stubbed claude"
  "test_instincts_capture.bats|state and learning dirs env-redirected under BATS_TEST_TMPDIR"
  "test_instincts_desk.bats|text assertions on role files plus one run on a temp fixture store"
  "test_instincts_eval.bats|HOME under BATS_TEST_TMPDIR, stubbed claude"
  "test_instincts_inject.bats|state and learning dirs env-redirected under BATS_TEST_TMPDIR"
  "test_instincts_lib.bats|state and learning dirs env-redirected under BATS_TEST_TMPDIR"
  "test_instincts_schedule.bats|HOME and state under BATS_TEST_TMPDIR, stubbed schedulers that log and do nothing"
  "test_issue_loop_hooks.bats|HOME and every repo in temp dirs, stubbed gh/claude, real-gh shim fails the file"
  "test_issue_loop_runner.bats|HOME, TMPDIR and AGENTS_DIR in temp dirs, stubbed gh/claude, temp bare origin"
  "test_pages_site.bats|fixture GRID_DIR in a temp dir; the last two cases only read the real repo"
  "test_render_schedule.bats|pure renderer, HOME in a temp dir; systemd-analyze runs in a private runtime dir"
  "test_repo_health.bats|reads the repo and a fixture skills dir under BATS_FILE_TMPDIR; writes nothing"
  "test_skill_format.bats|wire.sh runs into a throwaway GRID_DRY_HOME (helpers/wired.bash); the repo is only read"
  "test_submodule_sources.bats|read-only checks of .gitmodules and the tracked example baseline"
)

@test "every test file sandboxes or is excepted" {
  local failed=0 f base e listed
  for f in "$GRID_ROOT"/tests/*.bats; do
    base="$(basename "$f")"
    listed=0
    for e in ${SANDBOX_EXCEPTIONS[@]+"${SANDBOX_EXCEPTIONS[@]}"}; do
      [ "${e%%|*}" = "$base" ] && listed=1
    done
    if grep -qE '^[[:space:]]*common_setup([[:space:]]|$)' "$f"; then
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
  # SKILLS_DIR is the fixture dir from setup_file, so this only proves the fixture
  # was built; the CI skip stays for a runner where it could not be.
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
