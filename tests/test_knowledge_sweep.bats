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
  [ "$(jq_py "d['counts']")" = "{'written': 10}" ]
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
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/one")" = '  "canon_claims": [],' ]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/one")" = '  "cap": 10,' ]
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
  [ "$(jq_py "d['signals'][1]['disposition']")" = "written" ]
  [ "$(jq_py "d['counts']")" = "{'invalid': 1, 'written': 1}" ]
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
  [ "$(jq_py "d")" = "{'canon_claims': [], 'cap': 10, 'counts': {}, 'deferred': 0, 'pending': 0, 'reconcile': [], 'signals': []}" ]
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
  [ "$(jq_py "d['signals'][0]['disposition']")" = "written" ]
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

# ledger_line <json> — append one hand-written ledger line (the shape from the design's "Ledger").
ledger_line() {
  mkdir -p "$PROJ/signals/done"
  printf '%s\n' "$1" >>"$PROJ/signals/done/ledger.jsonl"
}

# esc_line <hash> <signal> <issue> — an `escalated` disposition line.
esc_line() {
  ledger_line "{\"claim_hash\":\"$1\",\"disposition\":\"escalated\",\"entry\":null,\"event\":\"disposition\",\"issue\":$3,\"pr\":null,\"run\":\"r1\",\"signal\":\"$2\"}"
}

# res_line <hash> <result> — a `resolution` line.
res_line() {
  ledger_line "{\"claim_hash\":\"$1\",\"event\":\"resolution\",\"pr\":null,\"result\":\"$2\",\"run\":\"r2\"}"
}

# claim_of_first — claim hash of the first listed signal of the plan in $output.
claim_of_first() {
  jq_py "d['signals'][0]['claim_hash']"
}

@test "plan: a claim with an open escalation is duplicate and the reason names the issue" {
  fixture
  fsig 1 >/dev/null
  commit_all
  plan_json
  h=$(claim_of_first)
  esc_line "$h" "20250101T000000Z-agent-a-old000.md" 77
  plan_json
  [ "$(jq_py "d['signals'][0]['disposition']")" = "duplicate" ]
  [ "$(jq_py "d['signals'][0]['reasons']")" = "['open issue 77']" ]
  [ "$(jq_py "d['counts']")" = "{'duplicate': 1}" ]
}

@test "plan: a rejected claim is repeat-rejected, and not after a later reopen" {
  fixture
  fsig 1 >/dev/null
  commit_all
  plan_json
  h=$(claim_of_first)
  res_line "$h" rejected
  plan_json
  [ "$(jq_py "d['signals'][0]['disposition']")" = "repeat-rejected" ]
  [ "$(jq_py "d['counts']")" = "{'repeat-rejected': 1}" ]
  ledger_line "{\"by\":\"operator\",\"claim_hash\":\"$h\",\"event\":\"reopen\",\"run\":\"r3\"}"
  plan_json
  # Past the ledger rules the signal reaches the entry rules: no entry yet, so it is written.
  [ "$(jq_py "d['signals'][0]['disposition']")" = "written" ]
}

@test "plan: open escalations are reconcile items, each takes a cap slot, and an accepted one is not listed" {
  fixture
  for i in 1 2 3; do fsig "$i" >/dev/null; done
  commit_all
  esc_line aaaaaaaaaaaaaaaa "20250101T000001Z-agent-a-old001.md" 11
  esc_line bbbbbbbbbbbbbbbb "20250101T000002Z-agent-a-old002.md" 12
  esc_line cccccccccccccccc "20250101T000003Z-agent-a-old003.md" 13
  res_line cccccccccccccccc accepted
  plan_json --cap 3
  [ "$(jq_py "[r['issue'] for r in d['reconcile']]")" = "[11, 12]" ]
  [ "$(jq_py "sorted(d['reconcile'][0])")" = "['claim_hash', 'issue', 'pr', 'signal']" ]
  [ "$(jq_py "len(d['signals'])")" = "1" ]
  [ "$(jq_py "d['deferred']")" = "2" ]
  # Items past the cap are counted in deferred, not dropped silently.
  plan_json --cap 1
  [ "$(jq_py "len(d['reconcile'])")" = "1" ]
  [ "$(jq_py "len(d['signals'])")" = "0" ]
  [ "$(jq_py "d['deferred']")" = "4" ]
}

