#!/usr/bin/env bats
# Content checks for rules/dbt (WP-062, records R22a.qa.F3/F4/F10/F11/F12/F13/F19): version
# floors, source-faithful wording, and the README's account of what the globs load on.
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

TESTS=rules/dbt/schema-tests.md
MODELS=rules/dbt/models.md
PROJECT=rules/dbt/project.md
README=rules/dbt/README.md

@test "dbt/schema-tests: the arguments: bullet names dbt 1.10.5 and the older and v2 forms" {
  line=$(bullet_line $TESTS 'arguments:')
  [[ "$line" == *'1.10.5'* ]]
  [[ "$line" == *'older versions use top-level properties'* ]]
  [[ "$line" == *'v2 requires'* ]]
}

@test "dbt/schema-tests: the data_tests: bullet says older dbt needs tests:" {
  grep -qF 'older dbt versions need `tests:`' "$REPO_ROOT/$TESTS"
}

@test "dbt/models: staging bullet gives the sourced reasons (joins, base models) not 'joins change the grain'" {
  run grep -F 'joins and aggregations change the grain' "$REPO_ROOT/$MODELS"
  [ "$status" -eq 1 ]
  grep -qF 'base models are the exception' "$REPO_ROOT/$MODELS"
}

@test "dbt/models: CTE bullet says 'its own model', not 'intermediate model'" {
  grep -qF 'move it into its own model' "$REPO_ROOT/$MODELS"
  run grep -F 'intermediate model' "$REPO_ROOT/$MODELS"
  [ "$status" -eq 1 ]
}

@test "dbt/models: incremental_predicates keeps the source's condition" {
  grep -qF 'large enough to justify' "$REPO_ROOT/$MODELS"
}

@test "dbt: the + prefix advice sits in the file that loads where it applies" {
  # project.md loads only on dbt_project.yml, so it must not talk about property files / config()
  run grep -F 'property files' "$REPO_ROOT/$PROJECT"
  [ "$status" -eq 1 ]
  run grep -F 'config()' "$REPO_ROOT/$PROJECT"
  [ "$status" -eq 1 ]
  [ -n "$(bullet_line $MODELS 'Omit the `+` prefix in `config()` blocks')" ]
  [ -n "$(bullet_line $TESTS 'Omit the `+` prefix in `config:` blocks')" ]
}

@test "dbt/README: documents Scope (glob false loads and misses) and Versions" {
  grep -qF '## Scope' "$REPO_ROOT/$README"
  grep -qF '## Versions' "$REPO_ROOT/$README"
  grep -qF 'SQLMesh' "$REPO_ROOT/$README"
  grep -qF 'Bullets name the dbt version they need' "$REPO_ROOT/$README"
}

@test "dbt: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets dbt)" ]
}
