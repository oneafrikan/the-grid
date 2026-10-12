#!/usr/bin/env bats
# Content checks for rules/terraform and rules/sql (WP-063, records R22a.qa.F14/F15/F16/F17/
# F18): version floors, root-module scope and dialect/origin qualifiers must be in the text.
# grep -F on repo files; the format itself is checked by `rules.py lint`.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

TFSAFE=rules/terraform/safety.md
TFSTYLE=rules/terraform/style.md

@test "terraform/safety: ephemeral and write-only bullet names Terraform 1.10 and 1.11" {
  line=$(bullet_line $TFSAFE 'write-only')
  [[ "$line" == *'1.10'* ]]
  [[ "$line" == *'1.11'* ]]
}

@test "terraform/safety: required_version is a minimum, not a pin" {
  run grep -F 'pin `required_version`' "$REPO_ROOT/$TFSAFE"
  [ "$status" -eq 1 ]
  grep -qF 'minimum Terraform version' "$REPO_ROOT/$TFSAFE"
}

@test "terraform/style: layout is scoped to a root module and split so no line holds main.tf and providers.tf" {
  grep -qF 'In a root module, keep resource and data blocks in `main.tf`' "$REPO_ROOT/$TFSTYLE"
  run grep -E 'main\.tf.*providers\.tf|providers\.tf.*main\.tf' "$REPO_ROOT/$TFSTYLE"
  [ "$status" -eq 1 ]
  grep -qF 'In a root module, put `variable`, `output` and `provider` blocks' "$REPO_ROOT/$TFSTYLE"
}

@test "terraform/README: Scope notes the layout bullets are for a root module" {
  grep -qF 'root module' "$REPO_ROOT/rules/terraform/README.md"
}

@test "sql/safety: the MERGE bullet names BigQuery" {
  line=$(bullet_line rules/sql/safety.md 'MERGE')
  [[ "$line" == *'- In BigQuery, make the `MERGE` source unique'* ]]
}

@test "sql/style: the aggregation bullet is attributed to the dbt Labs style guide, not stated as universal" {
  grep -qF 'dbt Labs style guide' "$REPO_ROOT/rules/sql/style.md"
  run grep -F -- '- Aggregate on the smallest' "$REPO_ROOT/rules/sql/style.md"
  [ "$status" -eq 1 ]
}

@test "sql/README: bullets naming BigQuery apply to that dialect only, though the pack loads on all .sql" {
  grep -qF 'apply to that dialect only' "$REPO_ROOT/rules/sql/README.md"
}

@test "terraform and sql: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets terraform sql)" ]
}
