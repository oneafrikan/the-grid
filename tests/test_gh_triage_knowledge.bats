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
