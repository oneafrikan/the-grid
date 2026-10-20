#!/usr/bin/env bats
# Tests for scripts/gate.sh — the commit gate. Each test runs a COPY of the gate
# inside a throwaway git repo with stub tools, so it never touches this repo's
# config, hook path or working tree.

load helpers/setup

setup() {
  common_setup
  G=$(mktemp -d)
  mkdir -p "$G/scripts" "$G/.githooks" "$G/tests/lib/bats-core/bin" "$G/stubbin"
  cp "$REPO_ROOT/scripts/gate.sh" "$G/scripts/gate.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/scripts/catalog.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/scripts/check-personal.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/.githooks/pre-commit"
  printf '#!/usr/bin/env bash\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  chmod +x "$G"/scripts/*.sh "$G/.githooks/pre-commit" "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  ( cd "$G" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init )
  # PATH with essentials but no shellcheck (tr/wc/xargs: needed by the real check-personal.sh)
  for t in git bash env dirname grep cat rm mkdir mktemp uname sed tr wc xargs; do
    ln -s "$(command -v $t)" "$G/stubbin/$t" 2>/dev/null || true
  done
}

teardown() {
  rm -rf "$G"
  common_teardown
}

# pinned_bats_version — the version scripts/gate.sh pins (the one source of that number).
pinned_bats_version() {
  sed -n 's/^PINNED_BATS_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/gate.sh"
}

# bats_answers_version <stub file> [version] — make a stub bats answer `--version` the way
# the real one does ("Bats X.Y.Z"), whatever else it does, so the gate's version pin passes
# (default: the pinned version) or fails (a different one) in a test (R16.qa.F14).
bats_answers_version() {
  local f="$1" v="${2:-$(pinned_bats_version)}" t
  t="$(mktemp)"
  { head -n 1 "$f"
    printf '[ "${1:-}" = "--version" ] && { echo "Bats %s"; exit 0; }\n' "$v"
    tail -n +2 "$f"; } > "$t"
  cat "$t" > "$f"
  rm -f "$t"
}

# GATE_ENV: extra VAR=value pairs a test wants the gate to see (the gate runs under env -i).
GATE_ENV=()
run_gate() { ( cd "$G" && env -i HOME="$G" PATH="$G/stubbin" ${GATE_ENV[@]+"${GATE_ENV[@]}"} bash scripts/gate.sh "$@" ); }

@test "missing shellcheck, venv and baseline are skipped LOUDLY, not failed" {
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate: PASS (skipped:"* ]] || false
  [[ "$output" == *"shellcheck"* ]] || false
  [[ "$output" == *"catalog"* ]] || false
  [[ "$output" == *"compose"* ]] || false
  # plugin-marketplace checks: both land in the skipped list, not silently passed
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"plugins"* ]] || false
  [[ "$last" == *"plugins-validate"* ]] || false
}

@test "a missing bats submodule is a FAIL with a hint, not a silent pass" {
  rm "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"git submodule update --init"* ]] || false
  [[ "$output" == *"gate: FAIL"* ]] || false
}

# R16.qa.F14: the bats submodule pointer can move; the gate asserts the version it was written for.
@test "a bats of the wrong version fails the gate, naming bats and both versions" {
  bats_answers_version "$G/tests/lib/bats-core/bin/bats" 0.0.0
  run run_gate
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
  [[ "$output" == *"0.0.0"* ]] || false
  [[ "$output" == *"$(pinned_bats_version)"* ]] || false
}

@test "a bats that prints no version fails the gate" {
  run run_gate
  [ "$status" -eq 0 ]    # the setup stub answers --version
  printf '#!/usr/bin/env bash\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
}

@test "a bats that prints the bare version without the 'Bats ' prefix fails the gate (NF-055 VF4)" {
  # `${v#Bats }` is a no-op on a bare number, so a bare "1.13.0" used to pass the pin.
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo "%s"; exit 0; }\necho "1..0"\nexit 0\n' \
    "$(pinned_bats_version)" > "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
}

@test "the pinned bats version is the one the real submodule carries" {
  [ -f "$REPO_ROOT/tests/lib/bats-core/package.json" ] || skip "bats-core submodule not initialised"
  [ -n "$(pinned_bats_version)" ]
  grep -q "\"version\": \"$(pinned_bats_version)\"" "$REPO_ROOT/tests/lib/bats-core/package.json"
}

@test "a bats run that leaves files in its TMPDIR fails the gate and names them" {
  # The stub bats leaks one file the way a test that forgot its rm -rf would.
  printf '#!/usr/bin/env bash\n: > "$TMPDIR/leaked-by-a-test"\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaked-by-a-test"* ]] || false
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
}

@test "a bats run that cleans up after itself leaves no TMPDIR behind" {
  # The stub records the dir it was given; the gate must remove it afterwards.
  printf '#!/usr/bin/env bash\necho "$TMPDIR" > "%s/bats-tmpdir"\necho "1..0"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 0 ]
  seen="$(cat "$BATS_TEST_TMPDIR/bats-tmpdir")"
  [ -n "$seen" ]
  [ ! -e "$seen" ]
}

@test "the gate makes the venv-gated tests mandatory (GRID_REQUIRE_VENV=1)" {
  # The stub records what bats would see; without the variable 215 tests skip and the gate stays green.
  printf '#!/usr/bin/env bash\necho "${GRID_REQUIRE_VENV-unset}" > "%s/bats-require-venv"\necho "1..0"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/bats-require-venv")" = "1" ]
}

# --- --pre-commit: the FAST, staged-files-only mode ------------------------------------------------
# The full gate is merge-time (CI, plain `bash scripts/gate.sh`); the hook only checks what is staged.

# stub_bats_logging — a bats stub that appends the targets it was asked to run to $G/bats.calls.
stub_bats_logging() {
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/bats.calls"\necho "1..0"\nexit 0\n' "$G" > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
}

