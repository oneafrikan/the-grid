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
  ( cd "$G" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init )
  # PATH with essentials but no shellcheck (tr/wc/xargs: needed by the real check-personal.sh)
  for t in git bash env dirname grep cat rm mktemp uname sed tr wc xargs; do
    ln -s "$(command -v $t)" "$G/stubbin/$t" 2>/dev/null || true
  done
}

teardown() {
  rm -rf "$G"
  common_teardown
}

run_gate() { ( cd "$G" && env -i HOME="$G" PATH="$G/stubbin" bash scripts/gate.sh "$@" ); }

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

@test "a bats run that leaves files in its TMPDIR fails the gate and names them" {
  # The stub bats leaks one file the way a test that forgot its rm -rf would.
  printf '#!/usr/bin/env bash\n: > "$TMPDIR/leaked-by-a-test"\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaked-by-a-test"* ]] || false
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
}

@test "a bats run that cleans up after itself leaves no TMPDIR behind" {
  # The stub records the dir it was given; the gate must remove it afterwards.
  printf '#!/usr/bin/env bash\necho "$TMPDIR" > "%s/bats-tmpdir"\necho "1..0"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 0 ]
  seen="$(cat "$BATS_TEST_TMPDIR/bats-tmpdir")"
  [ -n "$seen" ]
  [ ! -e "$seen" ]
}

@test "--pre-commit aborts on unstaged changes to tracked files" {
  echo x >> "$G/scripts/catalog.sh"
  run run_gate --pre-commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT"* ]] || false
}

@test "the first run installs the hook path in the repo it runs in" {
  run run_gate
  [ "$(cd "$G" && git config --get core.hooksPath)" = ".githooks" ]
}

@test "a failing check is named in the summary and the rest still run" {
  printf '#!/usr/bin/env bash\necho BOOM\nexit 1\n' > "$G/tests/lib/bats-core/bin/bats"
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