# mk_entry <dir> <claim> [<filer>|<stage>|<warrant>]... — write an entry in knowledge/<dir>/ with
# render_entry, one evidence line per argument, so the fixture is always a layout the reader accepts.
mk_entry() {
  python3 -I - "$REPO_ROOT/scripts" "$PROJ" "$@" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import knowledge as k
root, dirname, claim = sys.argv[2:5]
evidence = []
for n, spec in enumerate(sys.argv[5:], 1):
    filer, stage, warrant = spec.split("|", 2)
    evidence.append({"signal": "20260101T0000%02dZ-%s-aaaaa%d.md" % (n, filer, n),
                     "filed_by": filer, "stage": stage, "warrant": warrant})
fields = {"id": k.entry_id(claim), "claim": claim, "claim_hash": k.claim_hash(claim),
          "stage": "canonical" if dirname == "canon" else dirname,
          "created": "2026-01-01", "updated": "2026-01-01"}
os.makedirs(os.path.join(root, "knowledge", dirname), exist_ok=True)
path = os.path.join(root, "knowledge", dirname, fields["id"] + ".md")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(k.render_entry(fields, evidence))
PY
}

# esig <filer> <stage> <warrant> <claim> [extra file args] — file one signal (timestamp 10:00:30).
esig() {
  local filer=$1 stage=$2 warrant=$3 claim=$4
  shift 4
  KNOWLEDGE_NOW=20261018T100030Z python3 -I "$KN" file --root "$PROJ" --filer "$filer" \
    --claim "$claim" --stage "$stage" --warrant "$warrant" "$@" >/dev/null
}

# Assert the first plan signal's disposition, stage and entry address (the entry is K- plus the
# first 8 of the signal's own claim hash unless a third argument gives another one).
expect_first() {
  [ "$(jq_py "d['signals'][0]['disposition']")" = "$1" ]
  [ "$(jq_py "d['signals'][0]['stage']")" = "$2" ]
  [ "$(jq_py "d['signals'][0]['entry']")" = "${3:-K-$(jq_py "d['signals'][0]['claim_hash'][:8]")}" ]
}

@test "plan: an unwarranted established claim with no entry is wip at stage wip" {
  fixture
  esig agent-a established none "claim one"
  commit_all
  plan_json
  expect_first wip wip
}

@test "plan: a warranted provisional claim with no entry is written at provisional" {
  fixture
  esig agent-a provisional "seen in CI" "claim one"
  commit_all
  plan_json
  expect_first written provisional
}

@test "plan: a first established claim is written at provisional (one filer)" {
  fixture
  esig agent-a established "seen in CI" "claim one"
  commit_all
  plan_json
  expect_first written provisional
}

@test "plan: a second filer naming the entry with a new warrant confirms it to established" {
  fixture
  mk_entry provisional "claim one" "agent-a|established|seen in CI"
  id=$(python3 -I "$KN" hash "claim one" | cut -c1-8)
  esig agent-b established "reproduced locally" "claim one reworded" --confirms "K-$id"
  commit_all
  plan_json
  expect_first confirmed established "K-$id"
}

@test "plan: the same filer again is a duplicate and the entry keeps its stage" {
  fixture
  mk_entry provisional "claim one" "agent-a|established|seen in CI"
  esig agent-a established "a different warrant" "claim one"
  commit_all
  plan_json
  expect_first duplicate provisional
}

@test "plan: a second filer with an identical warrant (other case) is a duplicate" {
  fixture
  mk_entry provisional "claim one" "agent-a|established|seen in CI"
  esig agent-b established "SEEN IN ci" "claim one"
  commit_all
  plan_json
  expect_first duplicate provisional
}

