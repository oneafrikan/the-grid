#!/usr/bin/env bats
# Tests for `run_evals.py --changed` (eval selection by touched roles). Each test runs against
# a throwaway git repo holding only evals/cases + evals/touchfiles.yaml, so no real checkout is
# diffed. A tripwire `claude` fails the test if any run reaches a model. Needs the agent-factory
# venv; skipped without it.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  EVALS="$REPO_ROOT/agent-factory/run_evals.py"
  unset GRID_EVALS
  TMP=$(mktemp -d)
  # Tripwire: any real model call touches the marker and fails; teardown turns that into a failure.
  printf '#!/bin/sh\ntouch "%s/claude.called"\nexit 99\n' "$TMP" > "$TMP/claude-tripwire"
  chmod +x "$TMP/claude-tripwire"
  export GRID_CLAUDE="$TMP/claude-tripwire"
  RESULTS="$TMP/results"
  mkdir -p "$RESULTS"
  R="$TMP/repo"
  mkdir -p "$R/evals" "$R/agent-factory/roles/qa-engineer" "$R/agent-factory/_core"
  cp -r "$REPO_ROOT/evals/cases" "$R/evals/cases"
  cp "$REPO_ROOT/evals/touchfiles.yaml" "$R/evals/touchfiles.yaml"
  git -C "$R" init -q
  for f in agent-factory/roles/qa-engineer/AGENTS.md agent-factory/_core/DECISION_BRIEF.md \
           agent-factory/_core/SOUL_base.md agent-factory/compose.py README.md; do
    mkdir -p "$(dirname "$R/$f")"
    echo base > "$R/$f"
  done
  commit "initial"
}

teardown() {
  local called=0
  [ -e "$TMP/claude.called" ] && called=1
  rm -rf "$TMP"
  common_teardown
  [ "$called" -eq 0 ] || { echo "a real model call was attempted" >&2; return 1; }
}

commit() {
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m "$1"
}

# Append a line to a file in the temp repo and commit it as the one change under test.
touch_commit() {
  echo "change" >> "$R/$1"
  commit "change $1"
}

# Run --changed HEAD~1 --dry-run against the temp repo (extra args pass through).
changed() {
  run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" --changed HEAD~1 --dry-run "$@"
}

@test "a role's own AGENTS.md selects that role" {
  touch_commit agent-factory/roles/qa-engineer/AGENTS.md
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"selected roles: qa-engineer"* ]]
}

@test "a case file edit selects the role it belongs to" {
  # Existing case only: a new case file that is invalid would fail --validate first.
  echo "# x" >> "$R/evals/cases/tron/does-not-recommend-unwired.yaml"
  commit "edit tron case"
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"selected roles: tron"* ]]
}

@test "the decision brief selects orchestrators and not specialists" {
  touch_commit agent-factory/_core/DECISION_BRIEF.md
  changed
  line=$(printf '%s\n' "$output" | grep 'selected roles:')
  [[ "$line" == *"ceo-orchestrator"* ]]
  [[ "$line" == *"tech-lead"* ]]
  [[ "$line" != *"qa-engineer"* ]]
}

@test "a _core file outside the eval prompt selects nothing" {
  touch_commit agent-factory/_core/SOUL_base.md
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"no eval-relevant changes"* ]]
}

@test "an unrelated file selects nothing and exits 0" {
  touch_commit README.md
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"no eval-relevant changes"* ]]
}

@test "compose.py selects every role: the default cap refuses, --max-total 50 allows" {
  touch_commit agent-factory/compose.py
  changed
  [ "$status" -eq 2 ]
  [[ "$output" == *"--max-total"* ]]
  changed --max-total 50
  [ "$status" -eq 0 ]
}

@test "first matching touchfile rule wins" {
  # Rule 1 sends the brief to orchestrators; rule 2 would send it to all. qa-engineer must stay out.
  cat > "$R/evals/touchfiles.yaml" <<'YAML'
rules:
  - paths: ["agent-factory/_core/DECISION_BRIEF.md"]
    roles: orchestrators
  - paths: ["agent-factory/*"]
    roles: all
YAML
  commit "custom touchfiles"
  touch_commit agent-factory/_core/DECISION_BRIEF.md
  changed --max-total 50   # orchestrator cases alone can exceed the default cap
  [ "$status" -eq 0 ]
  [[ "$output" == *"selected roles:"* ]]
  [[ "$output" != *"qa-engineer"* ]]
}

@test "a bad range exits 2 with E_RANGE" {
  run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" --changed no-such-ref..HEAD --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"E_RANGE"* ]]
}

@test "without GRID_EVALS a real selected run is refused and writes nothing" {
  touch_commit agent-factory/roles/qa-engineer/AGENTS.md
  run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" --results-dir "$RESULTS" --changed HEAD~1
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$RESULTS")" ]
}

