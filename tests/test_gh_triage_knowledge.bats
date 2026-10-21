#!/usr/bin/env bats
# The gh-triage scope template carries the knowledge sweep contract, and it is off by default.

load helpers/setup
load helpers/stubs

setup() {
  common_setup
  TMPL="$REPO_ROOT/agent-factory/roles/gh-triage/deployment-scope.template.md"
}

teardown() {
  clean_stubs
  common_teardown
}

# section — the text from the `## Knowledge sweep` heading up to the next `## ` heading.
section() {
  awk '/^## Knowledge sweep$/ {on=1; next} /^## / {on=0} on' "$TMPL"
}

@test "scope template has a Knowledge sweep section, off by default, with the four-column table" {
  grep -qx '## Knowledge sweep' "$TMPL"
  # enabled: false must sit inside the section, not just anywhere (the Slack section has one too).
  section | grep -qx 'enabled: false'
  section | grep -qF '| Repo | Checkout path | Sweep branch | Cap |'
  section | grep -q 'dedicated'
}

# The SKILL carries the sweep procedure; the must-never rules are explicit imperative blocks.
@test "gh-triage SKILL has the knowledge sweep step with its safety rules" {
  skill="$REPO_ROOT/agent-factory/roles/gh-triage/SKILL.md"
  grep -qE '^## Step 6 — Knowledge sweep' "$skill"
  # Skipped when the scope does not enable it.
  grep -qF 'enabled: false' "$skill"
  # First-run preview rule, stated as its own block.
  grep -qF 'FIRST RUN WRITES NOTHING' "$skill"
  grep -qF 'record outcome `skipped`' "$skill"
  grep -qF 'NEVER merge, auto-merge, close, or edit canon' "$skill"
  # `gh pr merge` may only appear on a line that forbids it.
  [ "$(grep -cF 'gh pr merge' "$skill")" -ge 1 ]
  ! grep -F 'gh pr merge' "$skill" | grep -viq 'never' || false
  # The helper subcommands and the PR / commit wording the design fixes.
  grep -qF -- '--proposal-for' "$skill"
  grep -qF 'Refs #<issue>' "$skill"
  grep -qF 'knowledge-sweep: N signals' "$skill"
  # The idempotency marker is spelled out: a literal HTML comment would be stripped on compose.
  grep -qF 'knowledge-signal: <claim_hash>' "$skill"
}

# AGENTS.md carries the sweep scope and its widened channel; the role-authoring size cap still holds.
@test "gh-triage AGENTS.md declares the sweep, keeps its hard rules, and stays under 4096 bytes" {
  agents="$REPO_ROOT/agent-factory/roles/gh-triage/AGENTS.md"
  [ "$(wc -c < "$agents")" -lt 4096 ]
  # map.py has_sweep() keys on this exact heading.
  grep -qx '## Knowledge sweep' "$agents"
  grep -qF 'SAFE TARGET FIRST' "$agents"
  grep -qF 'RUN RECORD' "$agents"
  grep -qF 'gh pr merge' "$agents"
  grep -F 'SINGLE OUTWARD CHANNEL' "$agents" | grep -qF 'knowledge/'
}

@test "gh-triage role.yaml tools line is unchanged by the sweep" {
  grep -qxF 'tools: [Read, Grep, Glob, Bash, Write]' "$REPO_ROOT/agent-factory/roles/gh-triage/role.yaml"
}

# ---- sweep_run: SKILL Step 6 replayed against a fixture repo --------------------------------
# The SKILL is prose for a model, so a test cannot run it. This helper replays its documented
# shell steps in order with the stub `gh`, the real scripts/knowledge.py and the real
# scripts/run-record.sh; the model's judgement is a canned verdicts file (no / none).

# git identity from the environment (no address in this file) and no user/system git config.
sweep_git_env() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL=t@example.com GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
}