@test "plan: a filer whose earlier signal had no warrant adds one and confirms wip to provisional" {
  fixture
  mk_entry wip "claim one" "agent-a|provisional|none"
  esig agent-a provisional "seen in CI" "claim one"
  commit_all
  plan_json
  expect_first confirmed provisional
}

@test "plan: an unwarranted signal on an existing entry is a duplicate" {
  fixture
  mk_entry provisional "claim one" "agent-a|provisional|seen in CI"
  esig agent-b established none "claim one"
  commit_all
  plan_json
  expect_first duplicate provisional
}

# expect_escalated <reason> — the first plan signal is escalated with exactly that one reason and
# carries no entry and no stage.
expect_escalated() {
  [ "$(jq_py "d['signals'][0]['disposition']")" = "escalated" ]
  [ "$(jq_py "d['signals'][0]['reasons']")" = "['$1']" ]
  [ "$(jq_py "d['signals'][0]['entry']")" = "None" ]
  [ "$(jq_py "d['signals'][0]['stage']")" = "None" ]
}

@test "plan: a signal claiming stage canonical is escalated (canonical) with no entry or stage" {
  fixture
  esig agent-a canonical "seen in CI" "claim one"
  commit_all
  plan_json
  expect_escalated canonical
}

@test "plan: a signal with supersedes is escalated (supersedes)" {
  fixture
  esig agent-a provisional "seen in CI" "claim one" --supersedes K-aaaaaaaa
  commit_all
  plan_json
  expect_escalated supersedes
}

@test "plan: a signal with contradicts is escalated (contradicts)" {
  fixture
  esig agent-a provisional "seen in CI" "claim two" --contradicts K-aaaaaaaa
  commit_all
  plan_json
  expect_escalated contradicts
}

@test "plan: a claim matching an entry in canon/ is escalated (canon-match)" {
  fixture
  mk_entry canon "claim one" "agent-a|canonical|seen in CI"
  esig agent-b provisional "reproduced locally" "claim one"
  commit_all
  plan_json
  expect_escalated canon-match
}

@test "plan: a forged entry with the same K-id but another claim_hash is escalated (id-collision)" {
  fixture
  id=$(python3 -I "$KN" hash "claim one" | cut -c1-8)
  mkdir -p "$PROJ/knowledge/provisional"
  # Only the name and the claim_hash line matter: the file does not parse, so it is read raw.
  printf -- '---\nclaim_hash: 0000000000000000\n---\n' >"$PROJ/knowledge/provisional/K-$id-forged.md"
  esig agent-a provisional "seen in CI" "claim one"
  commit_all
  plan_json
  expect_escalated id-collision
}

# write_guardrails — a GUARDRAILS.md at the fixture root holding a G3 line (and a G30 one, so a
# lookup of G3 cannot match by prefix).
write_guardrails() {
  printf '# Guardrails\n\n- G3: Add sponsored content [check: human]\n- G30: Other rule [check: none]\n' \
    >"$PROJ/GUARDRAILS.md"
}

@test "plan: a signal citing a guardrail needs guardrail judgement and carries the exact line" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  plan_json
  expect_first written provisional
  [ "$(jq_py "d['signals'][0]['needs_judgement']")" = "['guardrail']" ]
  [ "$(jq_py "d['signals'][0]['guardrail_text']")" = "- G3: Add sponsored content [check: human]" ]
}

@test "plan: a signal citing a guardrail that is not in GUARDRAILS.md is escalated (guardrail-not-found)" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G9
  commit_all
  plan_json
  expect_escalated guardrail-not-found
  [ "$(jq_py "d['signals'][0]['needs_judgement']")" = "[]" ]
}

