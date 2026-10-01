#!/usr/bin/env bats
# Tests for agent-factory/run_evals.py (golden cases for roles). No test here ever calls
# a real model: real runs are exercised only against a stub `claude` (GRID_CLAUDE) and
# every result file lands in a temp dir. Needs the agent-factory venv; skipped without it.

load helpers/setup

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  [ -x "$PY" ] || skip "agent-factory venv not built"
  EVALS="$REPO_ROOT/agent-factory/run_evals.py"
  CASES=$(mktemp -d)      # a throwaway cases dir for the tests that write their own cases
  RESULTS=$(mktemp -d)
}

teardown() {
  rm -rf "$CASES" "$RESULTS"
  common_teardown
}

# One well-formed case for a real role, written into the temp cases dir.
write_case() {
  mkdir -p "$CASES/qa-engineer"
  cat > "$CASES/qa-engineer/demo.yaml" <<'YAML'
role: qa-engineer
finding: "#2"
expect_today: pass
prompt: "Say hello."
must_match:
  - '^VERDICT:\s*NOT-VERIFIED'
YAML
}

# A stand-in for the claude binary: prints a fixed JSON result, ignores its arguments.
write_stub() {
  STUB="$CASES/claude-stub"
  printf '#!/bin/sh\ncat >/dev/null\necho %s\n' "'{\"result\": \"$1\", \"total_cost_usd\": 0.01}'" > "$STUB"
  chmod +x "$STUB"
}

@test "every shipped case file is well formed" {
  run "$PY" "$EVALS" --validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 problem(s)"* ]]
}

@test "validate rejects an unknown role, a bad regex and a missing key" {
  mkdir -p "$CASES/nonesuch"
  printf 'role: nonesuch\nfinding: "#2"\nexpect_today: pass\nprompt: x\nmust_match: ["("]\n' > "$CASES/nonesuch/bad.yaml"
  mkdir -p "$CASES/qa-engineer"
  printf 'role: qa-engineer\nfinding: "#2"\n' > "$CASES/qa-engineer/short.yaml"
  run "$PY" "$EVALS" --validate --cases-dir "$CASES"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown role"* ]]
  [[ "$output" == *"bad regex"* ]]
  [[ "$output" == *"missing 'prompt'"* ]]
}

@test "dry-run prints the plan and worst-case spend and makes no model call" {
  write_case
  GRID_CLAUDE=/nonexistent run "$PY" "$EVALS" --dry-run --cases-dir "$CASES"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 case(s), 3 run(s); worst case"* ]]
}

@test "real runs refuse without GRID_EVALS=1 and without --yes" {
  write_case
  run "$PY" "$EVALS" --yes --cases-dir "$CASES" --results-dir "$RESULTS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"GRID_EVALS=1"* ]]
  GRID_EVALS=1 run "$PY" "$EVALS" --cases-dir "$CASES" --results-dir "$RESULTS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--yes"* ]]
  [ -z "$(ls "$RESULTS")" ]     # refusing wrote nothing
}

@test "a passing stub run reports 3/3 and writes a results file" {
  write_case
  write_stub "VERDICT: NOT-VERIFIED - nothing was run."
  GRID_EVALS=1 GRID_CLAUDE="$STUB" run "$PY" "$EVALS" --yes --cases-dir "$CASES" --results-dir "$RESULTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qa-engineer/demo: 3/3 pass"* ]]
  [ "$(cat "$RESULTS"/*.jsonl | wc -l | tr -d ' ')" -eq 3 ]
  grep -q '"passed": true' "$RESULTS"/*.jsonl
}

@test "a failing stub run reports 0/3" {
  write_case
  write_stub "VERDICT: PASS - looks fine."
  GRID_EVALS=1 GRID_CLAUDE="$STUB" run "$PY" "$EVALS" --yes --cases-dir "$CASES" --results-dir "$RESULTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qa-engineer/demo: 0/3 pass"* ]]
}

@test "an error reply (e.g. not logged in) is recorded as an error, never as a failed case" {
  write_case
  STUB="$CASES/claude-stub"
  printf '#!/bin/sh\ncat >/dev/null\necho %s\n' "'{\"is_error\": true, \"result\": \"Not logged in\"}'" > "$STUB"
  chmod +x "$STUB"
  GRID_EVALS=1 GRID_CLAUDE="$STUB" run "$PY" "$EVALS" --yes --cases-dir "$CASES" --results-dir "$RESULTS"
  [ "$status" -eq 0 ]
  grep -q '"error": "Not logged in"' "$RESULTS"/*.jsonl
  ! grep -q '"passed": true' "$RESULTS"/*.jsonl
}
