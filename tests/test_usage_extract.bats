#!/usr/bin/env bats
# scripts/usage/extract.py + adapters — the usage extractor and its adapter seam.
# Every test runs on a temp copy of the synthetic transcript tree in
# tests/fixtures/usage/claude-projects and writes only under a temp dir; nothing
# reads the real ~/.claude or the real private repo.
#
# Fixture facts (hand-counted, UTC days D1=2026-10-07 D2=2026-10-08 D3=2026-10-09):
#   D1  skills handoff:1   agents grid-qa-engineer:1   slash model:1
#       tokens sonnet msgs1 in5 out50 cr1000 cw200
#   D2  skills tdd:2 handoff:1   agents grid-qa-engineer:1 (default):1   slash handoff:1
#       hooks PreToolUse:Bash:1 Stop:2
#       tokens sonnet msgs3 in4 out710 cr130 cw55 ; haiku msgs1 in3 out300 cr0 cw0
#       (the haiku message streams across UTC midnight and lands on D2)
#   D3  skills tdd:1   hooks PreToolUse:Bash:1   tokens sonnet msgs1 in4 out40
#   listing D2 skills 12 chars 480
# proj-beta/sess-a-resumed.jsonl is a byte copy of proj-alpha/sess-a.jsonl, so any
# count that doubles would show up here.

bats_require_minimum_version 1.5.0
load helpers/setup

FIX="$BATS_TEST_DIRNAME/fixtures/usage"
EXTRACT="$BATS_TEST_DIRNAME/../scripts/usage/extract.py"

setup() {
  common_setup
  T="$(mktemp -d)"
  cp -R "$FIX/claude-projects" "$T/projects"
  mkdir -p "$T/skills/tdd" "$T/skills/handoff" "$T/agents" "$T/private"
  touch "$T/agents/grid-qa-engineer.md" "$T/agents/.hidden.md"
  # Hand-written settings with the recommended retention so tests are quiet
  # unless they are about the retention warning.
  printf '{"cleanupPeriodDays": 60}\n' > "$T/settings.json"
  export CLAUDE_PROJECTS_DIR="$T/projects"
  export SKILLS_DIR="$T/skills" AGENTS_DIR="$T/agents"
  export CLAUDE_SETTINGS="$T/settings.json"
  export GRID_PRIVATE_DIR="$T/private"
  export GRID_HOST=testhost
  OUT="$T/out"
  F="$OUT/testhost.json"
}

teardown() {
  # A test may leave an unreadable dir behind; make everything removable first.
  chmod -R u+rwx "$T" 2>/dev/null || true
  rm -rf "$T"
  common_teardown
}

# extract [args...] — run the extractor with the temp --out.
extract() { run --separate-stderr python3 "$EXTRACT" --out "$OUT" "$@"; }

# jget <expr> — evaluate a Python expression on the output file as `d`.
jget() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))' "$F" "$1"
}

# day <D> <kind> — the claude-code per-day bucket as sorted JSON.
day() { jget "d['harnesses']['claude-code']['days']['$1'].get('$2')"; }

@test "(a) per-day counts match the hand-counted fixture" {
  extract
  [ "$status" -eq 0 ]
  [ "$(day 2026-10-07 skills)" = '{"handoff": 1}' ]
  [ "$(day 2026-10-07 agents)" = '{"grid-qa-engineer": 1}' ]
  [ "$(day 2026-10-07 slash)" = '{"model": 1}' ]
  [ "$(day 2026-10-08 skills)" = '{"handoff": 1, "tdd": 2}' ]
  [ "$(day 2026-10-08 agents)" = '{"(default)": 1, "grid-qa-engineer": 1}' ]
  [ "$(day 2026-10-08 slash)" = '{"handoff": 1}' ]
  [ "$(day 2026-10-09 skills)" = '{"tdd": 1}' ]
  [ "$(jget "d['harnesses']['claude-code']['listing']")" = '{"2026-10-08": {"chars": 480, "skills": 12}}' ]
  [ "$(jget "d['schema'], d['host']")" = '[1, "testhost"]' ]
}