@test "plan: with canon entries the plan lists canon_claims and ordinary signals need canon judgement" {
  fixture
  mk_entry canon "canon claim" "agent-a|canonical|seen in CI"
  esig agent-b provisional "seen in CI" "claim one"
  commit_all
  plan_json
  id=$(python3 -I "$KN" hash "canon claim" | cut -c1-8)
  [ "$(jq_py "d['canon_claims']")" = "[{'claim': 'canon claim', 'id': 'K-$id'}]" ]
  [ "$(jq_py "d['signals'][0]['needs_judgement']")" = "['canon']" ]
}

@test "plan: with no canon, canon_claims is empty and a plain signal needs no judgement" {
  fixture
  esig agent-a provisional "seen in CI" "claim one"
  commit_all
  plan_json
  [ "$(jq_py "d['canon_claims']")" = "[]" ]
  [ "$(jq_py "d['signals'][0]['needs_judgement']")" = "[]" ]
}

@test "plan: at most 3 escalated signals are listed, the rest stay pending and count as deferred" {
  fixture
  for i in 1 2 3 4 5; do
    KNOWLEDGE_NOW=$(printf '20261018T1000%02dZ' "$i") python3 -I "$KN" file --root "$PROJ" \
      --filer agent-a --claim "claim number $i" --stage provisional --warrant "seen in CI" \
      --supersedes K-aaaaaaaa >/dev/null
  done
  commit_all
  plan_json
  [ "$(jq_py "len(d['signals'])")" = "3" ]
  [ "$(jq_py "d['counts']")" = "{'escalated': 3}" ]
  [ "$(jq_py "d['deferred']")" = "2" ]
  [ "$(jq_py "d['pending']")" = "5" ]
  [ "$(ls "$PROJ/signals" | grep -c '\.md$')" = "5" ]
}

@test "plan: with guardrail and canon judgement, two runs print identical bytes and nothing is written" {
  fixture
  write_guardrails
  mk_entry canon "canon claim" "agent-a|canonical|seen in CI"
  esig agent-b provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  plan_json
  first=$output
  plan_json
  [ "$output" = "$first" ]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
}

# --- apply: guards only (no writes) -------------------------------------------------------

# commits — number of commits in the fixture, to prove apply never commits.
commits() {
  git -C "$PROJ" rev-list --count HEAD
}

# empty_plan — plan from a committed fixture with no signals, saved outside the repo.
empty_plan() {
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
}

@test "apply: a valid plan with nothing to write exits 0, writes nothing and makes no commit" {
  fixture
  empty_plan
  before=$(commits)
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/plan.json"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
  [ "$(commits)" = "$before" ]
}

@test "apply: while another process holds the lock it exits 3 with locked on stderr and writes nothing" {
  fixture
  empty_plan
  before=$(commits)
  # The holder prints one line once it owns the lock, then waits on stdin; reading that line
  # means no sleep or polling is needed. Killing it releases the lock (the OS does that).
  coproc HOLDER (python3 -I -c 'import fcntl,sys; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); print("held",flush=True); sys.stdin.readline()' "$PROJ/.git/knowledge-sweep.lock")
  read -r line <&"${HOLDER[0]}"
  [ "$line" = "held" ]
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/plan.json"
  kill "$HOLDER_PID" || true
  [ "$status" -eq 3 ]
  [[ "$stderr" == *locked* ]]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
  [ "$(commits)" = "$before" ]
}

@test "apply: an uncommitted new file exits 4 and nothing is written" {
  fixture
  empty_plan
  before=$(commits)
  printf 'stray\n' >"$PROJ/stray.txt"
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/plan.json"
  [ "$status" -eq 4 ]
  # Only the stray file is there: apply added nothing of its own.
  [ "$(git -C "$PROJ" status --porcelain)" = "?? stray.txt" ]
  [ "$(commits)" = "$before" ]
}