# sweep_fixture [stage] — a bare origin plus a checkout of it with two signals committed and
# pushed: a warranted provisional one, and a second one at <stage> (default provisional).
# Sets ORIGIN, CHECKOUT, SWEEP_TMP (each run's plan/verdicts live in a dir under it: Step 6
# keeps them OUTSIDE the checkout) and GRID_RUN_RECORD; GRID_RUN_LOG is already a temp path
# from common_setup.
sweep_fixture() {
  sweep_git_env
  make_stubs
  export STUB_REPO=acme/widgets
  export GRID_RUN_RECORD="$REPO_ROOT/scripts/run-record.sh"
  KN="$REPO_ROOT/scripts/knowledge.py"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  SWEEP_TMP="$BATS_TEST_TMPDIR/sweep"
  mkdir -p "$SWEEP_TMP"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$CHECKOUT"
  git -C "$CHECKOUT" remote add origin "$ORIGIN"
  echo "fixture" > "$CHECKOUT/README.md"
  git -C "$CHECKOUT" add -A
  git -C "$CHECKOUT" commit -q -m base
  # KNOWLEDGE_NOW pins the file names, so the fixture is the same on every run.
  KNOWLEDGE_NOW=20261018T100001Z python3 -I "$KN" file --root "$CHECKOUT" --filer agent-a \
    --claim "the cache is cleared on deploy" --stage provisional --warrant "seen in CI" >/dev/null
  KNOWLEDGE_NOW=20261018T100002Z python3 -I "$KN" file --root "$CHECKOUT" --filer agent-a \
    --claim "retries are capped at three" --stage "${1:-provisional}" --warrant "seen in CI" >/dev/null
  git -C "$CHECKOUT" add -A
  git -C "$CHECKOUT" commit -q -m signals
  # -u so a later `git pull --ff-only` knows its upstream, as in a real checkout.
  git -C "$CHECKOUT" push -q -u origin HEAD 2>/dev/null
}

# sweep_record <outcome> <note> — Step 6 "Record": one run-record line for the target.
sweep_record() {
  "$GRID_RUN_RECORD" --role gh-triage --action knowledge-sweep --target "$SWEEP_TARGET" \
    --outcome "$1" --note "$2"
}

# sweep_counts <plan file> — the plan counts as a note, e.g. `written=2 deferred=0`.
sweep_counts() {
  python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
parts = ["%s=%s" % (k, v) for k, v in sorted(p["counts"].items())]
parts.append("deferred=%d" % p["deferred"])
print(" ".join(parts))' "$1"
}

# sweep_has_earlier_line — true when the run log already holds a knowledge-sweep line for the
# target (a `skipped` line counts, per the SKILL).
sweep_has_earlier_line() {
  [ -f "$GRID_RUN_LOG" ] || return 1
  python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["action"] == "knowledge-sweep" and r["target"] == sys.argv[2]:
        sys.exit(0)
sys.exit(1)' "$GRID_RUN_LOG" "$SWEEP_TARGET"
}

# sweep_canned_verdicts <plan file> <out file> — Step 6 "Judge" with the model replaced: every
# word the plan asks for is answered `no` (guardrail) or `none` (canon).
sweep_canned_verdicts() {
  python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
v = {}
for s in p["signals"]:
    for word in s["needs_judgement"]:
        v.setdefault(s["file"], {})[word] = "no" if word == "guardrail" else "none"
json.dump(v, open(sys.argv[2], "w"))' "$1" "$2"
}

# sweep_escalations <plan> <verdicts> — Step 6 item 3, which signals escalate: every `escalated`
# or `secret` item, plus every item a verdict turned into an escalation. One tab-separated line
# each: file, claim_hash ("-" for a secret, which has none), disposition, severity, reason.
# `plan` already lists at most 3 escalated signals and leaves the rest pending, so no further cap
# is applied here.
sweep_escalations() {
  python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
v = json.load(open(sys.argv[2]))
clear = {"guardrail": "no", "canon": "none"}
for s in p["signals"]:
    disp, reason = s["disposition"], ",".join(s["reasons"])
    if disp in ("wip", "written", "confirmed") and not all(
            v.get(s["file"], {}).get(w) == clear[w] for w in s["needs_judgement"]):
        disp, reason = "escalated", "verdict"
    if disp not in ("escalated", "secret"):
        continue
    # medium for a contradiction, a guardrail conflict or a secret; low otherwise.
    sev = "medium" if disp == "secret" or reason in ("contradicts", "verdict") else "low"
    print("\t".join([s["file"], s["claim_hash"] or "-", disp, sev, reason]))' "$1" "$2"
}