@test "(b) a path-like slash is absent" {
  extract
  [ "$status" -eq 0 ]
  run ! grep -F 'tmp' "$F"
}

@test "(c) no prompt text and no session ids reach the output" {
  extract
  [ "$status" -eq 0 ]
  run ! grep -F 'SECRET-PROMPT-TEXT' "$F"
  run ! grep -F 'sessionId' "$F"
}

@test "(d) a second run leaves the file byte-identical and its mtime unchanged" {
  extract
  [ "$status" -eq 0 ]
  cp "$F" "$T/first.json"
  touch -t 200001010000 "$F"        # an old mtime makes any rewrite visible
  before="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$F")"
  extract
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
  cmp "$F" "$T/first.json"
  after="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$F")"
  [ "$before" = "$after" ]
}

@test "(e)(j) deleting the oldest day's transcript keeps that day's counts and tokens" {
  extract
  [ "$status" -eq 0 ]
  cp "$F" "$T/first.json"
  rm "$CLAUDE_PROJECTS_DIR/proj-beta/sess-b.jsonl"   # the only file holding D1
  extract
  [ "$status" -eq 0 ]
  cmp "$F" "$T/first.json"
  [ "$(day 2026-10-07 skills)" = '{"handoff": 1}' ]
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-07']['tokens']['claude-sonnet-5-5']['out']")" = '50' ]
}

@test "(f) --registry swaps in a fake adapter; counts land under harnesses.fake" {
  PYTHONPATH="$FIX" extract --registry fake_adapter:REGISTRY
  [ "$status" -eq 0 ]
  [ "$(jget "sorted(d['harnesses'])")" = '["fake"]' ]
  [ "$(jget "d['harnesses']['fake']['days']['2026-10-08']['skills']")" = '{"alpha": 2}' ]
  [ "$(jget "d['harnesses']['fake']['days']['2026-10-09']['agents']")" = '{"beta": 1}' ]
  [ "$(jget "d['harnesses']['fake']['listing']")" = '{"2026-10-09": {"chars": 100, "skills": 3}}' ]
  [ "$(jget "d['harnesses']['fake']['wired']")" = '{"agents": ["beta"], "skills": ["alpha"]}' ]
}

@test "(g) retention warning: missing setting and 30 warn, 60 does not" {
  rm "$CLAUDE_SETTINGS"
  extract
  [ "$status" -eq 0 ]
  [[ "$stderr" == *cleanupPeriodDays* ]]
  printf '{"cleanupPeriodDays": 30}\n' > "$CLAUDE_SETTINGS"
  extract
  [[ "$stderr" == *cleanupPeriodDays* ]]
  printf '{"cleanupPeriodDays": 60}\n' > "$CLAUDE_SETTINGS"
  extract
  [[ "$stderr" != *cleanupPeriodDays* ]]
}

@test "(h) a missing projects dir exits 0 with a 'no adapters available' line" {
  export CLAUDE_PROJECTS_DIR="$T/does-not-exist"
  extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"no adapters available"* ]]
  [ ! -e "$OUT" ]
}

@test "(i) tokens: chunks merge by max, copies add nothing, midnight lands on the earlier day" {
  extract
  [ "$status" -eq 0 ]
  # sonnet D2 = m-1 (2/680/100/50) + m-2 (1/20/10/5, "[1m]" suffix dropped) + m-6 subagent (1/10/20/0)
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-08']['tokens']['claude-sonnet-5-5']")" \
     = '{"cache_read": 130, "cache_write": 55, "in": 4, "msgs": 3, "out": 710}' ]
  # haiku m-4 streamed across UTC midnight: max over chunks, earliest day.
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-08']['tokens']['claude-haiku-4-5']")" \
     = '{"cache_read": 0, "cache_write": 0, "in": 3, "msgs": 1, "out": 300}' ]
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-09']['tokens']")" \
     = '{"claude-sonnet-5-5": {"cache_read": 0, "cache_write": 0, "in": 4, "msgs": 1, "out": 40}}' ]
  # <synthetic> (in/out 9) and the id-less / timestamp-less records (7, 99) are absent.
  run ! grep -F 'synthetic' "$F"
  # the copied file doubled nothing: tool calls and slashes equal the single-file counts
  [ "$(day 2026-10-08 skills)" = '{"handoff": 1, "tdd": 2}' ]
  [ "$(day 2026-10-08 slash)" = '{"handoff": 1}' ]
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-07']['tokens']['claude-sonnet-5-5']['msgs']")" = '1' ]
}

