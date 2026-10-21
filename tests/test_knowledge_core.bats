#!/usr/bin/env bats
# scripts/knowledge.py core helpers (change `knowledge-signals`): claim hash, entry id,
# slug, warrant rule and stage ceiling. Pure functions: no files are written.

load helpers/setup

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# py <expr> — evaluate a Python expression against the library and print the result.
# -I keeps the user's site and environment out; the library dir is added by hand.
py() {
  python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge
print(eval(sys.argv[2]))
' "$REPO_ROOT" "$1"
}

@test "claim_hash ignores case and spacing" {
  a=$(py 'knowledge.claim_hash("Use  the   Gate")')
  b=$(py 'knowledge.claim_hash("  use the gate\t")')
  [ "$a" = "$b" ]
}

@test "claim_hash differs for different claims" {
  a=$(py 'knowledge.claim_hash("use the gate")')
  b=$(py 'knowledge.claim_hash("skip the gate")')
  [ "$a" != "$b" ]
}

@test "claim_hash is 16 lowercase hex" {
  run py 'knowledge.claim_hash("use the gate")'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{16}$ ]]
}

@test "entry_id is K- plus 8 hex of the claim hash" {
  id=$(py 'knowledge.entry_id("use the gate")')
  h=$(py 'knowledge.claim_hash("use the gate")')
  [[ "$id" =~ ^K-[0-9a-f]{8}$ ]]
  [ "$id" = "K-${h:0:8}" ]
}

@test "slug folds punctuation runs to one dash" {
  run py 'knowledge.slug("  Hello, World!! -- v2.0 ")'
  [ "$output" = "hello-world-v2-0" ]
}

@test "slug cuts at 40 with no trailing dash" {
  # 39 letters then punctuation: the cut at 40 lands on a dash that must be trimmed.
  run py 'knowledge.slug("a" * 39 + "!!bbb")'
  [ "$output" = "$(printf 'a%.0s' $(seq 1 39))" ]
  run py 'len(knowledge.slug("x" * 100))'
  [ "$output" = "40" ]
}

@test "is_warranted is false for each placeholder, any case" {
  for w in none NONE n/a N/A na untested unknown tbd TBD '?' '' '   '; do
    run py "knowledge.is_warranted($(printf '%s' "$w" | python3 -I -c 'import sys; print(repr(sys.stdin.read()))'))"
    [ "$output" = "False" ]
  done
}

@test "is_warranted is true for a real sentence" {
  run py 'knowledge.is_warranted("  ran bats on the branch, all green ")'
  [ "$output" = "True" ]
}

@test "ceiling: no warranted filer is wip" {
  run py 'knowledge.ceiling([])'
  [ "$output" = "wip" ]
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "none"}])'
  [ "$output" = "wip" ]
}

@test "ceiling: one warranted filer is provisional" {
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "saw it"}, {"filed_by": "b", "warrant": "tbd"}])'
  [ "$output" = "provisional" ]
}

@test "ceiling: two warranted filers is established" {
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "saw it"}, {"filed_by": "b", "warrant": "ran it"}])'
  [ "$output" = "established" ]
}

@test "ceiling: one filer twice counts once" {
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "saw it"}, {"filed_by": "a", "warrant": "ran it"}])'
  [ "$output" = "provisional" ]
}