# sweep_issue_body <signal path> <disposition> <reason> <marker> — the issue body. A secret names
# the file and the pattern only, never the signal text.
sweep_issue_body() {
  python3 -I -c '
import sys
path, disp, reason, marker = sys.argv[1:5]
name = path.rsplit("/", 1)[-1]
if disp == "secret":
    print("Signal file signals/%s holds a token-shaped value (pattern: %s).\n" % (name, reason))
    print("Rotate the credential and scrub history.")
else:
    fm = {}
    for line in open(path).read().split("\n")[1:]:
        if line == "---":
            break
        key, _, value = line.partition(": ")
        fm[key] = value
    print("Claim: %s" % fm.get("claim"))
    print("Warrant: %s" % fm.get("warrant"))
    print("Filed by: %s" % fm.get("filed_by"))
    print("Stage claimed: %s" % fm.get("stage"))
    print("Why escalated: %s" % reason)
    print("Signal: signals/%s" % name)
print("")
print(marker)' "$1" "$2" "$3" "$4"
}

# sweep_escalate <checkout> <branch> <file> <claim_hash> <disposition> <severity> <reason> —
# Step 6 item 3 for one signal: find or create the issue, then (not for a secret) the PR.
# Appends `file<TAB>issue<TAB>pr` to $SWEEP_WORK/numbers.tsv.
sweep_escalate() {
  local checkout="$1" branch="$2" file="$3" chash="$4" disp="$5" sev="$6" reason="$7"
  local key="$chash" kid issue pr="" url labels wt body rc=0
  # A secret has no claim_hash: the signal file name keys the marker instead.
  if [ "$chash" = "-" ]; then key="$file"; fi
  kid="K-${chash:0:8}"
  if [ "$chash" = "-" ]; then kid="$file"; fi
  local marker="<!-- knowledge-signal: $key -->"
  # Idempotency: an issue that already carries the exact marker is reused, closed ones included.
  issue="$(gh issue list --repo "$SWEEP_TARGET" --state all \
    --search "\"knowledge-signal: $key\" in:body" --json number,body | python3 -I -c '
import json, sys
try:
    items = json.load(sys.stdin)
except ValueError:
    items = []
for item in items if isinstance(items, list) else []:
    if sys.argv[1] in item.get("body", ""):
        print(item["number"])
        break' "$marker")"
  if [ -z "$issue" ]; then
    # The label must exist before the first issue that uses it.
    labels="$(gh label list --repo "$SWEEP_TARGET" --json name)"
    case "$labels" in *'"knowledge"'*) ;; *) gh label create knowledge --repo "$SWEEP_TARGET" >/dev/null ;; esac
    body="$SWEEP_WORK/issue-$file.body"
    sweep_issue_body "$checkout/signals/$file" "$disp" "$reason" "$marker" > "$body"
    url="$(gh issue create --repo "$SWEEP_TARGET" --title "Knowledge signal needs review: $kid" \
      --label knowledge --label ready-for-human --label "severity:$sev" --body-file "$body")"
    issue="${url##*/}"
  fi
  if [ "$disp" != "secret" ]; then
    # The proposal is cut in a temp worktree from the sweep branch, so the sweep branch itself
    # never gains the change. One && chain so the cleanup below runs pass or fail.
    wt="$SWEEP_WORK/wt-$kid"
    git -C "$checkout" worktree add -q -b "knowledge/$kid" "$wt" "$branch" \
      && python3 -I "$KN" apply --proposal-for "$file" --root "$wt" \
      && git -C "$wt" add knowledge \
      && git -C "$wt" commit -q -m "knowledge-sweep: proposal for $kid" \
      && git -C "$wt" push -q origin "knowledge/$kid" || rc=$?
    git -C "$checkout" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$checkout" worktree prune
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    printf 'Proposed change for the escalated signal.\n\nRefs #%s\n' "$issue" > "$SWEEP_WORK/pr-$kid.body"
    url="$(gh pr create --repo "$SWEEP_TARGET" --base "$branch" --head "knowledge/$kid" \
      --title "Knowledge proposal $kid" --body-file "$SWEEP_WORK/pr-$kid.body")"
    pr="${url##*/}"
  fi
  printf '%s\t%s\t%s\n' "$file" "$issue" "${pr:-null}" >> "$SWEEP_WORK/numbers.tsv"
}

