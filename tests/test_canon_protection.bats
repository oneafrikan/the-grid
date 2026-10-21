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

@test "PR template carries the canon checkbox with the exact detection command" {
  # The merger runs this one command to learn whether a human must merge; the
  # base is origin/main because the retired next branch no longer exists.
  run grep -F -- '- [ ] No path under `knowledge/canon/` changed, or a human is merging this: `git diff --name-only origin/main...HEAD -- knowledge/canon`' "$REPO_ROOT/.github/pull_request_template.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md block says canon is never merged without a human" {
  # Take the block that starts at the line naming the path and the rule, up to
  # the next blank line, so the three words must sit together and not be
  # satisfied by unrelated mentions elsewhere in the file.
  block="$(awk '/knowledge\/canon\// && /never merged/ {p=1} p && /^$/ {exit} p' "$REPO_ROOT/CLAUDE.md")"
  [ -n "$block" ]
  [[ "$block" == *'knowledge/canon/'* ]]
  [[ "$block" == *'never merged'* ]]
  [[ "$block" == *'human'* ]]
  [[ "$block" == *'origin/main...HEAD'* ]]
}
