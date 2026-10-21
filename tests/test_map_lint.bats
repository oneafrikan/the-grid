#!/usr/bin/env bats
# scripts/map.py --check, knowledge lint scaffold (change `epistemic-enforcement`, spec
# `map-lint`): after the MAP.md drift check it lints signals/ and knowledge/ through
# knowledge.check_tree. Every case runs in a throwaway git repo under the test temp dir.

load helpers/setup

setup() {
  common_setup
  P="$BATS_TEST_TMPDIR/proj"
}

teardown() {
  # A chmod 000 file would make the temp dir cleanup noisy; restore it first.
  chmod -R u+rwX "$P" 2>/dev/null || true
  common_teardown
}

# mk_proj [with-signals] — a temp git repo holding copies of map.py and knowledge.py and a
# current, committed MAP.md. With `with-signals` it also holds one valid pending signal, so
# the lint has something to read. Identity comes from the environment (no address in this
# file) and no user or system git config is read.
mk_proj() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="t@${HOSTNAME:-h}.test" GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL="t@${HOSTNAME:-h}.test" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$P/scripts"
  cp "$REPO_ROOT/scripts/map.py" "$REPO_ROOT/scripts/knowledge.py" "$P/scripts/"
  git -C "$P" init -q
  if [ "${1:-}" = with-signals ]; then
    mkdir -p "$P/signals"
    printf -- '---\nfiled_by: agent-a\nclaim: use the gate\nstage: wip\nwarrant: seen in CI\nstatus: pending\n---\n' \
      > "$P/signals/$SIG"
  fi
  git -C "$P" add -A
  git -C "$P" commit -q -m base
  # MAP.md lists tracked files, so it is generated after the first commit, then committed.
  python3 "$P/scripts/map.py" --root "$P"
  git -C "$P" add -A
  git -C "$P" commit -q -m map
}

SIG=20261018T101500Z-agent-a-abc123.md

# lint — run the check against the fixture; stderr is part of $output.
lint() {
  run python3 "$P/scripts/map.py" --check --root "$P"
}

@test "clean tree: exit 0 and no E_ line" {
  mk_proj with-signals
  lint
  [ "$status" -eq 0 ]
  ! grep -q '^E_' <<<"$output" || false
  [ -z "$output" ]
}

@test "no knowledge.py: one notice, and the exit code is the drift result" {
  mk_proj with-signals
  rm "$P/scripts/knowledge.py"
  lint
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == "map.py: knowledge lint skipped ("*")" ]]
  # A stale MAP.md still fails, with the drift text first and the same single notice.
  printf 'extra\n' >> "$P/MAP.md"
  lint
  [ "$status" -eq 1 ]
  [ "$(grep -c 'knowledge lint skipped' <<<"$output")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | head -n 1)" = "MAP.md is stale" ]
}

@test "neither signals/ nor knowledge/: one notice and exit 0" {
  mk_proj
  lint
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == "map.py: knowledge lint skipped ("*")" ]]
}

@test "an unreadable linted file exits 2 and names the file" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a chmod 000 file"
  mk_proj with-signals
  chmod 000 "$P/signals/$SIG"
  lint
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read signals/$SIG"* ]]
}

@test "a tree with findings: exit 1, findings after drift output, git status unchanged" {
  mk_proj with-signals
  # An unknown stage is a finding; the committed file is not edited, only replaced by a new one.
  printf -- '---\nfiled_by: agent-b\nclaim: a draft\nstage: draft\nwarrant: seen in CI\nstatus: pending\n---\n' \
    > "$P/signals/20261018T101600Z-agent-b-abc124.md"
  git -C "$P" add -A
  git -C "$P" commit -q -m second
  # The signals dir is already tracked, so MAP.md is still current: only the lint speaks.
  before=$(git -C "$P" status --porcelain)
  lint
  after=$(git -C "$P" status --porcelain)
  [ "$status" -eq 1 ]
  [[ "$output" == "E_"*" signals/20261018T101600Z-agent-b-abc124.md: "* ]]
  [ "$before" = "$after" ]
  [ -z "$after" ]
}