# stub_shellcheck_logging <exit> — shellcheck stub: logs its args and the content of each file it got.
stub_shellcheck_logging() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/shellcheck.args"\nfor f in "$@"; do [ -f "$f" ] && cat "$f" >> "%s/shellcheck.seen"; done\nexit %s\n' "$G" "$G" "$1" > "$G/stubbin/shellcheck"
  chmod +x "$G/stubbin/shellcheck"
}

@test "--pre-commit with nothing staged: fast note, no full-gate checks, bats not run" {
  stub_bats_logging
  run run_gate --pre-commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-commit: fast check; the full gate runs in CI and via 'bash scripts/gate.sh'"* ]] || false
  [[ "$output" != *"==> catalog"* ]] || false
  [[ "$output" != *"==> compose"* ]] || false
  [[ "$output" != *"==> audit"* ]] || false
  [ ! -e "$G/bats.calls" ]
  [[ "$output" == *"gate: PASS"* ]] || false
}

@test "--pre-commit lints only staged shell files, with the full gate's flags" {
  stub_shellcheck_logging 0
  echo 'echo staged' > "$G/scripts/new.sh"; echo 'echo other' > "$G/scripts/other.sh"
  ( cd "$G" && git add scripts/new.sh )
  run run_gate --pre-commit
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx -e '-S' "$G/shellcheck.args"
  grep -qx 'warning' "$G/shellcheck.args"
  grep -qx 'scripts/new.sh' "$G/shellcheck.args"
  ! grep -q 'other.sh' "$G/shellcheck.args"
}

@test "--pre-commit: a shellcheck failure on a staged file fails the gate and names shellcheck" {
  stub_shellcheck_logging 1
  echo 'echo x' > "$G/scripts/bad.sh"
  ( cd "$G" && git add scripts/bad.sh )
  run run_gate --pre-commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — shellcheck"* ]] || false
}

@test "--pre-commit lints the STAGED blob, not the working-tree edit" {
  stub_shellcheck_logging 0
  echo 'echo staged-version' > "$G/scripts/p.sh"
  ( cd "$G" && git add scripts/p.sh )
  echo 'echo unstaged-version' >> "$G/scripts/p.sh"
  run run_gate --pre-commit
  [ "$status" -eq 0 ]
  grep -q 'staged-version' "$G/shellcheck.seen"
  ! grep -q 'unstaged-version' "$G/shellcheck.seen"
}

@test "--pre-commit: no abort on unstaged edits to files that are not staged .bats" {
  echo x >> "$G/scripts/catalog.sh"
  run run_gate --pre-commit
  [ "$status" -eq 0 ]
  [[ "$output" != *"ABORT"* ]] || false
}

@test "--pre-commit runs bats for staged tests/*.bats files only, never the whole suite" {
  stub_bats_logging
  mkdir -p "$G/tests"
  printf '@test "a" { true; }\n' > "$G/tests/test_a.bats"
  echo '# mentions scripts/gate.sh' > "$G/tests/test_c.bats"
  ( cd "$G" && git add tests/test_c.bats && git commit -q -m "c" )
  echo '# edit, unstaged' >> "$G/tests/test_c.bats"
  ( cd "$G" && git add tests/test_a.bats )
  run run_gate --pre-commit
  echo "$output"
  [ "$status" -eq 0 ]
  # exactly one bats run, with exactly the one staged file (the --version probe is not logged as a run
  # because the stub answers it before logging)
  [ "$(cat "$G/bats.calls")" = "tests/test_a.bats" ]
}

@test "--pre-commit aborts when a staged .bats file also has unstaged changes" {
  stub_bats_logging
  mkdir -p "$G/tests"
  printf '@test "a" { true; }\n' > "$G/tests/test_a.bats"
  ( cd "$G" && git add tests/test_a.bats )
  echo '# unstaged' >> "$G/tests/test_a.bats"
  run run_gate --pre-commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT"* ]] || false
  [ ! -e "$G/bats.calls" ]
}

@test "--pre-commit syntax-checks staged python only" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'x = (\n' > "$G/broken_unstaged.py"
  printf 'x = 1\n' > "$G/ok.py"
  ( cd "$G" && git add ok.py )
  run run_gate --pre-commit
  [ "$status" -eq 0 ]
  ( cd "$G" && git add broken_unstaged.py )
  run run_gate --pre-commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken_unstaged.py"* ]] || false
  [[ "$output" == *"gate: FAIL — pysyntax"* ]] || false
}

@test "a plain gate run is unchanged: all checks run and there is no fast-mode note" {
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> shellcheck"* ]] || false
  [[ "$output" == *"==> pysyntax"* ]] || false
  [[ "$output" == *"==> catalog"* ]] || false
  [[ "$output" == *"==> bats"* ]] || false
  [[ "$output" != *"pre-commit: fast check"* ]] || false
}

@test "the first run installs the hook path in the repo it runs in" {
  run run_gate
  [ "$(cd "$G" && git config --get core.hooksPath)" = ".githooks" ]
}

@test "a failing check is named in the summary and the rest still run" {
  printf '#!/usr/bin/env bash\necho BOOM\nexit 1\n' > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
  [[ "$output" == *"==> catalog"* ]] || false      # earlier/other checks still ran
}

@test "with no python3 and no scripts/budget.py the budget check is skipped LOUDLY, not failed" {
  # The copied gate has no scripts/budget.py and the stub PATH has no python3.
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or scripts/budget.py absent"* ]] || false
  # the final summary line lists budget among the skipped checks
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"budget"* ]] || false
}

@test "with no scripts/build-personas.sh the personas check is skipped LOUDLY, not failed" {
  # The copied gate has no scripts/build-personas.sh (and no venv) in the fake grid.
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"build-personas.sh or agent-factory/.venv absent"* ]] || false
  # the final summary line lists personas among the skipped checks
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"personas"* ]] || false
}

