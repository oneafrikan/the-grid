#!/usr/bin/env bats
# scripts/usage/aggregate.py + scripts/usage/prune_report.py + scripts/prune-report.sh
#
# Every test builds a MOCK grid in a temp dir (GRID_DIR + a temp GRID_BASELINE +
# repos/) and reads a temp COPY of the synthetic per-host files in
# tests/fixtures/usage/hosts, so nothing touches the real repo, ~/.claude or the
# private usage repo.
#
# Fixture facts (hand-counted; hostA = 2026-09-01..2026-10-10, hostB = 2026-09-20..2026-10-10):
#   coverage            2026-09-01..2026-10-10 = 40 days across 2 hosts
#   a-used              5 uses, hostA only            -> used
#   a-rare              skills 1 (hostB) + slash 1 (hostA) = 2  -> rare
#   b-slash             slash 4 (hostB)               -> used
#   a-never, d-one/two/three, grid-help   0 uses      -> never
#   grid-qa-engineer    agents 3 (hostA) + 2 (hostB) = 5
#   core-idle, solo-bot wired, never used agents
#   hooks               Stop 50 (hostA 40 + hostB 10), PreToolUse:Bash 20 (hostA, Oct 1-10)
#   tokens Sep sonnet   msgs 71 in 41 out 344 cache_read 3110 cache_write 622
#   tokens Oct sonnet   msgs 30 in 20 out 140 cache_read 1100 cache_write 220
#   tokens Oct haiku    msgs 2  in 2  out 10  cache_read 0    cache_write 0
# Mock grid: baseline = `alpha` (whole repo: a-used a-rare a-never), `dead` (whole
# repo: d-one d-two d-three), `beta/b-slash`, `beta/grid-help` (keep-listed).
# Expected proposals: 1 A dead (79 chars), 2 B a-never (18), 3 B a-rare (17),
# 4 C core-idle (-project:core), 5 C solo-bot (no hint).

bats_require_minimum_version 1.5.0
load helpers/setup

FIX="$BATS_TEST_DIRNAME/fixtures/usage/hosts"
PRUNE="$BATS_TEST_DIRNAME/../scripts/prune-report.sh"
AGG="$BATS_TEST_DIRNAME/../scripts/usage"

