#!/usr/bin/env bats
# WP-070: recommend-only roles carry a `tools:` allowlist, and the shared decision-brief
# fragment cannot override a role's own approval rule. Text checks only (no venv, no model).
#
# H-04 narrowed the seven roles WP-070 left open (finance-analyst, seo, researcher, paid-search,
# paid-social, librarian, gh-triage). Each now carries the smallest allowlist its documented
# work needs; the exact lists are pinned below. `tools:` cannot name MCP tools, so a Slack tool
# is never in any list. Implementer roles are unchanged by decision (D19). tank keeps Write
# and Bash.

load helpers/setup

setup() {
  common_setup
  ROLES="$REPO_ROOT/agent-factory/roles"
  BRIEF="$REPO_ROOT/agent-factory/_core/DECISION_BRIEF.md"
}

teardown() {
  common_teardown
}

# tools_of <role> — the role.yaml `tools:` line, or empty
tools_of() {
  grep -E '^tools:' "$ROLES/$1/role.yaml" || true
}

@test "every planned recommend-only role has a tools allowlist" {
  local r
  for r in finance-sentinel data-analyst finance-scribe product-manager project-manager \
           designer copywriter ad-copy technical-writer; do
    [ -n "$(tools_of "$r")" ] || { echo "no tools: line in $r/role.yaml"; false; }
  done
}

@test "finance-sentinel (untrusted feeds) can run scripts but never edit or write" {
  local t; t="$(tools_of finance-sentinel)"
  [[ "$t" == *"Bash"* ]]
  [[ "$t" != *"Edit"* ]]
  [[ "$t" != *"Write"* ]]
  [[ "$t" != *"WebFetch"* ]]
}

@test "no recommend-only role other than technical-writer gets Bash with Edit or Write" {
  local r t
  for r in data-analyst finance-scribe product-manager project-manager designer copywriter ad-copy; do
    t="$(tools_of "$r")"
    if [[ "$t" == *"Bash"* ]]; then [[ "$t" != *"Write"* && "$t" != *"Edit"* ]]; fi
  done
  # technical-writer must run commands to verify its claims, so it keeps Bash.
  [[ "$(tools_of technical-writer)" == *"Bash"* ]]
}

@test "role.yaml allowlists use only known tool names, as a flow list on one line" {
  local r name
  for r in finance-sentinel data-analyst finance-scribe product-manager project-manager \
           designer copywriter ad-copy technical-writer; do
    # shellcheck disable=SC2001  # sed is clearer than ${//} for the bracket strip
    for name in $(tools_of "$r" | sed 's/^tools: *\[//; s/\].*//; s/,/ /g'); do
      case "$name" in Read|Grep|Glob|Bash|Edit|Write|WebFetch|WebSearch) ;; *) echo "$r: $name"; false ;; esac
    done
  done
}

@test "the decision brief says a role's own never-auto-approve rule overrides unattended mode" {
  grep -qF "A role's own never-auto-approve or approval-queue rule overrides this." "$BRIEF"
  # Still inside the 1500-byte cap compose.py --lint-roles enforces.
  [ "$(wc -c < "$BRIEF")" -le 1500 ]
}

@test "the composed persona for finance-manager carries the precedence line" {
  grep -qF "never-auto-approve or approval-queue rule overrides this" "$REPO_ROOT/dist/personas/finance-manager.md"
  # ... and still carries its own rule it points at.
  grep -qiE "never.*auto-approve" "$REPO_ROOT/dist/personas/finance-manager.md"
}

# H-04: the seven formerly open roles. Exact list per role, in role.yaml order, so a drift in
# either direction (a tool added back, or one dropped that the docs still rely on) fails.
@test "H-04: each narrowed role carries exactly its approved tools allowlist" {
  [ "$(tools_of gh-triage)"       = "tools: [Read, Grep, Glob, Bash, Write]" ]
  [ "$(tools_of researcher)"      = "tools: [Read, Grep, Glob, WebFetch, WebSearch, Write]" ]
  [ "$(tools_of seo)"             = "tools: [Read, Grep, Glob, WebFetch, WebSearch, Write]" ]
  [ "$(tools_of librarian)"       = "tools: [Read, Grep, Glob, Write, Edit, Bash]" ]
  [ "$(tools_of paid-search)"     = "tools: [Read, Grep, Glob, WebFetch, WebSearch, Write]" ]
  [ "$(tools_of paid-social)"     = "tools: [Read, Grep, Glob, WebFetch, WebSearch, Write]" ]
  [ "$(tools_of finance-analyst)" = "tools: [Read, Grep, Glob, WebFetch, WebSearch, Write]" ]
}

@test "H-04: roles that read untrusted web content never get Bash or Edit" {
  local r t
  for r in researcher seo paid-search paid-social finance-analyst; do
    t="$(tools_of "$r")"
    [[ "$t" == *"WebFetch"* ]]
    [[ "$t" != *"Bash"* ]]
    [[ "$t" != *"Edit"* ]]
  done
}

@test "H-04: the narrowed allowlists use only known tool names" {
  local r name
  for r in gh-triage researcher seo librarian paid-search paid-social finance-analyst; do
    # shellcheck disable=SC2001  # sed is clearer than ${//} for the bracket strip
    for name in $(tools_of "$r" | sed 's/^tools: *\[//; s/\].*//; s/,/ /g'); do
      case "$name" in Read|Grep|Glob|Bash|Edit|Write|WebFetch|WebSearch) ;; *) echo "$r: $name"; false ;; esac
    done
  done
}

@test "H-04: gh-triage Step 1 reads messages from files named in the scope, not from Slack" {
  local skill="$ROLES/gh-triage/SKILL.md" tmpl="$ROLES/gh-triage/deployment-scope.template.md"
  # No instruction to poll a channel: the role has no Slack tool and `tools:` cannot grant one.
  # (`if` form: a bare `! cmd` does not fail a bats test unless it is the last line)
  if grep -qi 'poll the channel' "$skill"; then echo "Step 1 still says to poll the channel"; false; fi
  # The scope file names where the messages and the last-run timestamp live.
  grep -q 'messages-file' "$skill"
  grep -q 'last-run-file' "$skill"
  grep -q 'messages-file' "$tmpl"
  grep -q 'last-run-file' "$tmpl"
}

@test "H-04: the narrowed roles' docs do not tell them to open a PR (no Bash) where Bash is withheld" {
  local r
  for r in researcher seo paid-search paid-social; do
    if grep -qE 'PR / `signals' "$ROLES/$r/AGENTS.md"; then echo "$r still offers a PR hand-off"; false; fi
  done
}

@test "H-04: shipped plugin agents for the narrowed roles carry the matching tools line" {
  grep -qx 'tools: Read, Grep, Glob, Bash, Write' "$REPO_ROOT/plugins/grid-core/agents/core-gh-triage.md"
  grep -qx 'tools: Read, Grep, Glob, WebFetch, WebSearch, Write' "$REPO_ROOT/plugins/grid-core/agents/core-researcher.md"
  grep -qx 'tools: Read, Grep, Glob, Write, Edit, Bash' "$REPO_ROOT/plugins/grid-core/agents/core-librarian.md"
  local a
  for a in grid-seo grid-paid-search grid-paid-social; do
    grep -qx 'tools: Read, Grep, Glob, WebFetch, WebSearch, Write' "$REPO_ROOT/plugins/grid-agents/agents/$a.md"
  done
}