# sweep_reconcile <plan> — Step 6 item 4: one `gh pr view` per open escalation (read-only), and
# `claim_hash<TAB>pr<TAB>accepted|rejected` into $SWEEP_WORK/resolutions.tsv for a decided one.
# A still-open PR adds nothing.
sweep_reconcile() {
  local chash pr issue state result labels
  python3 -I -c '
import json, sys
for r in json.load(open(sys.argv[1]))["reconcile"]:
    if r["pr"]:
        print("%s\t%s\t%s" % (r["claim_hash"], r["pr"], r["issue"] or "-"))' "$1" > "$SWEEP_WORK/reconcile.tsv"
  while IFS=$'\t' read -r chash pr issue <&3; do
    state="$(gh pr view "$pr" --repo "$SWEEP_TARGET" --json state,mergedAt)"
    result="$(python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
print("accepted" if d.get("mergedAt") or d.get("state") == "MERGED" else
      "rejected" if d.get("state") == "CLOSED" else "")' "$state")"
    if [ -z "$result" ] && [ "$issue" != "-" ]; then
      # Still open: a wontfix label on the issue also settles it.
      labels="$(gh issue view "$issue" --repo "$SWEEP_TARGET" --json labels)"
      case "$labels" in *'"wontfix"'*) result=rejected ;; esac
    fi
    if [ -n "$result" ]; then printf '%s\t%s\t%s\n' "$chash" "$pr" "$result" >> "$SWEEP_WORK/resolutions.tsv"; fi
  done 3< "$SWEEP_WORK/reconcile.tsv"
}

# sweep_run <org/repo> <checkout> [cap] [sweep branch] — one sweep of one repo, Step 6 items 1
# to 6. Each call works in a fresh dir, SWEEP_WORK, so a test can tell what THIS run wrote.
sweep_run() {
  SWEEP_TARGET="$1"
  local checkout="$2" cap="${3:-10}" branch="${4:-main}"
  SWEEP_WORK="$(mktemp -d "$SWEEP_TMP/run.XXXXXX")"
  local plan="$SWEEP_WORK/plan.json" verdicts="$SWEEP_WORK/verdicts.json" esc="$SWEEP_WORK/escalations.json"
  local n_signals file chash disp sev reason out rc=0 vargs=()
  : > "$SWEEP_WORK/numbers.tsv"
  : > "$SWEEP_WORK/resolutions.tsv"
  # 1. Prepare: a dirty tree is recorded `stopped` and the repo is left alone.
  if [ -n "$(git -C "$checkout" status --porcelain)" ]; then
    sweep_record stopped "dirty tree"
    return 0
  fi
  git -C "$checkout" pull -q --ff-only 2>/dev/null
  python3 -I "$KN" plan --root "$checkout" --cap "$cap" > "$plan"
  # FIRST RUN WRITES NOTHING: with no earlier knowledge-sweep line, record `skipped` with the
  # plan counts and stop. No commit, no push, no gh write, no model call.
  if ! sweep_has_earlier_line; then
    sweep_record skipped "$(sweep_counts "$plan")"
    return 0
  fi
  n_signals="$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["signals"]))' "$plan")"
  # 2. Judge: only a plan with signals asks the model anything, so an empty queue requests no
  # verdicts at all (no verdicts file is written).
  if [ "$n_signals" -gt 0 ]; then sweep_canned_verdicts "$plan" "$verdicts"; fi
  # 3. Escalate. A failure here stops the repo with nothing applied.
  if [ "$n_signals" -gt 0 ]; then
    sweep_escalations "$plan" "$verdicts" > "$SWEEP_WORK/escalate.tsv"
    # fd 3, so nothing run inside the loop can eat the list from stdin.
    while IFS=$'\t' read -r file chash disp sev reason <&3; do
      sweep_escalate "$checkout" "$branch" "$file" "$chash" "$disp" "$sev" "$reason" || rc=$?
    done 3< "$SWEEP_WORK/escalate.tsv"
    if [ "$rc" -ne 0 ]; then
      sweep_record error "escalation failed"
      return 0
    fi
  fi
  # 4. Reconcile.
  sweep_reconcile "$plan"
  # Nothing pending and nothing decided: no apply, no commit, no push. The spec records this as
  # `skipped` (SKILL Step 1 says `ok` for the empty case; the spec and the issue win here).
  if [ "$n_signals" -eq 0 ] && [ ! -s "$SWEEP_WORK/resolutions.tsv" ]; then
    sweep_record skipped "$(sweep_counts "$plan")"
    return 0
  fi
  python3 -I -c '
import json, sys
out = {}
for line in open(sys.argv[1]):
    f, issue, pr = line.rstrip("\n").split("\t")
    out[f] = {"issue": int(issue), "pr": None if pr == "null" else int(pr)}
res = [dict(zip(("claim_hash", "pr", "result"), l.rstrip("\n").split("\t"))) for l in open(sys.argv[2])]
for r in res:
    r["pr"] = int(r["pr"])
if res:
    out["resolutions"] = res
json.dump(out, open(sys.argv[3], "w"))' "$SWEEP_WORK/numbers.tsv" "$SWEEP_WORK/resolutions.tsv" "$esc"
  # 5. Apply, then one commit and one push. A failed apply changes nothing else.
  if [ -f "$verdicts" ]; then vargs=(--verdicts "$verdicts"); fi
  out="$(python3 -I "$KN" apply --root "$checkout" --plan "$plan" "${vargs[@]}" --escalations "$esc" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    sweep_record error "apply failed: $out"
    return 0
  fi
  git -C "$checkout" add knowledge signals
  git -C "$checkout" commit -q -m "knowledge-sweep: $n_signals signals"
  if ! git -C "$checkout" push -q origin "$branch" 2>"$SWEEP_WORK/push.err"; then
    # Rejected: rebase once and push once more; still rejected means reset and write nothing.
    git -C "$checkout" pull -q --rebase origin "$branch" 2>/dev/null || git -C "$checkout" rebase --abort 2>/dev/null || true
    if ! git -C "$checkout" push -q origin "$branch" 2>>"$SWEEP_WORK/push.err"; then
      git -C "$checkout" reset -q --hard "origin/$branch"
      sweep_record error "push rejected: $(cat "$SWEEP_WORK/push.err")"
      return 0
    fi
  fi
  # 6. Record.
  sweep_record ok "$(sweep_counts "$plan")"
}