@test "G3: with scripts/check-personal.sh absent the personal check is skipped LOUDLY, not failed" {
  rm "$G/scripts/check-personal.sh"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"check-personal.sh absent"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"personal"* ]] || false
}

# Uses the REAL scanner and patterns in the fake grid. HOME is $G, so no private
# denylist exists: the scan runs generic-only and the gate records the skip.
@test "personal check passes generic-only and lists personal-denylist as skipped; a home path makes it FAIL" {
  cp "$REPO_ROOT/scripts/check-personal.sh" "$G/scripts/check-personal.sh"
  cp "$REPO_ROOT/scripts/personal-patterns.txt" "$REPO_ROOT/scripts/personal-allow-paths.txt" "$G/scripts/"
  ( cd "$G" && git add -A && git commit -q -m scan )
  run run_gate
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"personal-denylist"* ]] || false

  # A real-looking home path in a tracked file must fail the gate.
  printf 'cd /home/%s/work\n' someone > "$G/notes.txt"
  ( cd "$G" && git add -A && git commit -q -m leak )
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — personal"* ]] || false
}

# --- lock check (manifest-lock-install#2) ------------------------------------------------
# `grid lock --check` exit codes: 0 fresh, 1 stale (real failure), 3 a locked source is
# not checked out here (skip loudly, never fail).

@test "G3: with no scripts/grid and no python3 the lock check is skipped LOUDLY, not failed" {
  # The throwaway repo has no scripts/grid and the stub PATH has no python3.
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or scripts/grid absent"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"lock"* ]] || false
}

@test "G3: python3 present but scripts/grid absent is still a loud skip of the lock check" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  run run_gate
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"lock"* ]] || false
}

@test "G3: scripts/grid present but python3 absent from PATH is a loud skip of the lock check" {
  printf 'import sys\nsys.exit(1)\n' > "$G/scripts/grid"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or scripts/grid absent"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"lock"* ]] || false
}

@test "lock check: exit 3 (a locked source is not checked out) is a loud skip, not a failure" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'import sys\nsys.exit(3)\n' > "$G/scripts/grid"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"a locked source is not checked out"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"lock"* ]] || false
}

@test "lock check: exit 1 (stale lock) FAILS the gate and names lock" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'import sys\nsys.exit(1)\n' > "$G/scripts/grid"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — "*"lock"* ]] || false
}

@test "lock check: exit 2 (an error) also FAILS the gate" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'import sys\nsys.exit(2)\n' > "$G/scripts/grid"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — "*"lock"* ]] || false
}

# --- audit check (vetting#5) -------------------------------------------------------------
# The check skips loudly when scripts/audit.sh or python3 is absent, and FAILS (named
# `audit`) when the tool is present and exits non-zero. The stub PATH has no python3 by
# default, so the failure case must symlink one in or it would skip instead of fail.

@test "with no scripts/audit.sh and no python3 the audit check is skipped LOUDLY, not failed" {
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/audit.sh absent - skipped"* ]] || false
  # the final summary line lists audit among the skipped checks
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"audit"* ]] || false
}

@test "audit check: a scripts/audit.sh that exits 1 FAILS the gate and names audit" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$G/scripts/audit.sh"
  chmod +x "$G/scripts/audit.sh"
  # Without python3 on the stub PATH the check would skip, not fail.
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — "*"audit"* ]] || false
}

# audit_stub: an audit.sh that, like the real one, refuses to pass unless --allow-partial is
# given when the wired set cannot be scanned, and says so in both cases.
audit_partial_stub() {
  cat > "$G/scripts/audit.sh" <<'STUB'
#!/usr/bin/env bash
echo "audit: wired set NOT scanned (uninitialised baseline submodules: ex)"
case " $* " in *" --allow-partial "*) exit 0 ;; esac
exit 2
STUB
  chmod +x "$G/scripts/audit.sh"
  ln -s "$(command -v python3)" "$G/stubbin/python3"
}

@test "audit check: locally an unscanned wired set passes with audit-wired listed as skipped" {
  audit_partial_stub
  run run_gate
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"audit-wired"* ]] || false
}

@test "audit check: with CI set an unscanned wired set FAILS the gate" {
  audit_partial_stub
  run bash -c 'cd "$1" && env -i HOME="$1" PATH="$1/stubbin" CI=true bash scripts/gate.sh' _ "$G"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — "*"audit"* ]] || false
}

@test "lock check: exit 0 passes and lock is not listed as skipped" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'import sys\nsys.exit(0)\n' > "$G/scripts/grid"
  run run_gate
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" != *"lock"* ]] || false
}

# --- plugins / plugins-validate checks (plugin-marketplace#2) ------------------------------
# `plugins` needs python3 + scripts/build-plugins.py + the agent-factory venv; any one
# absent is a loud skip. `plugins-validate` needs `claude` + .claude-plugin/marketplace.json.

@test "G3: venv present but scripts/build-plugins.py absent is a loud skip of the plugins check" {
  mkdir -p "$G/agent-factory/.venv/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/agent-factory/.venv/bin/python"
  chmod +x "$G/agent-factory/.venv/bin/python"
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/build-plugins.py absent"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"plugins"* ]] || false
}

# mk_plugin_tree: a marketplace file plus one plugin dir, so plugins-validate has work to do.
mk_plugin_tree() {
  mkdir -p "$G/.claude-plugin" "$G/plugins/x"
  printf '{}\n' > "$G/.claude-plugin/marketplace.json"
}

@test "plugins-validate: a claude that exits 1 FAILS the gate and names plugins-validate" {
  mk_plugin_tree
  printf '#!/usr/bin/env bash\nexit 1\n' > "$G/stubbin/claude"
  chmod +x "$G/stubbin/claude"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugins-validate"* ]] || false
  [[ "$output" == *"gate: FAIL"* ]] || false
}

