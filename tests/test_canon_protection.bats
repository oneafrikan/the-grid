#!/usr/bin/env bats
# Canon protection: GitHub must request the owner's review on any change under knowledge/canon/.
# Spec: openspec/changes/epistemic-enforcement, canon-protection ("CODEOWNERS covers canon").

load helpers/setup

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "CODEOWNERS has a knowledge/canon/ rule with an owner and no other rule line" {
  # Drop comments and blank lines; exactly one rule line must remain, so a wider
  # pattern (or a second path) cannot be added without this test changing.
  run grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.github/CODEOWNERS"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^knowledge/canon/\ @[A-Za-z0-9._-]+$ ]]
}