@test "apply: a plan item that would write stage canonical exits 2 and knowledge/canon is unchanged" {
  fixture
  printf '%s\n' '{"signals": [{"file": "x.md", "disposition": "written", "stage": "canonical", "entry": "K-00000000"}]}' \
    >"$BATS_TEST_TMPDIR/forged.json"
  before=$(commits)
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/forged.json"
  [ "$status" -eq 2 ]
  [ ! -e "$PROJ/knowledge/canon" ]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
  [ "$(commits)" = "$before" ]
}

@test "apply: an escalated item with no stage is not a canon write and exits 0" {
  fixture
  # A real signal, since apply now moves every listed signal.
  name=$(fsig 1)
  commit_all
  printf '{"signals": [{"file": "%s", "disposition": "escalated", "stage": null, "entry": null}]}\n' "$name" \
    >"$BATS_TEST_TMPDIR/esc.json"
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/esc.json"
  [ "$status" -eq 0 ]
}

@test "apply: bad JSON, a missing plan file and an unknown disposition each exit 2" {
  fixture
  before=$(commits)
  printf 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  printf '%s\n' '{"signals": [{"file": "x.md", "disposition": "bogus"}]}' >"$BATS_TEST_TMPDIR/unk.json"
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/unk.json"
  [ "$status" -eq 2 ]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
  [ "$(commits)" = "$before" ]
}

# --- apply: entries -----------------------------------------------------------------------

# plan_apply — plan the committed fixture to a file outside the repo, apply it with a fixed
# date, and require exit 0 and a tree `check` accepts. The run date is 2026-10-19.
plan_apply() {
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
  KNOWLEDGE_NOW=20261019T120000Z run --separate-stderr python3 -I "$KN" apply --root "$PROJ" \
    --plan "$BATS_TEST_TMPDIR/plan.json"
  [ "$status" -eq 0 ]
  run --separate-stderr python3 -I "$KN" check --root "$PROJ"
  [ "$status" -eq 0 ]
}

@test "apply: an unwarranted established claim becomes a wip entry marked unwarranted" {
  fixture
  esig agent-a established none "claim one"
  commit_all
  plan_apply
  f=$(ls "$PROJ"/knowledge/wip/K-*-claim-one.md)
  grep -qx 'stage: wip' "$f"
  grep -qx 'unwarranted: yes' "$f"
  grep -qx 'created: 2026-10-19' "$f"
}

@test "apply: a warranted provisional claim becomes one provisional entry with one evidence line and no signal body" {
  fixture
  printf 'BODYONLYTEXT\n' >"$BATS_TEST_TMPDIR/body.txt"
  esig agent-a provisional "seen in CI" "claim one" --body-file "$BATS_TEST_TMPDIR/body.txt"
  commit_all
  plan_apply
  f=$(ls "$PROJ"/knowledge/provisional/K-*-claim-one.md)
  [ "$(grep -c '^- ' "$f")" = "1" ]
  grep -q '^- .*-agent-a-[0-9a-f]\{6\}\.md | agent-a | provisional | seen in CI$' "$f"
  ! grep -q 'unwarranted' "$f" || false
  ! grep -rq BODYONLYTEXT "$PROJ/knowledge" || false
}

@test "apply: a first established claim stays in provisional" {
  fixture
  esig agent-a established "seen in CI" "claim one"
  commit_all
  plan_apply
  [ -n "$(ls "$PROJ"/knowledge/provisional/K-*.md)" ]
  [ ! -e "$PROJ/knowledge/established" ]
}

@test "apply: a second filer with a new warrant moves the entry to established as a staged rename with two evidence lines" {
  fixture
  esig agent-a established "seen in CI" "claim one"
  commit_all
  plan_apply
  commit_all
  id=$(python3 -I "$KN" hash "claim one" | cut -c1-8)
  old=$(ls "$PROJ"/knowledge/provisional/K-"$id"-*.md)
  esig agent-b established "reproduced locally" "claim one reworded" --confirms "K-$id"
  commit_all
  plan_apply
  [ ! -e "$old" ]
  new=$(ls "$PROJ"/knowledge/established/K-"$id"-*.md)
  [ "$(grep -c '^- ' "$new")" = "2" ]
  grep -qx 'stage: established' "$new"
  grep -qx 'updated: 2026-10-19' "$new"
  git -C "$PROJ" status --porcelain | grep -q '^R'
}

