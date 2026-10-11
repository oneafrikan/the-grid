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