setup() {
  common_setup
  # baseline_wired() runs the mock grid's OWN wire.sh, so give it a copy.
  mkdir -p "$MOCK_GRID/scripts" "$MOCK_GRID/docs" "$MOCK_GRID/agent-factory/examples"
  cp "$BATS_TEST_DIRNAME/../scripts/wire.sh" "$MOCK_GRID/scripts/wire.sh"
  cp -R "$BATS_TEST_DIRNAME/../scripts/lib" "$MOCK_GRID/scripts/lib"
  # The REAL keep list, so a typo in docs/prune-keep.txt would show up here.
  cp "$BATS_TEST_DIRNAME/../docs/prune-keep.txt" "$MOCK_GRID/docs/prune-keep.txt"
  for s in a-used a-rare a-never; do make_skill "$MOCK_GRID/repos/alpha/$s" "$s"; done
  for s in d-one d-two d-three;   do make_skill "$MOCK_GRID/repos/dead/$s" "$s"; done
  for s in b-slash grid-help b-unwired; do make_skill "$MOCK_GRID/repos/beta/$s" "$s"; done
  printf 'alpha\ndead\nbeta/b-slash\nbeta/grid-help\n' > "$OTHER_DIR/baseline.txt"
  # Agent -> project hints come from these (slug + project lines only).
  printf 'project: core\nslug: core\n' > "$MOCK_GRID/agent-factory/examples/core.yaml"
  printf 'project: grid\nslug: grid\n' > "$MOCK_GRID/agent-factory/examples/grid.yaml"
  USAGE="$(mktemp -d)"
  cp "$FIX"/*.json "$USAGE/"
  # A developer's own overrides must not leak in.
  unset GRID_HOST GRID_PRIVATE_DIR
  # Importing aggregate.py from the repo must not leave __pycache__ behind.
  export PYTHONDONTWRITEBYTECODE=1
  export GRID_DIR="$MOCK_GRID" GRID_BASELINE="$OTHER_DIR/baseline.txt"
}

teardown() {
  rm -rf "$USAGE"
  common_teardown
}

# prune [args...] — run the wrapper against the temp usage dir ($output = stdout).
prune() { run --separate-stderr bash "$PRUNE" --usage-dir "$USAGE" "$@"; }

# agg <python expr over `a`, the aggregate dict> — print it as sorted JSON.
agg() {
  python3 -c 'import sys, json
sys.path.insert(0, sys.argv[1]); import aggregate
a = aggregate.aggregate(sys.argv[2], int(sys.argv[4]))
print(json.dumps(eval(sys.argv[3]), sort_keys=True))' "$AGG" "$USAGE" "$1" "${2:-90}"
}

# jget <json> <python expr over d>
jget() { python3 -c 'import sys, json; d = json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2]), sort_keys=True))' "$1" "$2"; }

# tree_hash <dir> — content + layout hash of a directory tree.
tree_hash() { (cd "$1" && { find . | sort; find . -type f -print0 | sort -z | xargs -0 sha256sum; } | sha256sum); }

# --- (a) aggregate sums both hosts ---------------------------------------------

@test "(a) aggregate() sums both hosts, counts hosts, reports coverage" {
  [ "$(agg "a['claude-code']['hosts']")" = "2" ]
  [ "$(agg "[a['claude-code'][k] for k in ('first_day','last_day','coverage_days')]")" \
    = '["2026-09-01", "2026-10-10", 40]' ]
  [ "$(agg "a['claude-code']['skills']")" = '{"a-rare": 1, "a-used": 5}' ]
  [ "$(agg "a['claude-code']['slash']")" = '{"a-rare": 1, "b-slash": 4}' ]
  [ "$(agg "a['claude-code']['agents']")" = '{"grid-qa-engineer": 5}' ]
  [ "$(agg "a['claude-code']['wired']['agents']")" = '["core-idle", "grid-qa-engineer", "solo-bot"]' ]
  [ "$(agg "a['ignored']")" = "[]" ]
  # The window ends at the latest day (Oct 10): 8 days = Oct 3..10 keeps a-rare's
  # Oct 3 call and 3 of a-used's 5 (Oct 3-5); 5 days = Oct 6..10 keeps neither.
  [ "$(agg "a['claude-code']['skills']" 8)" = '{"a-rare": 1, "a-used": 3}' ]
  [ "$(agg "a['claude-code']['skills']" 5)" = '{}' ]
}

# --- (b) a skill used on one host only is used ---------------------------------

@test "(b) a skill used on only one host is 'used' and never proposed" {
  prune --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" "[p['name'] for p in d['proposals']]")" \
    = '["dead", "a-never", "a-rare", "core-idle", "solo-bot"]' ]
  # counts: used a-used + b-slash; rare a-rare; never the other five
  [ "$(jget "$output" "d['counts']")" = '{"never": 5, "rare": 1, "used": 2}' ]
}

# --- (c) all-unused repo -> proposal A -----------------------------------------

@test "(c) the all-unused repo yields proposal A with its saving" {
  prune
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^1\. A: demote repo `dead` to library, saves ~79 chars\. Drops: d-one, d-three, d-two\.'
  # alpha is only 2/3 unused, so it is NOT demoted
  ! echo "$output" | grep -q 'demote repo `alpha`'
}

# --- (d) name-only lines and the skillOverrides block --------------------------

@test "(d) rare and never skills get name-only lines and a JSON skillOverrides block" {
  prune
  echo "$output" | grep -q '^2\. B: name-only `a-never` (never, 0 uses), saves ~18 chars'
  echo "$output" | grep -q '^3\. B: name-only `a-rare` (rare, 2 uses), saves ~17 chars'
  echo "$output" | grep -q '^4\. C: agent `core-idle` never used\. Overlay: `-project:core`\.'
  echo "$output" | grep -q '^5\. C: agent `solo-bot` never used\.$'
  block="$(printf '%s\n' "$output" | awk '/^```json/{f=1;next} /^```/{f=0} f')"
  [ "$(jget "$block" "d")" = '{"skillOverrides": {"a-never": "name-only", "a-rare": "name-only"}}' ]
}

# --- (e) keep list -------------------------------------------------------------

@test "(e) keep-listed names never appear in proposals" {
  prune
  # grid-help is wired and never used; it must not show up anywhere in the report.
  ! echo "$output" | grep -q 'grid-help' || false
  prune --json
  [ "$(jget "$output" "[p['name'] for p in d['proposals'] if p['name'] == 'grid-help']")" = "[]" ]
}

# --- (f) insufficient history --------------------------------------------------

@test "(f) coverage under --min-days says insufficient history and proposes nothing" {
  rm "$USAGE"/*.json
  printf '{"schema":1,"host":"short","harnesses":{"claude-code":{"days":{"2026-10-10":{"skills":{"a-used":1}}},"wired":{"skills":[],"agents":["core-idle"]}}}}\n' \
    > "$USAGE/short.json"
  prune
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'insufficient history: 1 days of 28 required'
  ! echo "$output" | grep -qE 'name-only|Proposals|demote|skillOverrides|agent `' || false
  echo "$output" | grep -q '^## Evidence'
  prune --json
  [ "$(jget "$output" "[d['insufficient'], d['proposals']]")" = "[true, []]" ]
}

# --- (g) read-only -------------------------------------------------------------

@test "(g) a run changes no file in the grid or the usage dir" {
  g1="$(tree_hash "$MOCK_GRID")"; u1="$(tree_hash "$USAGE")"
  prune
  prune --json
  prune --out "$OTHER_DIR/out.md"
  [ -s "$OTHER_DIR/out.md" ]
  [ "$g1" = "$(tree_hash "$MOCK_GRID")" ]
  [ "$u1" = "$(tree_hash "$USAGE")" ]
}

@test "no baseline on this machine: message, exit 0" {
  export GRID_BASELINE="$OTHER_DIR/does-not-exist.txt"
  prune
  [ "$status" -eq 0 ]
  [ "$output" = "no baseline on this machine" ]
}

# --- (h) --json matches the markdown -------------------------------------------

@test "(h) --json parses and its counts match the markdown" {
  prune --json
  js="$output"
  prune
  md="$output"
  [ "$(jget "$js" "len(d['proposals'])")" = "$(echo "$md" | grep -cE '^[0-9]+\. ')" ]
  [ "$(jget "$js" "[sum(p['kind'] == k for p in d['proposals']) for k in 'ABC']")" = "[1, 2, 2]" ]
  echo "$md" | grep -q '^## Proposals (5: A 1, B 2, C 2)'
  echo "$md" | grep -q 'baseline skills: 2 used, 1 rare, 5 never'
  [ "$(jget "$js" "[d['hosts'], d['coverage_days']]")" = "[2, 40]" ]
  echo "$md" | grep -q -- '- Hosts reporting: 2'
  echo "$md" | grep -q -- '- Day coverage: 40 days'
}

# --- (i) corrupt and unknown-schema files --------------------------------------

@test "(i) a corrupt json and a schema 99 file are skipped, listed in ignored, exit 0" {
  printf '{"schema": 1, "harnesses": {' > "$USAGE/broken.json"
  printf '{"schema": 99, "host": "future", "harnesses": {}}\n' > "$USAGE/future.json"
  printf 'notes\n' > "$USAGE/README.md"          # not *.json: silently skipped, not "ignored"
  [ "$(agg "a['ignored']")" = '["broken.json", "future.json"]' ]
  prune
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Ignored usage files.*broken.json, future.json'
  # the good hosts still produce the same proposals
  echo "$output" | grep -q '^## Proposals (5: A 1, B 2, C 2)'
}

# --- (j) tokens and hooks: aggregated, but never part of the report ------------

@test "(j) aggregate() tokens and hooks match the hand count" {
  [ "$(agg "a['claude-code']['tokens']")" = '{"2026-09": {"claude-sonnet-5-5": {"cache_read": 3110, "cache_write": 622, "in": 41, "msgs": 71, "out": 344}}, "2026-10": {"claude-haiku-4-5": {"cache_read": 0, "cache_write": 0, "in": 2, "msgs": 2, "out": 10}, "claude-sonnet-5-5": {"cache_read": 1100, "cache_write": 220, "in": 20, "msgs": 30, "out": 140}}}' ]
  [ "$(agg "a['claude-code']['hooks']")" = '{"PreToolUse:Bash": 20, "Stop": 50}' ]
  # hooks honour the window (Oct 6..10: Stop 5 + 5, PreToolUse:Bash 10); tokens do not
  [ "$(agg "a['claude-code']['hooks']" 5)" = '{"PreToolUse:Bash": 10, "Stop": 10}' ]
  [ "$(agg "a['claude-code']['tokens']['2026-09']['claude-sonnet-5-5']['msgs']" 5)" = "71" ]
}

@test "(j) removing every tokens and hooks object leaves the report byte-identical" {
  prune
  with="$output"
  prune --json
  with_json="$output"
  python3 - "$USAGE" <<'EOF'
import glob, json, sys
for path in glob.glob(sys.argv[1] + "/*.json"):
    doc = json.load(open(path))
    for h in doc["harnesses"].values():
        for day in h["days"].values():
            day.pop("tokens", None)
            day.pop("hooks", None)
    json.dump(doc, open(path, "w"), indent=2, sort_keys=True)
EOF
  prune
  [ "$output" = "$with" ]
  prune --json
  [ "$output" = "$with_json" ]
}

# --- the documented read recipe -------------------------------------------------

@test "usage docs recipe runs against the fixtures" {
  cd "$BATS_TEST_DIRNAME/.."
  run python3 -c 'import sys; sys.path.insert(0, "scripts/usage"); import aggregate, json; print(json.dumps(aggregate.aggregate(sys.argv[1], 90)["claude-code"]["tokens"], indent=2, sort_keys=True))' "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import sys, json; print(json.load(sys.stdin)["2026-09"]["claude-sonnet-5-5"]["msgs"])')" = "71" ]
}