@test "plugins-validate: a claude that exits 0 passes and plugins-validate is not listed as skipped" {
  mk_plugin_tree
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/stubbin/claude"
  chmod +x "$G/stubbin/claude"
  run run_gate
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" != *"plugins-validate"* ]] || false
}

# --- rules check (rule-packs#1) ----------------------------------------------------------
# Like the other checks, `rules` skips loudly (and is recorded in the final line) when its
# tool is absent. Neither case puts python3 on the stub PATH, so even a PRESENT
# scripts/rules.py is skipped: the check needs both python3 and the script.

@test "G3: with no scripts/rules.py the rules check is skipped LOUDLY, not failed" {
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or scripts/rules.py absent"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"rules"* ]] || false
}

@test "G3: a placeholder scripts/rules.py but no python3 on PATH is still a loud skip of the rules check" {
  printf 'import sys\nsys.exit(1)\n' > "$G/scripts/rules.py"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or scripts/rules.py absent"* ]] || false
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == "gate: PASS (skipped:"*"rules"* ]] || false
}

# --- hooks/ in the lint file list (hook-profiles#1) -------------------------------------------
# The gate must hand the three hooks/ globs to shellcheck. A stub shellcheck records its
# arguments; the stub repo gets one file per glob so each expands to a real path.

@test "lint check: shellcheck is given the hooks/ run.sh, lib and scripts files" {
  mkdir -p "$G/hooks/lib" "$G/hooks/scripts"
  : > "$G/hooks/run.sh"; : > "$G/hooks/lib/common.sh"; : > "$G/hooks/scripts/x.sh"
  # the files the existing globs need (so only the hooks/ paths are under test)
  mkdir -p "$G/scripts/lib" "$G/scripts/usage" "$G/contexts" "$G/automation-factory/patterns/p/hooks"
  : > "$G/scripts/lib/a.sh"; : > "$G/scripts/usage/b.sh"; : > "$G/contexts/c.sh"
  : > "$G/automation-factory/patterns/p/d.sh"; : > "$G/automation-factory/patterns/p/hooks/e.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/shellcheck.args"\nexit 0\n' "$G" > "$G/stubbin/shellcheck"
  chmod +x "$G/stubbin/shellcheck"
  run run_gate
  [ "$status" -eq 0 ]
  grep -qx 'hooks/run.sh' "$G/shellcheck.args"
  grep -qx 'hooks/lib/common.sh' "$G/shellcheck.args"
  grep -qx 'hooks/scripts/x.sh' "$G/shellcheck.args"
}

# change charter-files: the pre-commit shim every cut project receives is linted by the gate.
@test "lint check: shellcheck is given the _common .githooks pre-commit shim" {
  mkdir -p "$G/project-factory/templates/_common/.githooks"
  : > "$G/project-factory/templates/_common/.githooks/pre-commit"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/shellcheck.args"\nexit 0\n' "$G" > "$G/stubbin/shellcheck"
  chmod +x "$G/stubbin/shellcheck"
  run run_gate
  [ "$status" -eq 0 ]
  grep -qx 'project-factory/templates/_common/.githooks/pre-commit' "$G/shellcheck.args"
}

# --- the live issue-loop pattern is linted ----------------------------------------------------
# The runner, its setup script and the hook scripts of automation-factory/patterns/ are live
# assets: the gate hands every one of them to shellcheck.
@test "lint check: shellcheck is given the issue-loop pattern's runner, setup and hook scripts" {
  local p="$G/automation-factory/patterns/issue-loop"
  mkdir -p "$p/hooks"
  : > "$p/run-issue.sh"; : > "$p/setup.sh"
  : > "$p/hooks/guard-main-push.sh"; : > "$p/hooks/new-agent-worktree.sh"; : > "$p/hooks/post-commit-review.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/shellcheck.args"\nexit 0\n' "$G" > "$G/stubbin/shellcheck"
  chmod +x "$G/stubbin/shellcheck"
  run run_gate
  [ "$status" -eq 0 ]
  # wake.sh arrives with the waker stage (B2) and is added to this list there
  grep -qx 'automation-factory/patterns/issue-loop/run-issue.sh' "$G/shellcheck.args"
  grep -qx 'automation-factory/patterns/issue-loop/setup.sh' "$G/shellcheck.args"
  grep -qx 'automation-factory/patterns/issue-loop/hooks/guard-main-push.sh' "$G/shellcheck.args"
  grep -qx 'automation-factory/patterns/issue-loop/hooks/new-agent-worktree.sh' "$G/shellcheck.args"
  grep -qx 'automation-factory/patterns/issue-loop/hooks/post-commit-review.sh' "$G/shellcheck.args"
}

# NF-027: a glob group with no match (a stub grid, a fork that dropped a dir) must add nothing.
# Without nullglob the literal pattern reaches shellcheck, which reports it as a missing file.
@test "lint check: a glob group with no matching file is not handed to shellcheck as a literal pattern" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/shellcheck.args"\nexit 0\n' "$G" > "$G/stubbin/shellcheck"
  chmod +x "$G/stubbin/shellcheck"
  run run_gate
  [ "$status" -eq 0 ]
  # the real file is still linted, so the list is not simply empty
  grep -qx 'scripts/gate.sh' "$G/shellcheck.args"
  # last, so the negation is the test's final (and deciding) command
  ! grep -q '[*?[]' "$G/shellcheck.args"
}

# --- strict mode (WP-045, D65) ---------------------------------------------------------------
# A skip that is not on the allowlist must fail CI. The gate runs under env -i, so a test hands
# the allowlist in through GATE_ENV.

# skipped_list — the skipped names from the last line of a PASSING gate run's output
skipped_list() {
  printf '%s\n' "$output" | tail -n 1 | sed -e 's/^gate: PASS (skipped: //' -e 's/)$//'
}

