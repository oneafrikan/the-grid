#!/usr/bin/env bats
# Tests for scripts/run-record.sh (the per-run record). Every test logs to a temp file
# via GRID_RUN_LOG — never the real ~/.grid/runs.jsonl.

load helpers/setup

setup() {
  common_setup
  RR="$REPO_ROOT/scripts/run-record.sh"
  LOGDIR=$(mktemp -d)
  export GRID_RUN_LOG="$LOGDIR/sub/runs.jsonl"
}

teardown() {
  rm -rf "$LOGDIR"
  common_teardown
}

@test "appends one valid JSON line with the required fields" {
  run "$RR" --role gh-triage --action classify --outcome ok --target "acme/app#212" --operator gareth --cost-usd 0.02
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$GRID_RUN_LOG" | tr -d ' ')" -eq 1 ]
  python3 - <<PY
import json
r = json.loads(open("$GRID_RUN_LOG").read())
assert r["role"] == "gh-triage" and r["action"] == "classify" and r["outcome"] == "ok"
assert r["target"] == "acme/app#212" and r["operator"] == "gareth" and r["cost_usd"] == 0.02
assert r["ts"].endswith("Z") and r["host"]
PY
}

@test "two runs append two lines and keep the first" {
  "$RR" --role a --action x --outcome ok
  "$RR" --role b --action y --outcome error
  [ "$(wc -l < "$GRID_RUN_LOG" | tr -d ' ')" -eq 2 ]
  head -1 "$GRID_RUN_LOG" | grep -q '"role": "a"'
}

@test "quotes, newlines and unicode in the note keep the line valid JSON" {
  "$RR" --role a --action x --outcome stopped --note $'said "stop"\nthen — ünïcode'
  [ "$(wc -l < "$GRID_RUN_LOG" | tr -d ' ')" -eq 1 ]
  python3 -c "import json; json.loads(open('$GRID_RUN_LOG').read())"
}

@test "the log is private: file 0600" {
  "$RR" --role a --action x --outcome ok
  case "$(uname)" in Darwin) mode=$(stat -f %Lp "$GRID_RUN_LOG") ;; *) mode=$(stat -c %a "$GRID_RUN_LOG") ;; esac
  [ "$mode" = "600" ]
}

@test "rejects a bad outcome, a missing role and a non-numeric cost, and writes nothing" {
  run "$RR" --role a --action x --outcome great
  [ "$status" -eq 2 ]
  run "$RR" --action x --outcome ok
  [ "$status" -eq 2 ]
  run "$RR" --role a --action x --outcome ok --cost-usd abc
  [ "$status" -eq 2 ]
  [ ! -e "$GRID_RUN_LOG" ]
}
