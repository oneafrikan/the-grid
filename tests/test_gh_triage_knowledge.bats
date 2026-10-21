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

# sweep_fixture — a bare origin plus a checkout of it with two signals committed and pushed.
# Sets ORIGIN, CHECKOUT, SWEEP_TMP (plan/verdicts live there: Step 6 keeps them OUTSIDE the
# checkout) and GRID_RUN_RECORD; GRID_RUN_LOG is already a temp path from common_setup.
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
    --claim "retries are capped at three" --stage provisional --warrant "seen in CI" >/dev/null
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

# sweep_run <org/repo> <checkout> [cap] — one sweep of one repo, Step 6 items 1 to 6.
sweep_run() {
  SWEEP_TARGET="$1"
  local checkout="$2" cap="${3:-10}"
  local plan="$SWEEP_TMP/plan.json" verdicts="$SWEEP_TMP/verdicts.json"
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
  # next issue: Steps 2 to 5 (judge, escalate, reconcile, apply, commit, push) and the final
  # record. Verdicts are ready so that issue only adds the writing steps.
  sweep_canned_verdicts "$plan" "$verdicts"
  echo "sweep_run: writing steps not built yet" >&2
  return 1
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