@test "strict: an unexpected skip fails the gate and names it" {
  run run_gate --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL (unexpected skip:"* ]] || false
  [[ "$output" == *"shellcheck"* ]] || false
}

@test "strict: the same skips pass when they are on GRID_GATE_EXPECT_SKIPPED" {
  run run_gate
  [ "$status" -eq 0 ]
  local all; all="$(skipped_list)"
  [ -n "$all" ]
  GATE_ENV=(GRID_GATE_EXPECT_SKIPPED="$all")
  run run_gate --strict
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate: PASS (skipped: $all)"* ]] || false
  # drop one name from the allowlist: that skip alone is now unexpected
  GATE_ENV=(GRID_GATE_EXPECT_SKIPPED="${all#shellcheck }")
  run run_gate --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected skip: shellcheck"* ]] || false
}

# NF-027: the allowlist is matched as WHOLE names. A substring match would let an allowed
# `plugins-validate` hide an unexpected `plugins` skip (and `compose-core` hide `compose`).
@test "strict: the allowlist matches whole names (an allowed plugins-validate does not cover plugins)" {
  run run_gate
  [ "$status" -eq 0 ]
  local all; all="$(skipped_list)"
  # precondition: both names are skipped here, and one is a prefix of the other
  [[ " $all " == *" plugins "* ]] || false
  [[ " $all " == *" plugins-validate "* ]] || false
  local allow=" $all "
  allow="${allow/ plugins / }"
  GATE_ENV=(GRID_GATE_EXPECT_SKIPPED="$allow")
  run run_gate --strict
  echo "$output"
  [ "$status" -eq 1 ]
  # exactly `plugins` is unexpected; plugins-validate stays covered by its own entry
  [[ "$output" == *"gate: FAIL (unexpected skip: plugins)"* ]] || false
}

@test "strict: --strict and --pre-commit combine in either order (fast scope, strict skips)" {
  # a staged shell file with no shellcheck on PATH is a skip, which --strict makes a failure
  echo 'echo x' > "$G/scripts/s.sh"
  ( cd "$G" && git add scripts/s.sh )
  run run_gate --pre-commit --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected skip: shellcheck"* ]] || false
  run run_gate --strict --pre-commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected skip: shellcheck"* ]] || false
}

@test "strict: a missing audit script is an unexpected skip, a present one is not" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/scripts/audit.sh"
  run run_gate
  [ "$status" -eq 0 ]
  GATE_ENV=(GRID_GATE_EXPECT_SKIPPED="$(skipped_list)")
  run run_gate --strict
  [ "$status" -eq 0 ]
  # remove the script: the same allowlist no longer covers the (new) skip
  rm "$G/scripts/audit.sh"
  run run_gate --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected skip:"*"audit"* ]] || false
}

@test "an unknown argument is a usage error, not a silent full run" {
  run run_gate --strcit
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]] || false
}

# --- every check body is pinned (WP-045): a failing check fails the gate and is named ----------
# arm_checks gives every check a stub that RUNS and passes; a test then flips ONE stub to fail
# through $G/rc/<name>. This kills mutants that swallow a failure (`|| true`, `; true`, `return 0`)
# or replace a check body with `true`.
arm_checks() {
  mkdir -p "$G/rc" "$G/agent-factory/.venv/bin"
  # python3: the exit code of `python3 <script> ...` comes from rc/<script basename>
  # (budget.py also records the baseline it was pinned to, WP-046)
  {
    printf '#!/usr/bin/env bash\nn="${1##*/}"\n'
    printf 'if [ "$n" = budget.py ]; then echo "${GRID_BASELINE-unset}" > "%s/budget.baseline"; fi\n' "$G"
    printf '[ -f "%s/rc/$n" ] && exit "$(cat "%s/rc/$n")"\nexit 0\n' "$G" "$G"
  } > "$G/stubbin/python3"
  # the venv python: records its args, fails --lint-roles / --check through rc/lint-roles, rc/compose-check
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/venv.log"\ncase "$*" in\n  *--lint-roles*) [ -f "%s/rc/lint-roles" ] && exit "$(cat "%s/rc/lint-roles")" ;;\n  *--check*) [ -f "%s/rc/compose-check" ] && exit "$(cat "%s/rc/compose-check")" ;;\nesac\nexit 0\n' "$G" "$G" "$G" "$G" "$G" > "$G/agent-factory/.venv/bin/python"
  : > "$G/scripts/budget.py"; : > "$G/scripts/rules.py"; : > "$G/scripts/build-plugins.py"; : > "$G/scripts/grid"
  : > "$G/scripts/map.py"
  printf '#!/usr/bin/env bash\n[ -f "%s/rc/personas" ] && exit "$(cat "%s/rc/personas")"\nexit 0\n' "$G" "$G" > "$G/scripts/build-personas.sh"
  # catalog.sh and sources.sh record the baseline pin / args they were run with (WP-046)
  {
    printf '#!/usr/bin/env bash\necho "${GRID_BASELINE-unset} $*" > "%s/catalog.args"\n' "$G"
    printf '[ -f "%s/rc/catalog" ] && exit "$(cat "%s/rc/catalog")"\nexit 0\n' "$G" "$G"
  } > "$G/scripts/catalog.sh"
  {
    printf '#!/usr/bin/env bash\necho "${GRID_BASELINE-unset} $*" > "%s/sources.args"\n' "$G"
    printf '[ -f "%s/rc/sources" ] && exit "$(cat "%s/rc/sources")"\nexit 0\n' "$G" "$G"
  } > "$G/scripts/sources.sh"
  printf '#!/usr/bin/env bash\n[ -f "%s/rc/audit" ] && exit "$(cat "%s/rc/audit")"\nexit 0\n' "$G" "$G" > "$G/scripts/audit.sh"
  # the tracked example baseline: the gate pins catalog, sources and budget to it; there is NO personal one
  : > "$G/baseline-submodules.example.txt"
  chmod +x "$G/stubbin/python3" "$G/agent-factory/.venv/bin/python" "$G/scripts/build-personas.sh" "$G/scripts/catalog.sh" "$G/scripts/audit.sh" "$G/scripts/sources.sh"
}

