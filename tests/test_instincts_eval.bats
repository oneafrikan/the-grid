#!/usr/bin/env bats
# Tests for scripts/instincts/evalcases.py and `instincts.sh eval-prompt`
# (openspec change `instincts`, group 8: labelled prompt cases and the live eval).
#
# Offline and free: no test here makes a real model call. The model is a stub
# `claude`, reached only through GRID_CLAUDE: the shared stub (tests/helpers/stubs.bash)
# for the refusal tests, and a small case-aware wrapper (below) for the live-mode tests,
# which answers each case with that case's own canned reply. State, results and edited
# case copies live in temp dirs; the real ~/.grid is never touched.
# These are self-checks by the author; the paid run against a real model is a separate,
# human step (never from the gate).

load helpers/stubs

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SH="$REPO_ROOT/scripts/instincts.sh"
CASES="$REPO_ROOT/evals/instincts"

setup() {
  # A git hook (the commit gate) exports these; they must not leak into the fixtures.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GRID_INSTINCTS INSTINCTS_MODEL INSTINCTS_BUDGET_USD \
        INSTINCTS_TIMEOUT_S STUB_CLAUDE_SLEEP STUB_CLAUDE_EXIT STUB_CLAUDE_JSON GRID_EVALS
  export PYTHONDONTWRITEBYTECODE=1
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export GRID_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GRID_HOST="host-a"
  # The analyser hands `claude` an allowlisted environment: name what the stubs read.
  export INSTINCTS_PASS_ENV="STUB_DIR STUB_LOG STUB_CLAUDE_JSON STUB_CLAUDE_EXIT STUB_CLAUDE_SLEEP STUB_CLAUDE_STDIN CASE_STUB_LOG STUB_CASES_DIR REPO_ROOT STUB_BAD_CASES"
  RESULTS="$GRID_STATE_DIR/instincts/eval-results.jsonl"
  make_stubs
  # Tripwire: every call must reach a stub, never a real claude.
  case "$GRID_CLAUDE" in "$STUB_DIR"/*) ;; *) echo "GRID_CLAUDE is not the stub" >&2; return 1 ;; esac
}

teardown() { clean_stubs; }

# case_stub — replace GRID_CLAUDE with a wrapper that answers each case with its canned
# reply: canned.good, or canned.bad for the cases named in STUB_BAD_CASES (space separated).
# It recognises the case by comparing its stdin with that case's digest, built by the
# shipping builder. Every call is logged (one line) to $CASE_STUB_LOG.
case_stub() {
  export CASE_STUB_LOG="$BATS_TEST_TMPDIR/case-stub.log"; : > "$CASE_STUB_LOG"
  export STUB_CASES_DIR="${1:-$CASES}"
  cat > "$BATS_TEST_TMPDIR/case_stub.py" <<'PY'
import json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "scripts", "instincts"))
import evalcases
digest = sys.stdin.read()
cases, _ = evalcases.load_cases(evalcases.Path(os.environ["STUB_CASES_DIR"]))
for c in cases:
    if evalcases.build_case_digest(c)[0].text == digest:
        key = "bad" if c["name"] in os.environ.get("STUB_BAD_CASES", "").split() else "good"
        with open(os.environ["CASE_STUB_LOG"], "a") as fh:
            fh.write(c["name"] + " " + key + "\n")
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                          "result": json.dumps(c["canned"][key]), "total_cost_usd": 0.01}))
        sys.exit(0)
sys.exit(3)
PY
  printf '#!/bin/bash\nexec python3 -I %q\n' "$BATS_TEST_TMPDIR/case_stub.py" > "$BATS_TEST_TMPDIR/claude-case"
  chmod +x "$BATS_TEST_TMPDIR/claude-case"
  export REPO_ROOT
  GRID_CLAUDE="$BATS_TEST_TMPDIR/claude-case"
}

# --- --validate (the free half, also the gate) ----------------------------------

@test "eval-prompt --validate exits 0 on the shipped cases" {
  run "$SH" eval-prompt --validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"validated 17 case(s)"* ]]
  [[ "$output" == *"0 problem(s)"* ]]
  # seventeen files, c01 to c17
  [ "$(ls "$CASES"/c*.json | wc -l)" -eq 17 ]
}

@test "--validate makes no model call" {
  run "$SH" eval-prompt --validate
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$RESULTS" ]
}

@test "--validate fails when a canned.bad item is edited to a valid one" {
  cp -r "$CASES" "$BATS_TEST_TMPDIR/cases"
  # c02: the bad item cites P1 (one session, dropped as thin-evidence); C1 spans three sessions.
  python3 - "$BATS_TEST_TMPDIR/cases/c02-quiet-week.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["canned"]["bad"][0]["evidence"] = ["C1"]
json.dump(c, open(p, "w"))
PY
  run "$SH" eval-prompt --validate --cases-dir "$BATS_TEST_TMPDIR/cases"
  [ "$status" -ne 0 ]
  [[ "$output" == *"c02-quiet-week"* ]]
  [[ "$output" == *"canned.bad must be dropped"* ]]
}

@test "--validate fails when canned.good does not survive the validator" {
  cp -r "$CASES" "$BATS_TEST_TMPDIR/cases"
  python3 - "$BATS_TEST_TMPDIR/cases/c01-repeated-correction.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["canned"]["good"][0]["evidence"] = ["P9"]
json.dump(c, open(p, "w"))
PY
  run "$SH" eval-prompt --validate --cases-dir "$BATS_TEST_TMPDIR/cases"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canned.good must survive validation"* ]]
}

@test "--validate fails on a malformed case file" {
  cp -r "$CASES" "$BATS_TEST_TMPDIR/cases"
  rm "$BATS_TEST_TMPDIR/cases/c03-one-session-only.json"
  printf '{"name": "c03-one-session-only", "why": "x"}\n' > "$BATS_TEST_TMPDIR/cases/c03-one-session-only.json"
  run "$SH" eval-prompt --validate --cases-dir "$BATS_TEST_TMPDIR/cases"
  [ "$status" -ne 0 ]
  [[ "$output" == *"c03-one-session-only.json: missing 'obs'"* ]]
}

@test "the shipped prompt has its header keys, no placeholders and three example blocks" {
  # The same checks --validate runs, asserted directly so a failure names the file.
  f="$REPO_ROOT/scripts/instincts/prompts/analyse-v1.md"
  for k in prompt version supersedes inputs output_schema invariants model_cannot_see change; do
    grep -q "^$k:" "$f"
  done
  ! grep -q '{{' "$f" || false
  [ "$(grep -c '^<<<DIGEST$' "$f")" -eq 3 ]
}

# --- live mode: refusals --------------------------------------------------------

@test "live mode without GRID_EVALS=1 exits non-zero and calls no stub" {
  run "$SH" eval-prompt --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"GRID_EVALS=1"* ]]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$RESULTS" ]
}

@test "live mode without --yes exits non-zero and calls no stub" {
  GRID_EVALS=1 run "$SH" eval-prompt
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$RESULTS" ]
}

@test "the plan and worst-case spend are printed before anything is refused" {
  run "$SH" eval-prompt --runs 2 --budget 0.04
  [[ "$output" == *"plan: 17 case(s) x 2 run(s) x \$0.04 cap = worst case \$1.36"* ]]
}

@test "an unknown --case is a usage error with no call" {
  GRID_EVALS=1 run "$SH" eval-prompt --yes --case c99-nope
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ]
}

# --- live mode: against a stub --------------------------------------------------

@test "live mode with every case answered by canned.good: all pass, one results line per run" {
  case_stub
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan: 17 case(s) x 2 run(s)"* ]]
  [[ "$output" != *"FAIL"* ]]
  [[ "$output" != *"FLIPPING"* ]]
  [ "$(grep -c ': 2/2 pass' <<<"$output")" -eq 17 ]
  [ "$(wc -l < "$RESULTS")" -eq 34 ]
  [ "$(wc -l < "$CASE_STUB_LOG")" -eq 34 ]
  # every line carries the full reply and the funnel counts, and all of them passed
  python3 - "$RESULTS" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert all(r["pass"] is True and r["error"] is None for r in rows), rows
assert all(isinstance(r["reply"], str) and r["ret"] is not None and r["valid"] is not None for r in rows)
assert all(r["pv"].startswith("1:") for r in rows)
assert len({r["case"] for r in rows}) == 17
PY
}

@test "--case runs only that case" {
  case_stub
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 1 --case c05-confirm-existing
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$RESULTS")" -eq 1 ]
  [ "$(cat "$CASE_STUB_LOG")" = "c05-confirm-existing good" ]
}

@test "a hostile reply to c08 fails that case, shown with ret and valid; the other cases still run" {
  case_stub
  STUB_BAD_CASES="c08-injection-repeated"
  export STUB_BAD_CASES
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"c08-injection-repeated: 0/1 pass"* ]]
  # the validator dropped the curl item (valid=0) but the model still returned it (ret=1)
  [[ "$output" == *"c08-injection-repeated run 1: FAIL ret=1 valid=0"* ]]
  [[ "$output" == *"fetch-and-run-script"* ]]          # the failing reply, verbatim
  [[ "$output" == *"c01-repeated-correction: 1/1 pass"* ]]
  [[ "$output" == *"c12-secret-shaped: 1/1 pass"* ]]
  [ "$(wc -l < "$RESULTS")" -eq 17 ]
}

@test "a case that passes only some runs is marked FLIPPING" {
  case_stub
  # Flip c02 between a good and a bad reply: the stub alternates on a counter file.
  cat > "$BATS_TEST_TMPDIR/claude-flip" <<EOF
#!/bin/bash
n=\$(cat "$BATS_TEST_TMPDIR/flip" 2>/dev/null || echo 0); echo \$((n + 1)) > "$BATS_TEST_TMPDIR/flip"
if [ \$((n % 2)) -eq 0 ]; then STUB_BAD_CASES= exec "$BATS_TEST_TMPDIR/claude-case"; fi
STUB_BAD_CASES=c02-quiet-week exec "$BATS_TEST_TMPDIR/claude-case"
EOF
  chmod +x "$BATS_TEST_TMPDIR/claude-flip"
  # A flip needs a reply that really fails `expect`. c02's shipped canned.bad is dropped by
  # the validator (so it would pass), so edit a copy to hold one that survives validation.
  cp -r "$CASES" "$BATS_TEST_TMPDIR/cases"
  python3 - "$BATS_TEST_TMPDIR/cases/c02-quiet-week.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
# a reply that survives validation but breaks `expect` (items: none): two sessions of evidence
c["canned"]["bad"] = [{"kind": "new", "id": "list-files-often", "trigger": "when exploring the repo",
                       "action": "run ls first", "domain": "workflow", "evidence": ["C1"]}]
c["canned"]["bad_reason"] = "ignored-by-this-test"
json.dump(c, open(p, "w"))
PY
  export STUB_CASES_DIR="$BATS_TEST_TMPDIR/cases"
  GRID_CLAUDE="$BATS_TEST_TMPDIR/claude-flip"
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 2 --case c02-quiet-week --cases-dir "$BATS_TEST_TMPDIR/cases"
  [ "$status" -ne 0 ]
  [[ "$output" == *"c02-quiet-week: 1/2 pass FLIPPING"* ]]
}

@test "an error such as Not logged in is reported as an error and never counted as a failed case" {
  GRID_CLAUDE="$STUB_DIR/claude"
  STUB_CLAUDE_JSON='{"type":"result","subtype":"success","is_error":true,"result":"Not logged in","total_cost_usd":0}'
  STUB_CLAUDE_EXIT=1
  export STUB_CLAUDE_JSON STUB_CLAUDE_EXIT
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 2 --case c01-repeated-correction
  [ "$status" -ne 0 ]
  [[ "$output" == *"c01-repeated-correction run 1: ERROR (exit)"* ]]
  [[ "$output" == *"c01-repeated-correction: ERROR, no verdict"* ]]
  [[ "$output" != *"0/2 pass"* ]]                # no pass rate was computed from errors
  [ "$(wc -l < "$RESULTS")" -eq 2 ]
  grep -q '"error": "exit"' "$RESULTS"
}

@test "the live call passes --budget and the prompt through the shipping command line" {
  GRID_CLAUDE="$STUB_DIR/claude"
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 1 --budget 0.02 --case c02-quiet-week
  [ "$status" -eq 0 ]
  grep -q -- '--max-budget-usd 0.02' "$STUB_LOG"
  grep -q -- '--tools ""' "$STUB_LOG"
  grep -q -- '--no-session-persistence' "$STUB_LOG"
}


# --- WP-029: bounds on spend ----------------------------------------------------------------

@test "--budget 100, nan, inf, a negative budget and --runs over the cap exit 2 with no call" {
  case_stub
  for a in "--budget 100" "--budget nan" "--budget inf" "--budget -1" "--budget 1.01" "--runs 50" "--runs 11" "--runs 0"; do
    # shellcheck disable=SC2086
    GRID_EVALS=1 run "$SH" eval-prompt --yes $a
    [ "$status" -eq 2 ] || { echo "accepted: $a"; return 1; }
  done
  [ ! -s "$CASE_STUB_LOG" ]
}

@test "a plan whose worst case is over --max-total is refused before any call; nan is rejected" {
  case_stub
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 10 --budget 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"--max-total"* ]]
  GRID_EVALS=1 run "$SH" eval-prompt --yes --max-total nan
  [ "$status" -eq 2 ]
  [ ! -s "$CASE_STUB_LOG" ]
  # raising the cap lets the same plan through
  GRID_EVALS=1 run "$SH" eval-prompt --yes --runs 1 --budget 0.05 --case c01-repeated-correction --max-total 100
  [ "$status" -ne 2 ]
}
