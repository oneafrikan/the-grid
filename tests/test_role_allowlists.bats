#!/usr/bin/env bats
# WP-070: recommend-only roles carry a `tools:` allowlist, and the shared decision-brief
# fragment cannot override a role's own approval rule. Text checks only (no venv, no model).
#
# Roles deliberately left WITHOUT an allowlist, with the reason (see the PR for WP-070):
#   finance-analyst, seo, researcher, paid-search, paid-social: their documented hand-off
#     (append to signals/<agent>.md, or open a PR) needs a write or shell tool the planned
#     read-only set omits.
#   librarian: ingest moves an inbox file to sources/, which needs a shell.
#   gh-triage: optional Slack ingestion needs a Slack tool an allowlist cannot name.
# Implementer roles are unchanged by decision (D19). tank keeps Write and Bash.

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