@test "with GRID_EVALS=1 and --yes a selected run writes a results file" {
  touch_commit agent-factory/roles/qa-engineer/AGENTS.md
  printf '#!/bin/sh\ncat >/dev/null\necho %s\n' "'{\"result\":\"ok\",\"total_cost_usd\":0}'" > "$TMP/claude-stub"
  chmod +x "$TMP/claude-stub"
  GRID_CLAUDE="$TMP/claude-stub" GRID_EVALS=1 run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" \
    --results-dir "$RESULTS" --changed HEAD~1 --role qa-engineer --yes
  [ "$status" -eq 0 ]
  [ -n "$(ls -A "$RESULTS")" ]
}

@test "validate rejects a touchfile rule naming an unknown role" {
  cat > "$R/evals/touchfiles.yaml" <<'YAML'
rules:
  - paths: ["README.md"]
    roles: [no-such-role]
YAML
  run "$PY" "$EVALS" --validate --repo "$R" --cases-dir "$R/evals/cases"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_CASE: touchfiles.yaml"* ]]
}


# --- WP-029: instincts prompt in eval selection (D47) ---------------------------------------

# instincts_pointer — the one line --changed prints when an instincts file changed.
POINTER="instincts eval selected: run GRID_EVALS=1 scripts/instincts.sh eval-prompt --yes"

@test "an edit to the analyser prompt, analyse.py, lib.py or an instincts case prints the instincts pointer" {
  for f in scripts/instincts/prompts/analyse-v1.md scripts/instincts/analyse.py scripts/instincts/lib.py \
           evals/instincts/c01-example.json; do
    mkdir -p "$R/$(dirname "$f")"; echo base > "$R/$f"; commit "add $f"
    touch_commit "$f"
    changed
    [ "$status" -eq 0 ] || { echo "$f: status $status"; return 1; }
    [[ "$output" == *"$POINTER"* ]] || { echo "$f: $output"; return 1; }
    [[ "$output" != *"no eval-relevant changes"* ]] || { echo "$f: said no changes"; return 1; }
  done
}

@test "the instincts pointer is printed next to a role selection too" {
  mkdir -p "$R/scripts/instincts"; echo base > "$R/scripts/instincts/analyse.py"; commit "add analyse"
  echo change >> "$R/scripts/instincts/analyse.py"
  echo change >> "$R/agent-factory/roles/qa-engineer/AGENTS.md"
  commit "both"
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"$POINTER"* ]]
  [[ "$output" == *"qa-engineer"* ]]
}

@test "an unrelated instincts-adjacent file (docs) does not print the pointer" {
  mkdir -p "$R/docs"; echo base > "$R/docs/instincts.md"; commit "add doc"
  touch_commit docs/instincts.md
  changed
  [[ "$output" != *"instincts eval selected"* ]]
}

@test "validate rejects a malformed eval: rule (unknown value, or mixed with roles)" {
  cat > "$R/evals/touchfiles.yaml" <<'YAML'
rules:
  - paths: ["README.md"]
    eval: nonsense
YAML
  run "$PY" "$EVALS" --validate --repo "$R" --cases-dir "$R/evals/cases"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_CASE: touchfiles.yaml"* ]]
  cat > "$R/evals/touchfiles.yaml" <<'YAML'
rules:
  - paths: ["README.md"]
    eval: instincts
    roles: all
YAML
  run "$PY" "$EVALS" --validate --repo "$R" --cases-dir "$R/evals/cases"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_CASE: touchfiles.yaml"* ]]
}

@test "--max-total applies to a real run without --changed too (worst case over the cap is refused)" {
  run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" --budget 1 --runs 20 --dry-run --max-total 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"--max-total"* ]]
  run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" --budget nan --dry-run
  [ "$status" -eq 2 ]
}


# --- WP-057: selection rules that mutation runs left unpinned ---------------------------------

@test "an explicit roles list in a touchfile rule selects exactly those roles" {
  cat > "$R/evals/touchfiles.yaml" <<'YAML'
rules:
  - paths: ["README.md"]
    roles: [qa-engineer]
YAML
  commit "explicit roles"
  touch_commit README.md
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"selected roles: qa-engineer"* ]]
}

@test "renaming a role's file selects the role (both the old and the new path count)" {
  git -C "$R" mv agent-factory/roles/qa-engineer/AGENTS.md agent-factory/roles/qa-engineer/OLD.md
  commit "rename"
  changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"selected roles: qa-engineer"* ]]
}

@test "a range that starts with a dash is rejected as E_RANGE and never reaches git as an option" {
  run "$PY" "$EVALS" --repo "$R" --cases-dir "$R/evals/cases" "--changed=--output=$TMP/leak" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"E_RANGE"* ]]
  [ ! -e "$TMP/leak" ]
}
