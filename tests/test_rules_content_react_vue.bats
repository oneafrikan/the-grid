#!/usr/bin/env bats
# Content checks for WP-067 (records R23b.qa.F9/F10/F11/F12/F15/F16): a false README ledger
# claim, version-dependent and over-broad react and vue bullets, and the documented limit
# of the composable/Hook globs. grep -F on repo files; the format is checked by
# `rules.py lint`.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "react/README: no claim that ECC had a Trusted Types bullet (ECC rules/react has none)" {
  run grep -F 'Trusted Types' "$REPO_ROOT/rules/react/README.md"
  [ "$status" -eq 1 ]
}

@test "vue/patterns: the toValue() bullet names Vue 3.3" {
  [ -n "$(bullet_line rules/vue/patterns.md 'In Vue 3.3 and later')" ]
}

@test "react/hooks: the cleanup bullet says Strict Mode remounts in development" {
  grep -qF 'Strict Mode' "$REPO_ROOT/rules/react/hooks.md"
}

@test "react/patterns: 'use client' is placed where a Server Component meets client code, not on any file" {
  grep -qF 'meets client code' "$REPO_ROOT/rules/react/patterns.md"
  run grep -F 'any file that uses' "$REPO_ROOT/rules/react/patterns.md"
  [ "$status" -eq 1 ]
}

@test "vue/testing: the trigger()/setValue() bullet is conditional on mounting with @vue/test-utils" {
  line=$(bullet_line rules/vue/testing.md 'await `trigger()`')
  [[ "$line" == '- When a test mounts'* ]]
}

@test "react/testing: the userEvent.setup() bullet is conditional on user-event" {
  [ -n "$(bullet_line rules/react/testing.md 'When tests use `user-event`')" ]
}

@test "react and vue READMEs document that composable/Hook bullets load only on component files" {
  grep -qF 'Bullets about writing a composable (Hook) load only when' "$REPO_ROOT/rules/react/README.md"
  grep -qF 'Bullets about writing a composable (Hook) load only when' "$REPO_ROOT/rules/vue/README.md"
  grep -qF 'Bullets name a minimum version where the cited page gives one.' "$REPO_ROOT/rules/vue/README.md"
}

@test "react and vue: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets react vue)" ]
}