@test "(k) <command-name> mid-prose and a bare /tmp message are not slash commands" {
  extract
  [ "$status" -eq 0 ]
  # D2 slash has only the real /handoff; the prose "/model" and "/tmp" are absent
  [ "$(day 2026-10-08 slash)" = '{"handoff": 1}' ]
}

@test "(l) drift canary: valid JSON but no assistant records warns and still exits 0" {
  rm -rf "$CLAUDE_PROJECTS_DIR"
  mkdir -p "$CLAUDE_PROJECTS_DIR/p"
  printf '{"type":"other","timestamp":"2026-10-08T10:00:00Z"}\n{"type":"other"}\n' > "$CLAUDE_PROJECTS_DIR/p/x.jsonl"
  extract
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING: transcript format may have changed"* ]]
}

@test "(m) a corrupt existing host file makes the run exit 1 and stays untouched" {
  mkdir -p "$OUT"
  printf '{"schema": 1, <<<<<<< conflict' > "$F"
  cp "$F" "$T/corrupt.json"
  extract
  [ "$status" -eq 1 ]
  cmp "$F" "$T/corrupt.json"
  # an unknown schema is treated the same way
  printf '{"schema": 99}\n' > "$F"
  cp "$F" "$T/future.json"
  extract
  [ "$status" -eq 1 ]
  cmp "$F" "$T/future.json"
}

@test "(n) --host localhost and --out inside GRID_DIR are refused with exit 2" {
  extract --host localhost
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
  export GRID_DIR="$T/grid"
  mkdir -p "$GRID_DIR"
  run --separate-stderr python3 "$EXTRACT" --out "$GRID_DIR/usage"
  [ "$status" -eq 2 ]
  [ ! -e "$GRID_DIR/usage" ]
}

@test "(p) hooks count once per hookName per day; command and toolUseID never stored" {
  extract
  [ "$status" -eq 0 ]
  # h-1 (hook_success) + h-2 (hook_non_blocking_error) + h-4 (subagent file); the copy adds nothing
  [ "$(day 2026-10-08 hooks)" = '{"PreToolUse:Bash": 1, "Stop": 2}' ]
  [ "$(day 2026-10-09 hooks)" = '{"PreToolUse:Bash": 1}' ]
  run ! grep -F 'SECRET/hook-cmd.sh' "$F"
  run ! grep -F 'toolUseID' "$F"
}

@test "(o) a missing SKILLS_DIR keeps the previous wired.skills snapshot" {
  extract
  [ "$status" -eq 0 ]
  [ "$(jget "d['harnesses']['claude-code']['wired']")" = '{"agents": ["grid-qa-engineer"], "skills": ["handoff", "tdd"]}' ]
  rm -rf "$T/skills" "$T/agents/grid-qa-engineer.md"
  touch "$T/agents/other.md"
  export SKILLS_DIR="$T/skills"        # now missing
  extract
  [ "$status" -eq 0 ]
  # skills kept from the earlier snapshot; agents replaced by the new listing
  [ "$(jget "d['harnesses']['claude-code']['wired']")" = '{"agents": ["other"], "skills": ["handoff", "tdd"]}' ]
}

# --- write hygiene (WP-026) -----------------------------------------------------

# fake_repo — a throwaway repo layout holding a COPY of the extractor, so a test that
# must run it against a "repo" never reaches the real checkout (red runs included).
# Sets REPO_COPY and X (the copied extract.py). Bytecode from earlier runs is removed.
fake_repo() {
  REPO_COPY="$T/fakerepo"
  mkdir -p "$REPO_COPY/scripts"
  cp -R "$BATS_TEST_DIRNAME/../scripts/usage" "$REPO_COPY/scripts/usage"
  find "$REPO_COPY" -name __pycache__ -exec rm -rf {} +
  X="$REPO_COPY/scripts/usage/extract.py"
}