@test "apply: a duplicate writes nothing" {
  fixture
  esig agent-a established "seen in CI" "claim one"
  commit_all
  plan_apply
  commit_all
  # The signal was moved to done/, so this second run has nothing pending and writes nothing.
  plan_apply
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
}

# --- apply: bookkeeping -------------------------------------------------------------------

# ledger_py <expression over L> — evaluate an expression over the list of ledger records.
ledger_py() {
  python3 -I -c "import json,sys; L=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; print($1)" \
    "$PROJ/signals/done/ledger.jsonl"
}

@test "apply: processed signals move to done/ byte-identical with one disposition line each" {
  fixture
  a=$(fsig 1)
  b=$(fsig 2)
  mkdir -p "$BATS_TEST_TMPDIR/orig"
  cp "$PROJ/signals/$a" "$PROJ/signals/$b" "$BATS_TEST_TMPDIR/orig/"
  commit_all
  plan_apply
  for n in "$a" "$b"; do
    cmp "$BATS_TEST_TMPDIR/orig/$n" "$PROJ/signals/done/$n"
    [ ! -e "$PROJ/signals/$n" ]
  done
  [ "$(ledger_py "len(L)")" = "2" ]
  [ "$(ledger_py "[r['signal'] for r in L]")" = "['$a', '$b']" ]
  # Disposition, a K- entry id built from the claim hash, null issue and pr, ISO run time.
  [ "$(ledger_py "[(r['event'], r['disposition'], r['issue'], r['pr'], r['run'], len(r['claim_hash']), r['entry'] == 'K-' + r['claim_hash'][:8]) for r in L][0]")" \
    = "('disposition', 'written', None, None, '2026-10-19T12:00:00Z', 16, True)" ]
  [ "$(ledger_py "L[1]['disposition']")" = "written" ]
}

@test "apply: a pre-existing ledger keeps its old bytes as a prefix" {
  fixture
  fsig 1 >/dev/null
  esc_line aaaaaaaaaaaaaaaa 20260101T000000Z-agent-a-aaaaa1.md 5
  commit_all
  cp "$PROJ/signals/done/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  size=$(stat -c %s "$BATS_TEST_TMPDIR/ledger.before")
  plan_apply
  cmp -n "$size" "$BATS_TEST_TMPDIR/ledger.before" "$PROJ/signals/done/ledger.jsonl"
  [ "$(ledger_py "len(L)")" = "2" ]
}

@test "apply: invalid and secret signals are also moved and recorded, with a null claim hash and entry" {
  fixture
  mkdir -p "$PROJ/signals"
  printf -- '---\nfiled_by: agent-a\nclaim: use the\xe2\x80\x8b gate\nstage: wip\nwarrant: seen\nstatus: pending\n---\n' \
    >"$PROJ/signals/20261018T100001Z-agent-a-abc124.md"
  tok=$(secret_tok)
  write_sig "seen in $tok" "use the gate"
  commit_all
  # Not plan_apply: `check` rightly reports the unchanged invalid signal now sitting in done/.
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
  KNOWLEDGE_NOW=20261019T120000Z run --separate-stderr python3 -I "$KN" apply --root "$PROJ" \
    --plan "$BATS_TEST_TMPDIR/plan.json"
  [ "$status" -eq 0 ]
  [ -e "$PROJ/signals/done/20261018T100001Z-agent-a-abc124.md" ]
  [ -e "$PROJ/signals/done/20261018T100000Z-agent-a-abc123.md" ]
  [ -z "$(ls "$PROJ"/signals/*.md 2>/dev/null)" ]
  [ "$(ledger_py "sorted((r['disposition'], r['claim_hash'], r['entry']) for r in L)")" \
    = "[('invalid', None, None), ('secret', None, None)]" ]
  # The ledger line names the signal and the pattern class never; the token is not copied.
  ! grep -qF -- "$tok" "$PROJ/signals/done/ledger.jsonl" || false
}