@test "armed checks: with every check stubbed to pass the gate passes" {
  arm_checks
  run run_gate
  echo "$output"
  [ "$status" -eq 0 ]
  # every armed check really ran: none of them is on the skipped list (word match, so
  # `compose` does not hide behind `compose-core`)
  local list n
  list=" $(skipped_list) "
  for n in lock budget rules map catalog sources plugins personas audit compose; do
    case "$list" in *" $n "*) echo "check '$n' was skipped, not run: $list" >&3; return 1 ;; esac
  done
}

@test "a failing budget check fails the gate and names budget; exit 3 only skips the baseline half" {
  arm_checks
  echo 1 > "$G/rc/budget.py"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — budget"* ]] || false
  echo 3 > "$G/rc/budget.py"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget-baseline"* ]] || false
}

@test "a failing rules lint fails the gate and names rules" {
  arm_checks
  echo 1 > "$G/rc/rules.py"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — rules"* ]] || false
}

# --- map check (change charter-files): a stale MAP.md fails the commit gate ------------------
@test "a stale MAP.md (map.py --check exits 1) fails the gate and names map" {
  arm_checks
  echo 1 > "$G/rc/map.py"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — map"* ]] || false
}

@test "map.py --check exiting 2 (an error) also fails the gate" {
  arm_checks
  echo 2 > "$G/rc/map.py"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — map"* ]] || false
}

@test "map check: python3 hidden from PATH is a loud, recorded skip of map" {
  # the stub PATH has no python3 unless a test links one in; scripts/map.py is present
  : > "$G/scripts/map.py"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or scripts/map.py absent"* ]] || false
  [[ " $(skipped_list) " == *" map "* ]] || false
}

@test "map check: scripts/map.py absent is a loud, recorded skip of map" {
  arm_checks
  rm "$G/scripts/map.py"
  run run_gate
  [ "$status" -eq 0 ]
  [[ " $(skipped_list) " == *" map "* ]] || false
}

@test "a failing catalog check fails the gate and names catalog" {
  arm_checks
  echo 1 > "$G/rc/catalog"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — catalog"* ]] || false
}

@test "catalog, sources and budget run on a machine with NO personal baseline, pinned to the example baseline (WP-046)" {
  arm_checks
  [ ! -e "$G/baseline-submodules.txt" ]
  run run_gate
  [ "$status" -eq 0 ]
  # the stubs recorded what the gate gave them: the pin is the tracked example file
  [[ "$(cat "$G/catalog.args")" == *"/baseline-submodules.example.txt --check" ]] || false
  [[ "$(cat "$G/sources.args")" == *"/baseline-submodules.example.txt --check-drift" ]] || false
  [[ "$(cat "$G/budget.baseline")" == *"/baseline-submodules.example.txt" ]] || false
}

@test "a personal baseline on the machine does not change what the gate checks (WP-046)" {
  arm_checks
  printf 'something-else\n' > "$G/baseline-submodules.txt"
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$(cat "$G/catalog.args")" == *"/baseline-submodules.example.txt --check" ]] || false
}

@test "a failing sources drift check fails the gate and names sources" {
  arm_checks
  echo 1 > "$G/rc/sources"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — sources"* ]] || false
}

@test "a missing sources.sh is a loud, recorded skip, not a pass" {
  arm_checks
  rm "$G/scripts/sources.sh"
  run run_gate
  [ "$status" -eq 0 ]
  [[ " $(skipped_list) " == *" sources "* ]] || false
}

@test "uninitialised submodules still skip catalog loudly" {
  arm_checks
  # a gitlink with no checkout shows as '-' in `git submodule status`
  ( cd "$G" && git config -f .gitmodules submodule.ghost.path repos/ghost \
      && git config -f .gitmodules submodule.ghost.url https://example.invalid/ghost.git \
      && git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,repos/ghost )
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"uninitialised submodules"* ]] || false
  [[ " $(skipped_list) " == *" catalog "* ]] || false
}

@test "a failing plugin bundle check fails the gate and names plugins" {
  arm_checks
  echo 1 > "$G/rc/build-plugins.py"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — plugins"* ]] || false
}

@test "a failing personas check fails the gate and names personas" {
  arm_checks
  echo 1 > "$G/rc/personas"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — personas"* ]] || false
}

@test "a failing compose lint-roles fails the gate and names compose" {
  arm_checks
  echo 1 > "$G/rc/lint-roles"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — compose"* ]] || false
}

@test "a failing compose --check on a composed project fails the gate and names compose" {
  arm_checks
  mkdir -p "$G/agent-factory/projects/core"
  echo 1 > "$G/rc/compose-check"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — compose"* ]] || false
  grep -q 'agent-factory/examples/core.yaml --target claude-code --check' "$G/venv.log"
}

@test "an uncomposed project is a recorded skip compose-<name>, learning-desk included" {
  arm_checks
  mkdir -p "$G/agent-factory/projects/core"
  run run_gate
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$last" == *"compose-grid"* ]] || false
  [[ "$last" == *"compose-finance-desk"* ]] || false
  [[ "$last" == *"compose-learning-desk"* ]] || false
  # the composed project is checked, not listed as skipped
  [[ "$last" != *"compose-core"* ]] || false
}

# --- the real pre-commit hook (WP-045) ----------------------------------------------------------
# The shim is the one place GRID_SKIP_HOOK lives. Copy the REAL hook into the stub repo (the
# default stub is `exit 0`) and commit it, so the tracked tree is clean.
install_real_hook() {
  cp "$REPO_ROOT/.githooks/pre-commit" "$G/.githooks/pre-commit"
  ( cd "$G" && git add -A && git commit -q -m "real hook" )
}
run_hook() { ( cd "$G" && env -i HOME="$G" PATH="$G/stubbin" ${GATE_ENV[@]+"${GATE_ENV[@]}"} bash .githooks/pre-commit ); }