@test "a planted .<host>.json.tmp symlink to a victim file is not followed" {
  printf 'victim-original\n' > "$T/victim.txt"
  mkdir -p "$OUT"
  ln -s "$T/victim.txt" "$OUT/.testhost.json.tmp"
  extract
  [ "$status" -eq 0 ]
  [ "$(cat "$T/victim.txt")" = "victim-original" ]
  [ -f "$F" ] && [ ! -L "$F" ]
}

@test "8 parallel runs x 3 rounds all exit 0 and leave valid JSON" {
  local round i p pids
  for round in 1 2 3; do
    rm -rf "$OUT"
    pids=()
    for i in 1 2 3 4 5 6 7 8; do
      python3 "$EXTRACT" --out "$OUT" > "$T/par.$round.$i.log" 2>&1 &
      pids+=($!)
    done
    for p in "${pids[@]}"; do
      wait "$p" || { cat "$T"/par.*.log; false; }
    done
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$F"
  done
}

@test "a stale GRID_DIR does not defeat the --out-inside-the-repo guard" {
  fake_repo
  GRID_DIR=/nonexistent run --separate-stderr python3 "$X" --out "$REPO_COPY/usage"
  [ "$status" -eq 2 ]
  [ ! -e "$REPO_COPY/usage" ]
}

@test "--host . and --host .. and a bad --since-day exit 2 and write nothing" {
  extract --host .
  [ "$status" -eq 2 ]
  extract --host ..
  [ "$status" -eq 2 ]
  extract --host .hidden
  [ "$status" -eq 2 ]
  extract --since-day garbage
  [ "$status" -eq 2 ]
  extract --since-day $'2026-10-01\n'
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}

@test "a run leaves no __pycache__ under scripts/usage" {
  fake_repo
  # Bytecode writing is ON for this run (the default); the extractor must turn it off itself.
  env -u PYTHONDONTWRITEBYTECODE python3 "$X" --out "$OUT"
  [ -z "$(find "$REPO_COPY" -name __pycache__)" ]
}

@test "an --out that is a symlink exits 2 and writes nothing through it" {
  mkdir -p "$T/elsewhere"
  ln -s "$T/elsewhere" "$T/linkout"
  run --separate-stderr python3 "$EXTRACT" --out "$T/linkout"
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$T/elsewhere")" ]
}

@test "a host file that is itself a symlink exits 2 and the link target is untouched" {
  printf 'victim-original\n' > "$T/victim.txt"
  mkdir -p "$OUT"
  ln -s "$T/victim.txt" "$F"
  extract
  [ "$status" -eq 2 ]
  [ "$(cat "$T/victim.txt")" = "victim-original" ]
}

@test "extra keys, string leaves and badly named counts in an existing host file are dropped" {
  mkdir -p "$OUT"
  cat > "$F" <<'JSON'
{"schema": 1, "host": "testhost", "updated": "2026-10-01", "evil": "top-level extra",
 "harnesses": {"claude-code": {"extra": 1,
   "days": {"2026-10-08": {"skills": {"tdd": 99, "handoff": "a string", "bad name": 999999},
                           "unknown_bucket": {"x": 1}},
            "not-a-day": {"skills": {"tdd": 5}}},
   "listing": {"2026-10-08": {"skills": 12, "chars": 480, "note": "x"}},
   "wired": {"skills": ["tdd", "bad name"], "agents": [], "other": ["x"]}}}}
JSON
  extract
  [ "$status" -eq 0 ]
  [ "$(jget "sorted(d)")" = '["harnesses", "host", "schema", "updated"]' ]
  [ "$(jget "sorted(d['harnesses']['claude-code'])")" = '["days", "listing", "wired"]' ]
  [[ "$stderr" == *"dropped"* ]]
  run ! grep -E 'a string|999999|not-a-day|bad name|unknown_bucket|top-level extra' "$F"
  # A well-formed value from the old file survives (max-merge keeps the larger).
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-08']['skills']['tdd']")" = '99' ]
}