@test "apply: plan then apply again on the unchanged tree is a no-op and plan lists nothing pending" {
  fixture
  fsig 1 >/dev/null
  fsig 2 >/dev/null
  commit_all
  plan_apply
  commit_all
  cp "$PROJ/signals/done/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.after1"
  before=$(commits)
  plan_json
  [ "$(jq_py "d['signals']")" = "[]" ]
  [ "$(jq_py "d['pending']")" = "0" ]
  plan_apply
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
  cmp "$BATS_TEST_TMPDIR/ledger.after1" "$PROJ/signals/done/ledger.jsonl"
  [ "$(commits)" = "$before" ]
}

@test "apply: a plan naming a signal that is not in signals/ exits 2 and changes nothing" {
  fixture
  fsig 1 >/dev/null
  commit_all
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
  # Add a second item for a well-formed name that does not exist.
  python3 -I -c "
import json,sys
p=json.load(open(sys.argv[1]))
p['signals'].append({'file':'20261018T100099Z-agent-a-ffffff.md','disposition':'escalated','entry':None,'stage':None})
json.dump(p,open(sys.argv[1],'w'))" "$BATS_TEST_TMPDIR/plan.json"
  run --separate-stderr python3 -I "$KN" apply --root "$PROJ" --plan "$BATS_TEST_TMPDIR/plan.json"
  [ "$status" -eq 2 ]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
  [ ! -e "$PROJ/signals/done" ]
}

# --- apply: model verdicts and escalation records -----------------------------------------

# vapply <verdicts json> [<escalations json>] — plan the committed fixture (one signal), write
# the verdict file (SIG stands for the signal's file name), apply and require exit 0 and a tree
# `check` accepts. An empty first argument passes no --verdicts at all.
vapply() {
  local sig args=()
  sig=$(basename "$(ls "$PROJ"/signals/*.md)")
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
  if [ -n "$1" ]; then
    printf '%s' "${1//SIG/$sig}" >"$BATS_TEST_TMPDIR/verdicts.json"
    args+=(--verdicts "$BATS_TEST_TMPDIR/verdicts.json")
  fi
  if [ -n "${2:-}" ]; then
    printf '%s' "${2//SIG/$sig}" >"$BATS_TEST_TMPDIR/esc.json"
    args+=(--escalations "$BATS_TEST_TMPDIR/esc.json")
  fi
  KNOWLEDGE_NOW=20261019T120000Z run --separate-stderr python3 -I "$KN" apply --root "$PROJ" \
    --plan "$BATS_TEST_TMPDIR/plan.json" "${args[@]}"
  [ "$status" -eq 0 ]
  run --separate-stderr python3 -I "$KN" check --root "$PROJ"
  [ "$status" -eq 0 ]
}

# mk_canon — a canon entry that `check` accepts: mk_entry names the file K-<id>.md, but check
# wants the slugged name a real entry has.
mk_canon() {
  mk_entry canon "canon claim" "agent-a|canonical|seen in CI"
  local id
  id=$(python3 -I "$KN" hash "canon claim" | cut -c1-8)
  mv "$PROJ/knowledge/canon/K-$id.md" "$PROJ/knowledge/canon/K-$id-canon-claim.md"
}

# escalated_cleanly — the one signal was moved, ledgered `escalated` with no entry, and no
# entry file was written.
escalated_cleanly() {
  [ "$(ledger_py "[(r['disposition'], r['entry']) for r in L]")" = "[('escalated', None)]" ]
  [ -z "$(ls "$PROJ"/signals/*.md 2>/dev/null)" ]
  [ ! -e "$PROJ/knowledge/provisional" ]
}

