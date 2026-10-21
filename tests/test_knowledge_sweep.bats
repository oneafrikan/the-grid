#!/usr/bin/env bats
# scripts/knowledge.py `plan` (change `knowledge-signals`, group 2): the read-only selection,
# ordering, cap and `invalid` disposition. Every test builds its own fixture repo with
# `git init` under the bats temp dir; nothing touches the real tree.
load helpers/setup
bats_require_minimum_version 1.5.0

setup() {
  common_setup
  KN="$REPO_ROOT/scripts/knowledge.py"
  PROJ="$BATS_TEST_TMPDIR/proj"
}

teardown() {
  common_teardown
}

# fixture — a git repo with one empty base commit. Identity comes from the environment (no
# address in this file) and no user or system git config is read.
fixture() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL=t@example.com GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$PROJ"
  git -C "$PROJ" init -q
  git -C "$PROJ" commit -q --allow-empty -m base
}

# fsig <n> — file a valid signal whose timestamp is 2026-10-18 10:00:<n> seconds (n < 60), so
# a lower n sorts first. Prints the file name.
fsig() {
  KNOWLEDGE_NOW=$(printf '20261018T1000%02dZ' "$1") python3 -I "$KN" file --root "$PROJ" \
    --filer agent-a --claim "claim number $1" --stage provisional --warrant "seen in CI" \
    | xargs basename
}

# commit_all — commit everything in the fixture so the signals have an add commit.
commit_all() {
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m signals
}

# plan_json <args...> — run `plan` against the fixture, leaving the JSON in $output.
plan_json() {
  run --separate-stderr python3 -I "$KN" plan --root "$PROJ" "$@"
  [ "$status" -eq 0 ]
}

# jq_py <expression over d> — evaluate an expression over the parsed plan in $output.
jq_py() {
  printf '%s' "$output" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

@test "plan: cap 10 of 25 valid signals lists 10 oldest first and defers 15" {
  fixture
  for i in $(seq 1 25); do fsig "$i" >/dev/null; done
  commit_all
  plan_json --cap 10
  [ "$(jq_py "len(d['signals'])")" = "10" ]
  [ "$(jq_py "d['deferred']")" = "15" ]
  [ "$(jq_py "d['pending']")" = "25" ]
  [ "$(jq_py "d['cap']")" = "10" ]
  [ "$(jq_py "d['counts']")" = "{'pending': 10}" ]
  # The listed names are the ten oldest, in order.
  [ "$(jq_py "[s['file'] for s in d['signals']] == sorted(s['file'] for s in d['signals'])")" = "True" ]
  [ "$(jq_py "d['signals'][0]['file'][:16]")" = "20261018T100001Z" ]
  [ "$(jq_py "d['signals'][9]['file'][:16]")" = "20261018T100010Z" ]
  [ "$(jq_py "d['signals'][0]['claim_hash'] is not None and len(d['signals'][0]['claim_hash'])")" = "16" ]
}

@test "plan: the default cap is 10" {
  fixture
  for i in $(seq 1 12); do fsig "$i" >/dev/null; done
  commit_all
  plan_json
  [ "$(jq_py "d['cap']")" = "10" ]
  [ "$(jq_py "len(d['signals'])")" = "10" ]
  [ "$(jq_py "d['deferred']")" = "2" ]
}

@test "plan: writes nothing, so git status --porcelain is empty afterwards" {
  fixture
  for i in $(seq 1 3); do fsig "$i" >/dev/null; done
  commit_all
  plan_json
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
}

@test "plan: two runs on an unchanged tree print identical bytes" {
  fixture
  for i in $(seq 1 4); do fsig "$i" >/dev/null; done
  commit_all
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/one"
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/two"
  cmp "$BATS_TEST_TMPDIR/one" "$BATS_TEST_TMPDIR/two"
  # Sorted keys, 2-space indent.
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/one")" = '  "cap": 10,' ]
}

@test "plan: a signal with a hidden character is listed invalid with its code and no claim_hash" {
  fixture
  # A zero-width space (U+200B) in the claim; the file name is a valid signal name.
  mkdir -p "$PROJ/signals"
  printf -- '---\nfiled_by: agent-a\nclaim: use the\xe2\x80\x8b gate\nstage: wip\nwarrant: seen\nstatus: pending\n---\n' \
    >"$PROJ/signals/20261018T100000Z-agent-a-abc123.md"
  fsig 1 >/dev/null
  commit_all
  plan_json
  [ "$(jq_py "d['signals'][0]['file']")" = "20261018T100000Z-agent-a-abc123.md" ]
  [ "$(jq_py "d['signals'][0]['disposition']")" = "invalid" ]
  [ "$(jq_py "d['signals'][0]['reasons']")" = "['E_SIGNAL']" ]
  [ "$(jq_py "d['signals'][0]['claim_hash']")" = "None" ]
  [ "$(jq_py "d['signals'][1]['disposition']")" = "pending" ]
  [ "$(jq_py "d['counts']")" = "{'invalid': 1, 'pending': 1}" ]
}