# --- adapter robustness (WP-058) ------------------------------------------------

# rec_skill <timestamp> <id> — one assistant record that calls the tdd skill on <timestamp>.
rec_skill() {
  printf '{"type":"assistant","uuid":"x-%s","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tx-%s","name":"Skill","input":{"skill":"tdd"}}]}}\n' "$2" "$1" "$2"
}

# day_keys — the sorted day keys of the claude-code block as JSON.
day_keys() { jget "sorted(d['harnesses']['claude-code']['days'])"; }

# in_time <seconds> <command...> — run under a perl alarm (portable `timeout`); 142 = killed.
in_time() { local s="$1"; shift; run --separate-stderr perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

@test "a future-dated record is dropped with a stderr warning and the day is not stored" {
  mkdir -p "$T/projects/p-x"
  rec_skill 2099-01-01T00:00:00Z f1 > "$T/projects/p-x/future.jsonl"
  extract
  [ "$status" -eq 0 ]
  [ "$(day_keys)" = '["2026-10-07", "2026-10-08", "2026-10-09"]' ]
  [[ "$stderr" == *"WARNING"*"timestamp"* ]]
  [[ "$output" == *"bad_day=1"* ]]
}

@test "impossible and non-ASCII-digit days are dropped: 2026-02-29, 9999-99-99, Arabic-Indic digits" {
  mkdir -p "$T/projects/p-x"
  {
    rec_skill 2026-02-29T10:00:00Z f1
    rec_skill 9999-99-99T10:00:00Z f2
    rec_skill $'\xd9\xa2\xd9\xa0\xd9\xa2\xd9\xa6-\xd9\xa1\xd9\xa0-\xd9\xa0\xd9\xa8T10:00:00Z' f3
  } > "$T/projects/p-x/odd.jsonl"
  extract
  [ "$status" -eq 0 ]
  [ "$(day_keys)" = '["2026-10-07", "2026-10-08", "2026-10-09"]' ]
  [[ "$output" == *"bad_day=3"* ]]
}

@test "an offset timestamp is bucketed by its UTC day: 2026-10-11T23:30:00-05:00 is 2026-10-12" {
  mkdir -p "$T/projects/p-x"
  rec_skill 2026-10-11T23:30:00-05:00 o1 > "$T/projects/p-x/offset.jsonl"
  extract
  [ "$status" -eq 0 ]
  [ "$(jget "d['harnesses']['claude-code']['days']['2026-10-12']['skills']")" = '{"tdd": 1}' ]
  [ "$(jget "'2026-10-11' in d['harnesses']['claude-code']['days']")" = 'false' ]
}

@test "CLAUDE_CONFIG_DIR is honoured when HOME has no .claude (projects, skills, agents, settings)" {
  CFG="$T/cfg"
  mkdir -p "$CFG/skills/tdd" "$CFG/agents" "$T/emptyhome"
  cp -R "$FIX/claude-projects" "$CFG/projects"
  touch "$CFG/agents/cfg-agent.md"
  printf '{"cleanupPeriodDays": 60}\n' > "$CFG/settings.json"
  unset CLAUDE_PROJECTS_DIR SKILLS_DIR AGENTS_DIR CLAUDE_SETTINGS
  HOME="$T/emptyhome" CLAUDE_CONFIG_DIR="$CFG" extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"events="[1-9]* ]]
  [ "$(jget "d['harnesses']['claude-code']['wired']")" = '{"agents": ["cfg-agent"], "skills": ["tdd"]}' ]
  [[ "$stderr" != *cleanupPeriodDays* ]]
}