# mk_entry <dir> <stage> — write a knowledge entry into knowledge/<dir>/ whose `stage:` line
# says <stage>, whatever the directory, and commit it. The entry is built with
# knowledge.render_entry (so it is otherwise valid), always at stage wip because the renderer
# rejects an unknown stage; the stage line is then rewritten, which is how a draft or a
# misfiled entry gets made. `-I` keeps the caller's PYTHONPATH and cwd out of the import, so
# the path is put on sys.path by hand. Sets ENTRY to the relative path.
mk_entry() {
  ENTRY=$(python3 -I -c '
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import knowledge
claim = "ship the thing"
ident = knowledge.entry_id(claim)
fields = {"id": ident, "claim": claim, "claim_hash": knowledge.claim_hash(claim),
          "stage": "wip", "created": "2026-10-18", "updated": "2026-10-18"}
evidence = [{"signal": "20261018T101500Z-agent-a-abc123.md", "filed_by": "agent-a",
             "stage": "wip", "warrant": "seen in CI"}]
text = knowledge.render_entry(fields, evidence)
text = text.replace("\nstage: wip\n", "\nstage: " + sys.argv[3] + "\n", 1)
rel = "knowledge/%s/%s-%s.md" % (sys.argv[2], ident, knowledge.slug(claim))
path = os.path.join(sys.argv[1], *rel.split("/"))
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
print(rel)
' "$P" "$1" "$2")
  git -C "$P" add -A
  git -C "$P" commit -q -m entry
}

# mk_signal <name> <frontmatter line>… — write a signal with exactly the given frontmatter
# lines and commit it, so nothing in the fixture is an uncommitted edit.
mk_signal() {
  local name=$1
  shift
  mkdir -p "$P/signals"
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n'; } > "$P/signals/$name"
  git -C "$P" add -A
  git -C "$P" commit -q -m signal
}

@test "stage: an entry with an unknown stage gives E_STAGE with its path" {
  mk_proj with-signals
  mk_entry wip draft
  lint
  [ "$status" -eq 1 ]
  grep -q "^E_STAGE $ENTRY: " <<<"$output"
}

@test "stage: canonical in knowledge/established/ gives E_STAGE naming stage and directory" {
  mk_proj with-signals
  mk_entry established canonical
  lint
  [ "$status" -eq 1 ]
  line=$(grep "^E_STAGE $ENTRY: " <<<"$output")
  [[ "$line" == *"stage"* ]]
  [[ "$line" == *"knowledge/canon/"* ]]
}

@test "stage: established in knowledge/canon/ gives E_STAGE" {
  mk_proj with-signals
  mk_entry canon established
  lint
  [ "$status" -eq 1 ]
  grep -q "^E_STAGE $ENTRY: " <<<"$output"
}

@test "signal: proposing canonical gives no E_STAGE line" {
  mk_proj with-signals
  mk_signal 20261018T101700Z-agent-c-abc125.md 'filed_by: agent-c' 'claim: a human-set stage' \
    'stage: canonical' 'warrant: seen in CI' 'status: pending'
  lint
  ! grep -q '^E_STAGE' <<<"$output" || false
}

@test "signal: stage retired gives E_SIGNAL (not claimable) and no E_STAGE" {
  mk_proj with-signals
  mk_signal 20261018T101700Z-agent-c-abc125.md 'filed_by: agent-c' 'claim: a retired claim' \
    'stage: retired' 'warrant: seen in CI' 'status: pending'
  lint
  [ "$status" -eq 1 ]
  line=$(grep '^E_SIGNAL signals/20261018T101700Z-agent-c-abc125.md: ' <<<"$output")
  [[ "$line" == *"not claimable"* ]]
  ! grep -q '^E_STAGE' <<<"$output" || false
}

@test "signal: a missing filed_by gives E_SIGNAL naming the file and the key" {
  mk_proj with-signals
  mk_signal 20261018T101700Z-agent-c-abc125.md 'claim: no filer' 'stage: wip' \
    'warrant: seen in CI' 'status: pending'
  lint
  [ "$status" -eq 1 ]
  grep -q '^E_SIGNAL signals/20261018T101700Z-agent-c-abc125.md: filed_by' <<<"$output"
}

@test "signal: a hand-filed hash6 that is not a content hash gives no E_ line" {
  mk_proj with-signals
  # The hash6 in the name is never recomputed from the content: only history proves immutability.
  mk_signal 20261018T101700Z-agent-c-a1b2c3.md 'filed_by: agent-c' 'claim: filed by hand' \
    'stage: wip' 'warrant: seen in CI' 'status: pending'
  lint
  [ "$status" -eq 0 ]
  ! grep -q '^E_' <<<"$output" || false
}

# edit_sig — change the body of the committed signal. Appending after the closing fence keeps
# the frontmatter valid, so E_EDITED is the only thing that can fire.
edit_sig() {
  printf 'a later remark\n' >> "$P/signals/$SIG"
}

@test "edited: a signal changed in a later commit gives E_EDITED and exit 1" {
  mk_proj with-signals
  edit_sig
  git -C "$P" add -A
  git -C "$P" commit -q -m edit
  lint
  [ "$status" -eq 1 ]
  grep -q "^E_EDITED signals/$SIG: " <<<"$output"
}

@test "edited: a signal changed in the working tree gives E_EDITED and exit 1" {
  mk_proj with-signals
  edit_sig
  lint
  [ "$status" -eq 1 ]
  grep -q "^E_EDITED signals/$SIG: " <<<"$output"
}

@test "edited: a signal changed and staged gives E_EDITED and exit 1" {
  mk_proj with-signals
  edit_sig
  git -C "$P" add signals
  lint
  [ "$status" -eq 1 ]
  grep -q "^E_EDITED signals/$SIG: " <<<"$output"
}

@test "edited: the sweep's move into signals/done/ with a ledger line stays green" {
  mk_proj with-signals
  # A hand-written disposition line carrying every key the ledger requires.
  mkdir -p "$P/signals/done"
  printf '%s\n' '{"event":"disposition","signal":"'"$SIG"'","claim_hash":"h","disposition":"invalid","entry":null,"issue":null,"pr":null,"run":"r1"}' \
    > "$P/signals/done/ledger.jsonl"
  git -C "$P" mv "signals/$SIG" "signals/done/$SIG"
  git -C "$P" add -A
  git -C "$P" commit -q -m sweep
  map_before=$(git -C "$P" hash-object "$P/MAP.md")
  lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # MAP.md is neither stale nor rewritten by the move.
  [ "$map_before" = "$(git -C "$P" hash-object "$P/MAP.md")" ]
  [ -z "$(git -C "$P" status --porcelain)" ]
}

@test "no git: the history check is skipped with one notice and the other rules still apply" {
  mk_proj with-signals
  # A second signal with an unknown stage, so there are two signals and one rule violation.
  mk_signal 20261018T101600Z-agent-b-abc124.md 'filed_by: agent-b' 'claim: a draft' \
    'stage: draft' 'warrant: seen in CI' 'status: pending'
  # Copy the tree without .git; the ceiling stops git finding a repository further up.
  N="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$N"
  cp -R "$P/scripts" "$P/signals" "$P/MAP.md" "$N/"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  run python3 "$N/scripts/map.py" --check --root "$N"
  # Whatever the drift result, the notice shows exactly once, however many signals there are.
  [ "$(grep -c 'signal history check skipped' <<<"$output")" -eq 1 ]
  # The format rule still fires without git.
  grep -q '^E_[A-Z]* signals/20261018T101600Z-agent-b-abc124.md: ' <<<"$output"
  [ "$status" -eq 1 ]
  ! grep -q '^E_EDITED' <<<"$output" || false
}

@test "no git: a clean tree gives one notice and exit 0" {
  mk_proj with-signals
  N="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$N"
  cp -R "$P/scripts" "$P/signals" "$N/"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  # Outside git MAP.md lists the filesystem, so it is generated here rather than copied.
  python3 "$N/scripts/map.py" --root "$N"
  run python3 "$N/scripts/map.py" --check --root "$N"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == "map.py: signal history check skipped ("*")" ]]
}

@test "signal: hand-off files and the README are not reported" {
  mk_proj with-signals
  # Neither is a signal, so neither has frontmatter the lint should read.
  printf 'notes for the tech lead\n' > "$P/signals/→tech-lead.md"
  printf '# Signals\n' > "$P/signals/README.md"
  git -C "$P" add -A
  git -C "$P" commit -q -m handoff
  lint
  [ "$status" -eq 0 ]
  ! grep -q 'tech-lead\|README' <<<"$output" || false
  ! grep -q '^E_' <<<"$output" || false
}
