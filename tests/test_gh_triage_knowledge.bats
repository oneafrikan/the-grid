#!/usr/bin/env bats
# The gh-triage scope template carries the knowledge sweep contract, and it is off by default.

load helpers/setup

setup() {
  common_setup
  TMPL="$REPO_ROOT/agent-factory/roles/gh-triage/deployment-scope.template.md"
}

teardown() {
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

@test "gh-triage role.yaml tools line is unchanged by the sweep" {
  grep -qxF 'tools: [Read, Grep, Glob, Bash, Write]' "$REPO_ROOT/agent-factory/roles/gh-triage/role.yaml"
}