@test "knowledge sweep: first run on a repo only previews, writes nothing and records one skipped line" {
  sweep_fixture
  local head_before origin_before
  head_before="$(git -C "$CHECKOUT" rev-parse HEAD)"
  origin_before="$(git --git-dir="$ORIGIN" rev-parse HEAD)"
  : > "$STUB_LOG"

  sweep_run acme/widgets "$CHECKOUT"

  # Nothing written: clean tree, no new commit locally or on origin, no entry, nothing archived.
  [ -z "$(git -C "$CHECKOUT" status --porcelain)" ]
  [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$head_before" ]
  [ "$(git --git-dir="$ORIGIN" rev-parse HEAD)" = "$origin_before" ]
  [ ! -e "$CHECKOUT/knowledge" ]
  [ ! -e "$CHECKOUT/signals/done" ]

  # Exactly one run-record line: outcome skipped, the plan counts in the note.
  [ "$(wc -l < "$GRID_RUN_LOG")" -eq 1 ]
  line="$(cat "$GRID_RUN_LOG")"
  contains "$line" '"action": "knowledge-sweep"'
  contains "$line" '"target": "acme/widgets"'
  contains "$line" '"outcome": "skipped"'
  contains "$line" '"note": "written=2 deferred=0"'

  # No write-type gh call, and no model call.
  calls="$(cat "$STUB_LOG")"
  lacks "$calls" 'gh issue create'
  lacks "$calls" 'gh pr create'
  lacks "$calls" 'gh pr merge'
  lacks "$calls" 'gh label create'
  lacks "$calls" 'gh issue edit'
  lacks "$calls" 'claude'
}

# gh_write_calls — the write-type gh calls in STUB_LOG: issue create / edit / close / comment,
# pr create / merge / comment, label create. Empty output means gh was only read from.
gh_write_calls() {
  awk '$1 == "gh" && (($2 == "issue" && $3 ~ /^(create|edit|close|comment)$/) ||
    ($2 == "pr" && $3 ~ /^(create|merge|comment)$/) || ($2 == "label" && $3 == "create"))' "$STUB_LOG"
}