@test "a symlinked project dir and a symlinked transcript are not followed, and are counted" {
  mkdir -p "$T/outside"
  rec_skill 2026-10-08T10:00:00Z l1 | sed 's/"tdd"/"linked-skill-dir"/' > "$T/outside/dir.jsonl"
  rec_skill 2026-10-08T10:00:00Z l2 | sed 's/"tdd"/"linked-skill-file"/' > "$T/outside/file.jsonl"
  ln -s "$T/outside" "$T/projects/linkdir"
  ln -s "$T/outside/file.jsonl" "$T/projects/proj-alpha/link.jsonl"
  extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped_links=2"* ]]
  [[ "$stderr" == *"skipped"* ]]
  # (last: `run !` replaces $output and $stderr)
  run ! grep -F 'linked-skill' "$F"
}

@test "a FIFO named *.jsonl is skipped instead of blocking forever" {
  mkfifo "$T/projects/proj-alpha/fifo.jsonl"
  in_time 10 python3 "$EXTRACT" --out "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$F" ]
}

@test "an unreadable project dir is counted in the warning; an unreadable projects root exits 1 untouched" {
  extract
  [ "$status" -eq 0 ]
  cp "$F" "$T/first.json"
  chmod 000 "$T/projects/proj-beta"
  # Root ignores modes; fail loudly instead of passing without testing anything.
  [ ! -r "$T/projects/proj-beta" ]
  extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"walk_errors=1"* ]]
  [[ "$stderr" == *"unreadable"* ]]
  chmod 755 "$T/projects/proj-beta"
  chmod 000 "$T/projects"
  [ ! -r "$T/projects" ]
  extract
  [ "$status" -eq 1 ]
  cmp "$F" "$T/first.json"
}

@test "100 KB of whitespace after <command-name> with no closing tag finishes quickly" {
  mkdir -p "$T/projects/p-x"
  python3 -c 'import json; print(json.dumps({"type":"user","uuid":"s1","timestamp":"2026-10-08T10:00:00Z","message":{"role":"user","content":"<command-name>" + " " * 100000}}))' > "$T/projects/p-x/ws.jsonl"
  in_time 5 python3 "$EXTRACT" --out "$OUT"
  [ "$status" -eq 0 ]
}

@test "a transcript line nested 12000 deep is counted as bad, the run still exits 0" {
  mkdir -p "$T/projects/p-x"
  python3 -c 'print("[" * 12000 + "]" * 12000)' > "$T/projects/p-x/deep.jsonl"
  extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"bad_lines=3"* ]]   # the fixture already holds 2 bad lines
}

@test "a line over the 8 MB cap is counted as bad and not parsed" {
  mkdir -p "$T/projects/p-x"
  python3 -c 'import sys; sys.stdout.write("{\"type\":\"x\",\"pad\":\"" + "a" * 9000000 + "\"}\n")' > "$T/projects/p-x/big.jsonl"
  extract
  [ "$status" -eq 0 ]
  [[ "$output" == *"bad_lines=3"* ]]   # the fixture already holds 2 bad lines
}

@test "skill, agent and model names ending in a newline are dropped; newline-named files are not wired" {
  mkdir -p "$T/projects/p-x"
  python3 - "$T/projects/p-x/evil.jsonl" <<'PY'
import json, sys
recs = [
  {"type": "assistant", "uuid": "e1", "timestamp": "2026-10-08T10:00:00Z", "message": {
     "id": "m-e1", "model": "evil-model\n", "usage": {"input_tokens": 1, "output_tokens": 1},
     "content": [{"type": "tool_use", "id": "te1", "name": "Skill", "input": {"skill": "evil-skill\n"}},
                 {"type": "tool_use", "id": "te2", "name": "Task", "input": {"subagent_type": "evil-agent\n"}}]}},
  {"type": "attachment", "uuid": "e3", "timestamp": "2026-10-08T10:00:01Z",
   "attachment": {"type": "hook_success", "hookName": "evil-hook\n"}},
]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in recs) + "\n")
PY
  touch "$T/agents/bad"$'\n'"agent.md"
  mkdir "$T/skills/bad"$'\n'"skill"
  extract
  [ "$status" -eq 0 ]
  run ! grep -F 'evil' "$F"
  [ "$(jget "d['harnesses']['claude-code']['wired']")" = '{"agents": ["grid-qa-engineer"], "skills": ["handoff", "tdd"]}' ]
}