@test "the real pre-commit hook: GRID_SKIP_HOOK=1 skips the gate entirely" {
  install_real_hook
  GATE_ENV=(GRID_SKIP_HOOK=1)
  run run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-commit: skipped"* ]] || false
  [[ "$output" != *"==>"* ]] || false
}

@test "the real pre-commit hook runs gate.sh --pre-commit (fast mode), not the full gate" {
  install_real_hook
  run run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-commit: fast check"* ]] || false
  [[ "$output" != *"==> catalog"* ]] || false
  [[ "$output" == *"no staged tests/*.bats files"* ]] || false
}

# --- lint coverage (WP-045) -----------------------------------------------------------------------
@test "lint check: shellcheck also gets the factory scripts, lamp templates and test helpers; python is not handed to it" {
  mkdir -p "$G/agent-factory/scripts" "$G/project-factory/scripts" "$G/project-factory/templates/lamp-agents-base/scripts" "$G/tests/helpers"
  : > "$G/agent-factory/scripts/deploy_openclaw.sh"; : > "$G/project-factory/scripts/cut-project.sh"
  : > "$G/project-factory/templates/lamp-agents-base/scripts/m.sh"; : > "$G/tests/helpers/h.bash"
  : > "$G/scripts/grid"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/shellcheck.args"\nexit 0\n' "$G" > "$G/stubbin/shellcheck"
  chmod +x "$G/stubbin/shellcheck"
  run run_gate
  [ "$status" -eq 0 ]
  grep -qx 'agent-factory/scripts/deploy_openclaw.sh' "$G/shellcheck.args"
  grep -qx 'project-factory/scripts/cut-project.sh' "$G/shellcheck.args"
  grep -qx 'project-factory/templates/lamp-agents-base/scripts/m.sh' "$G/shellcheck.args"
  grep -qx 'tests/helpers/h.bash' "$G/shellcheck.args"
  ! grep -qx 'scripts/grid' "$G/shellcheck.args"
}

@test "pysyntax: tracked *.py and scripts/grid are syntax-checked; a broken one fails the gate and names pysyntax" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'x = 1\n' > "$G/ok.py"
  # scripts/grid is the python CLI with no .py extension; exit 3 = "a locked source is not checked out" (lock skipped)
  printf 'import sys\nsys.exit(3)\n' > "$G/scripts/grid"
  ( cd "$G" && git add ok.py )
  run run_gate
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> pysyntax"* ]] || false
  printf 'def (:\n' > "$G/broken.py"
  ( cd "$G" && git add broken.py )
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL"*"pysyntax"* ]] || false
  [[ "$output" == *"broken.py"* ]] || false
  rm "$G/broken.py"; ( cd "$G" && git rm -q --cached broken.py )
  printf 'def (:\n' > "$G/scripts/grid"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/grid"* ]] || false
}

# NF-027: scripts/grid has no .py extension, so only the pysyntax stage's own special case
# covers it. The lock stage also runs it (and would fail on a syntax error too), so the
# assertion is on the pysyntax stage's own output, not just the gate's overall failure.
# The broken file is a fixture copy under $G; the real scripts/grid is never touched.
@test "pysyntax: a syntax error in scripts/grid alone fails the pysyntax stage itself" {
  ln -s "$(command -v python3)" "$G/stubbin/python3"
  printf 'def (:\n' > "$G/scripts/grid"
  run run_gate
  echo "$output"
  [ "$status" -eq 1 ]
  local stage
  stage="$(printf '%s\n' "$output" | sed -n '/^==> pysyntax/,/^==> catalog/p')"
  [[ "$stage" == *"scripts/grid"* ]] || false
  [[ "$stage" == *"FAIL"* ]] || false
}

# --- fresh worktree: initialise the bats submodule once (WP-045) -------------------------------------
# A stub git logs every call; on `submodule update --init tests/lib/bats-core` it restores the bats
# stub (as a real update would), unless a no-restore marker file says the update does nothing.
stub_git_with_bats_restore() {
  local real chm; real="$(command -v git)"; chm="$(command -v chmod)"
  cp "$G/tests/lib/bats-core/bin/bats" "$G/bats.restore"
  rm "$G/tests/lib/bats-core/bin/bats" "$G/stubbin/git"
  # nested ifs, not `[ A ] && [ B ]`: the repo-health lint rejects that shape anywhere in a test file
  {
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/git.log"\n' "$G"
    printf 'if [ "$1 $2 $3 $4" = "submodule update --init tests/lib/bats-core" ]; then\n'
    printf '  if [ ! -f "%s/no-restore" ]; then\n' "$G"
    printf '    cat "%s/bats.restore" > "%s/tests/lib/bats-core/bin/bats"; %s +x "%s/tests/lib/bats-core/bin/bats"\n' "$G" "$G" "$chm" "$G"
    printf '  fi\nfi\nexec %s "$@"\n' "$real"
  } > "$G/stubbin/git"
  chmod +x "$G/stubbin/git"
}

@test "a missing bats is initialised once with git submodule update --init tests/lib/bats-core, then runs" {
  stub_git_with_bats_restore
  run run_gate
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^submodule update --init tests/lib/bats-core$' "$G/git.log")" -eq 1 ]
}

@test "a missing bats that the one init attempt does not restore still FAILS with the hint" {
  stub_git_with_bats_restore
  : > "$G/no-restore"
  run run_gate
  [ "$status" -eq 1 ]
  [ "$(grep -c '^submodule update --init tests/lib/bats-core$' "$G/git.log")" -eq 1 ]
  [[ "$output" == *"git submodule update --init"* ]] || false
  [[ "$output" == *"gate: FAIL"*"bats"* ]] || false
}