@test "knowledge sweep: second run writes one entry, opens one issue and one PR, makes one commit and never merges" {
  sweep_fixture canonical
  # First run only previews: it leaves the earlier knowledge-sweep line the second run needs.
  sweep_run acme/widgets "$CHECKOUT"
  local base
  base="$(git -C "$CHECKOUT" rev-parse HEAD)"
  : > "$STUB_LOG"

  sweep_run acme/widgets "$CHECKOUT"

  # The provisional signal became an entry; canon on the sweep branch is untouched.
  [ "$(ls "$CHECKOUT/knowledge/provisional" | wc -l)" -eq 1 ]
  [ ! -e "$CHECKOUT/knowledge/canon" ] || [ -z "$(ls "$CHECKOUT/knowledge/canon")" ]
  # Both signals are archived, none is pending.
  [ "$(ls "$CHECKOUT/signals/done"/*.md | wc -l)" -eq 2 ]
  [ -z "$(find "$CHECKOUT/signals" -maxdepth 1 -name '*.md')" ]

  # Ledger: two dispositions; the escalated one carries the stub issue and PR numbers.
  ledger="$CHECKOUT/signals/done/ledger.jsonl"
  [ "$(grep -cF '"event":"disposition"' "$ledger")" -eq 2 ]
  esc_line="$(grep -F '"disposition":"escalated"' "$ledger")"
  contains "$esc_line" '"issue":201'
  contains "$esc_line" '"pr":101'
  contains "$(grep -F '"disposition":"written"' "$ledger")" '"issue":null'

  # Exactly one new commit, with the fixed message, and origin has it.
  [ "$(git -C "$CHECKOUT" rev-list --count "$base"..HEAD)" -eq 1 ]
  [ "$(git -C "$CHECKOUT" log -1 --format=%s)" = "knowledge-sweep: 2 signals" ]
  [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$(git -C "$CHECKOUT" rev-parse HEAD)" ]
  [ -z "$(git -C "$CHECKOUT" status --porcelain)" ]

  # The escalation branch is on origin and carries the canon proposal; the sweep branch does not.
  K="K-$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(" ".join(sys.argv[1].casefold().split()).encode()).hexdigest()[:8])' "retries are capped at three")"
  git --git-dir="$ORIGIN" rev-parse --verify -q "refs/heads/knowledge/$K"
  contains "$(git --git-dir="$ORIGIN" ls-tree -r --name-only "knowledge/$K")" 'knowledge/canon/'
  lacks "$(git --git-dir="$ORIGIN" ls-tree -r --name-only main)" 'knowledge/canon/'
  # The temp worktree was removed.
  [ "$(git -C "$CHECKOUT" worktree list | wc -l)" -eq 1 ]

  # gh: one issue, one PR (Refs the issue), never a merge.
  calls="$(cat "$STUB_LOG")"
  [ "$(grep -c '^gh issue create' "$STUB_LOG")" -eq 1 ]
  [ "$(grep -c '^gh pr create' "$STUB_LOG")" -eq 1 ]
  contains "$calls" '--label knowledge --label ready-for-human --label severity:low'
  contains "$calls" "--head knowledge/$K"
  lacks "$calls" 'gh pr merge'
  lacks "$calls" '--auto'
  contains "$(cat "$STUB_DIR/pr-create.body")" 'Refs #201'

  # Run record: the skipped preview, then one ok line with the counts.
  [ "$(wc -l < "$GRID_RUN_LOG")" -eq 2 ]
  last="$(tail -n 1 "$GRID_RUN_LOG")"
  contains "$last" '"outcome": "ok"'
  contains "$last" '"note": "escalated=1 written=1 deferred=0"'
}

@test "knowledge sweep: third run on the state the second left changes nothing and only reads from gh" {
  sweep_fixture canonical
  sweep_run acme/widgets "$CHECKOUT"
  sweep_run acme/widgets "$CHECKOUT"
  local head_before origin_before log_before
  head_before="$(git -C "$CHECKOUT" rev-parse HEAD)"
  origin_before="$(git --git-dir="$ORIGIN" rev-parse HEAD)"
  log_before="$(git -C "$CHECKOUT" log --format=%H | wc -l)"
  : > "$STUB_LOG"

  sweep_run acme/widgets "$CHECKOUT"

  # No new commit locally or on origin, clean tree.
  [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$head_before" ]
  [ "$(git --git-dir="$ORIGIN" rev-parse HEAD)" = "$origin_before" ]
  [ "$(git -C "$CHECKOUT" log --format=%H | wc -l)" -eq "$log_before" ]
  [ -z "$(git -C "$CHECKOUT" status --porcelain)" ]

  # No write-type gh call. The open escalation's PR was only read (reconcile).
  [ -z "$(gh_write_calls)" ]
  contains "$(cat "$STUB_LOG")" 'gh pr view 101'

  # No verdicts requested (the model would have been asked), and a skipped record.
  [ ! -e "$SWEEP_WORK/verdicts.json" ]
  lacks "$(cat "$STUB_LOG")" 'claude'
  last="$(tail -n 1 "$GRID_RUN_LOG")"
  contains "$last" '"outcome": "skipped"'
  [ "$(wc -l < "$GRID_RUN_LOG")" -eq 3 ]
}