@test "apply: a guardrail verdict of unsure escalates, writes no entry and still moves the signal" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  vapply '{"SIG":{"guardrail":"unsure"}}'
  escalated_cleanly
  # No --escalations file: the numbers are null.
  [ "$(ledger_py "(L[0]['issue'], L[0]['pr'])")" = "(None, None)" ]
}

@test "apply: a guardrail verdict of conflict escalates" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  vapply '{"SIG":{"guardrail":"conflict"}}'
  escalated_cleanly
}

@test "apply: a guardrail verdict of no writes the entry" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  vapply '{"SIG":{"guardrail":"no"}}'
  [ -n "$(ls "$PROJ"/knowledge/provisional/K-*-claim-one.md)" ]
  [ "$(ledger_py "[r['disposition'] for r in L]")" = "['written']" ]
}

@test "apply: a canon verdict naming an entry id escalates even when the guardrail verdict is no" {
  fixture
  write_guardrails
  mk_canon
  esig agent-b provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  id=$(python3 -I "$KN" hash "canon claim" | cut -c1-8)
  vapply "{\"SIG\":{\"guardrail\":\"no\",\"canon\":\"K-$id\"}}"
  escalated_cleanly
}

@test "apply: a canon verdict of none writes the entry" {
  fixture
  mk_canon
  esig agent-b provisional "seen in CI" "claim one"
  commit_all
  vapply '{"SIG":{"canon":"none"}}'
  [ -n "$(ls "$PROJ"/knowledge/provisional/K-*-claim-one.md)" ]
}

@test "apply: with no --verdicts file a signal that needs judgement escalates" {
  fixture
  mk_canon
  esig agent-b provisional "seen in CI" "claim one"
  commit_all
  # No --verdicts at all: a model that did not answer must not unlock a write.
  vapply ""
  escalated_cleanly
}

@test "apply: a verdict that omits the judgement a signal needs escalates" {
  fixture
  mk_canon
  esig agent-b provisional "seen in CI" "claim one"
  commit_all
  vapply '{"SIG":{"guardrail":"no"}}'
  escalated_cleanly
}

@test "apply: --escalations numbers land in the escalated ledger line, null where absent" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  vapply '{"SIG":{"guardrail":"unsure"}}' '{"SIG":{"issue":42,"pr":null}}'
  escalated_cleanly
  [ "$(ledger_py "(L[0]['issue'], L[0]['pr'])")" = "(42, None)" ]
}

@test "apply: a resolutions record appends a resolution line and a later plan sees the claim as repeat-rejected" {
  fixture
  write_guardrails
  esig agent-a provisional "seen in CI" "claim one" --guardrail GUARDRAILS#G3
  commit_all
  vapply '{"SIG":{"guardrail":"unsure"}}' '{"SIG":{"issue":42,"pr":9}}'
  [ "$(ledger_py "(L[0]['issue'], L[0]['pr'])")" = "(42, 9)" ]
  h=$(ledger_py "L[0]['claim_hash']")
  commit_all
  # A run with nothing pending still records the resolutions.
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
  printf '{"resolutions":[{"claim_hash":"%s","pr":9,"result":"rejected"}]}' "$h" \
    >"$BATS_TEST_TMPDIR/esc.json"
  KNOWLEDGE_NOW=20261019T130000Z run --separate-stderr python3 -I "$KN" apply --root "$PROJ" \
    --plan "$BATS_TEST_TMPDIR/plan.json" --escalations "$BATS_TEST_TMPDIR/esc.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_py "(L[-1]['event'], L[-1]['pr'], L[-1]['result'], L[-1]['claim_hash'] == '$h')")" \
    = "('resolution', 9, 'rejected', True)" ]
  commit_all
  esig agent-b provisional "seen in CI" "claim one"
  commit_all
  plan_json
  [ "$(jq_py "d['signals'][0]['disposition']")" = "repeat-rejected" ]
  run --separate-stderr python3 -I "$KN" check --root "$PROJ"
  [ "$status" -eq 0 ]
}