# --- leak diagnostics must not leak secrets (NF-005) ----------------------------------------------------
# The block that explains a leaked TMPDIR entry runs on CI, whose log is public. It may print names,
# sizes and process names; it must never print file CONTENTS or process ARGUMENTS (either can hold
# a token).
@test "leak diagnostics name the leaked entry and running processes but print no file contents or process args" {
  for t in ls find head cut mkdir; do ln -s "$(command -v $t)" "$G/stubbin/$t" 2>/dev/null || true; done
  # a ps stub: one process whose full command line carries a secret; the bare name does not
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *args*) echo "  PID     ELAPSED ARGS"; echo "   42       00:01 sleep --token=SECRET-ARG" ;;\n  *) echo "  PID     ELAPSED COMMAND"; echo "   42       00:01 sleep" ;;\nesac\n' > "$G/stubbin/ps"
  chmod +x "$G/stubbin/ps"
  # a test that leaks a file whose contents are a secret, and a directory holding one
  printf '#!/usr/bin/env bash\nprintf "SECRET-CONTENT\\n" > "$TMPDIR/leaked-file"\nmkdir -p "$TMPDIR/leaked-dir"\nprintf "SECRET-INNER\\n" > "$TMPDIR/leaked-dir/inner"\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  echo "$output"
  [ "$status" -eq 1 ]
  # the diagnostic block ran and says what leaked and who is running
  [[ "$output" == *"tests leaked temp files"* ]] || false
  [[ "$output" == *"leaked-file"* ]] || false
  [[ "$output" == *"leaked-dir"* ]] || false
  [[ "$output" == *"processes still running"* ]] || false
  [[ "$output" == *"sleep"* ]] || false
  # ... and printed neither contents nor arguments
  [[ "$output" != *"SECRET-CONTENT"* ]] || false
  [[ "$output" != *"SECRET-INNER"* ]] || false
  [[ "$output" != *"SECRET-ARG"* ]] || false
}

# --- bats shards (CI matrix) ---------------------------------------------------------------------
# tests/shards.txt maps every bats file to a CI shard. A file in no shard would silently never run
# in CI, so the real list is held to ls tests/test_*.bats exactly.
@test "shards: the shard files are exactly tests/test_*.bats, none missing, none in two shards" {
  local listed expected
  listed="$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/tests/shards.txt" | awk '{print $2}' | LC_ALL=C sort)"
  expected="$(cd "$REPO_ROOT/tests" && ls test_*.bats | LC_ALL=C sort)"
  # a vacuous pass (both empty) must not count
  [ -n "$expected" ]
  [ "$listed" = "$expected" ]
  # every line is "<shard> <file>" with nothing else on it
  [ -z "$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/tests/shards.txt" | awk 'NF != 2')" ]
}

@test "shards: the workflow matrix lists exactly the shard names in tests/shards.txt" {
  local wf="$REPO_ROOT/.github/workflows/tests.yml" in_file in_matrix
  in_file="$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/tests/shards.txt" | awk '{print $1}' | LC_ALL=C sort -u | tr '\n' ' ')"
  in_matrix="$(sed -n 's/^[[:space:]]*shard:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' "$wf" | tr -d ' ' | tr ',' '\n' | LC_ALL=C sort -u | tr '\n' ' ')"
  [ -n "$in_file" ]
  [ "$in_file" = "$in_matrix" ]
}

@test "shards: the aggregate job is still named gate, needs every other job and fails on anything but success" {
  local wf="$REPO_ROOT/.github/workflows/tests.yml"
  grep -qE '^  gate:[[:space:]]*$' "$wf"
  grep -qE '^    needs:[[:space:]]*\[checks, bats\]' "$wf"
  # always(): without it a failed/cancelled/skipped dependency skips gate, which reads as green
  grep -qE '^    if:.*always\(\)' "$wf"
  grep -qF '"checks=success bats=success"' "$wf"
  # a red shard must not cancel its siblings
  grep -qE '^[[:space:]]*fail-fast:[[:space:]]*false' "$wf"
}

# stub_shards — a two-shard list and a bats stub that records the files it is handed.
stub_shards() {
  printf '# comment\ns1 test_a.bats\ns1 test_b.bats\ns2 test_c.bats\n' > "$G/tests/shards.txt"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/bats.args"\necho "1..0"\nexit 0\n' "$G" > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
}

@test "--shard runs only that shard's files under the bats pin and skips every other check" {
  stub_shards
  run run_gate --shard s1
  [ "$status" -eq 0 ]
  [ "$(cat "$G/bats.args")" = "$(printf 'tests/test_a.bats\ntests/test_b.bats')" ]
  [[ "$output" == *"==> bats-s1"* ]] || false
  [[ "$output" != *"==> shellcheck"* ]] || false
  [[ "$output" != *"==> catalog"* ]] || false
}

@test "--shard keeps the per-shard leak check" {
  stub_shards
  printf '#!/usr/bin/env bash\nmkdir -p "$TMPDIR/leaked-dir"\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  bats_answers_version "$G/tests/lib/bats-core/bin/bats"
  run run_gate --shard s2
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests leaked temp files"* ]] || false
}

@test "--shard with an unknown name FAILS instead of running nothing" {
  stub_shards
  run run_gate --shard nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no bats files listed for shard 'nope'"* ]] || false
  [ ! -e "$G/bats.args" ]
}

@test "--shard is exclusive: a missing name, --no-bats and --pre-commit are usage errors" {
  stub_shards
  run run_gate --shard
  [ "$status" -eq 2 ]
  run run_gate --shard s1 --no-bats
  [ "$status" -eq 2 ]
  run run_gate --shard s1 --pre-commit
  [ "$status" -eq 2 ]
}

@test "--no-bats runs the other checks and never calls bats" {
  stub_shards
  run run_gate --no-bats
  [ "$status" -eq 0 ]
  [ ! -e "$G/bats.args" ]
  [[ "$output" == *"--no-bats"* ]] || false
  [[ "$output" == *"==> catalog"* ]] || false
}