@test "plan: a signal edited after it was added is invalid with E_EDITED" {
  fixture
  name=$(fsig 1)
  commit_all
  printf 'extra body\n' >>"$PROJ/signals/$name"
  plan_json
  [ "$(jq_py "d['signals'][0]['disposition']")" = "invalid" ]
  [ "$(jq_py "d['signals'][0]['reasons']")" = "['E_EDITED']" ]
}

@test "plan: a signal in the ledger or in signals/done/ is not listed" {
  fixture
  ledgered=$(fsig 1)
  done_one=$(fsig 2)
  keep=$(fsig 3)
  mkdir -p "$PROJ/signals/done"
  mv "$PROJ/signals/$done_one" "$PROJ/signals/done/$done_one"
  printf '{"claim_hash":"0123456789abcdef","disposition":"written","entry":null,"event":"disposition","issue":null,"pr":null,"run":"r1","signal":"%s"}\n' \
    "$ledgered" >"$PROJ/signals/done/ledger.jsonl"
  commit_all
  plan_json
  [ "$(jq_py "[s['file'] for s in d['signals']] == ['$keep']")" = "True" ]
  [ "$(jq_py "d['pending']")" = "1" ]
  [ "$(jq_py "d['deferred']")" = "0" ]
}

@test "plan: README.md, hand-off files and misnamed files are ignored and not counted" {
  fixture
  fsig 1 >/dev/null
  printf '# signals\n' >"$PROJ/signals/README.md"
  printf 'hand-off\n' >"$PROJ/signals/→x.md"
  printf -- '---\nclaim: misnamed\n---\n' >"$PROJ/signals/not-a-signal.md"
  commit_all
  plan_json
  [ "$(jq_py "d['pending']")" = "1" ]
  [ "$(jq_py "len(d['signals'])")" = "1" ]
}

@test "plan: a tree with no signals/ gives an empty plan" {
  fixture
  plan_json
  [ "$(jq_py "d")" = "{'cap': 10, 'counts': {}, 'deferred': 0, 'pending': 0, 'reconcile': [], 'signals': []}" ]
}

@test "plan: a bad --cap is a usage error (exit 2) with nothing on stdout" {
  fixture
  run --separate-stderr python3 -I "$KN" plan --root "$PROJ" --cap -1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "knowledge.py: --cap must be a non-negative integer" ]]
}

# secret_tok — a token-shaped value assembled from two literals, so this file holds no whole
# token (same trick as tests/test_hooks.bats).
secret_tok() { printf '%s' "sk""-$(printf 'Ab3dE%.0s' 1 2 3 4 5 6 7 8)"; }

# write_sig <warrant> <claim> — hand-write a grammar-valid signal (the `file` subcommand is not
# what is under test).
write_sig() {
  mkdir -p "$PROJ/signals"
  printf -- '---\nfiled_by: agent-a\nclaim: %s\nstage: wip\nwarrant: %s\nstatus: pending\n---\n' \
    "$2" "$1" >"$PROJ/signals/20261018T100000Z-agent-a-abc123.md"
}

@test "plan: a signal holding a token-shaped value is secret and the value is printed nowhere" {
  fixture
  tok=$(secret_tok)
  write_sig "seen in $tok" "use the gate"
  commit_all
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
  output=$(cat "$BATS_TEST_TMPDIR/out")
  [ "$(jq_py "d['signals'][0]['disposition']")" = "secret" ]
  [ "$(jq_py "d['signals'][0]['reasons']")" = "['generic-sk']" ]
  [ "$(jq_py "d['signals'][0]['claim_hash']")" = "None" ]
  [ "$(jq_py "d['signals'][0]['entry']")" = "None" ]
  [ "$(jq_py "d['counts']")" = "{'secret': 1}" ]
  ! grep -qF -- "$tok" "$BATS_TEST_TMPDIR/out" || false
  ! grep -qF -- "$tok" "$BATS_TEST_TMPDIR/err" || false
  ! grep -qF -- "${tok:0:12}" "$BATS_TEST_TMPDIR/out" || false
}

@test "plan: the allow pragma does not exempt a token from the scan" {
  fixture
  # Read the pragma from the library so it is not spelled in this file.
  pragma=$(sed -n "s/^_SECRET_PRAGMA='\(.*\)'$/\1/p" "$REPO_ROOT/hooks/lib/secret-patterns.sh")
  [ -n "$pragma" ]
  write_sig "seen in $(secret_tok) $pragma" "use the gate"
  commit_all
  plan_json
  [ "$(jq_py "d['signals'][0]['disposition']")" = "secret" ]
}

@test "plan: a claim with an https URL and backticks is not secret" {
  fixture
  write_sig "seen in CI" 'see `scripts/gate.sh` and https://example.com/docs/page'
  commit_all
  plan_json
  [ "$(jq_py "d['signals'][0]['disposition']")" = "pending" ]
  [ "$(jq_py "d['signals'][0]['reasons']")" = "[]" ]
}

@test "plan: KNOWLEDGE_SECRET_PATTERNS naming a missing file is a usage error (exit 2)" {
  fixture
  fsig 1 >/dev/null
  commit_all
  KNOWLEDGE_SECRET_PATTERNS="$BATS_TEST_TMPDIR/nope.sh" run --separate-stderr python3 -I "$KN" plan --root "$PROJ"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"secret-patterns.sh not found"* ]]
}
