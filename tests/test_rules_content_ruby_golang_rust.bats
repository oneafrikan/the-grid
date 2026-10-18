#!/usr/bin/env bats
# Content checks for WP-065 (records R22b.qa.F4/F5/F6/F10/F11): ruby default hash, go
# timeouts, the rust tests/ glob note, the go README ledger reason and the web nosniff
# bullet. grep -F on repo files; the format is checked by `rules.py lint`.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "ruby/style: the default-hash bullet assigns into the hash (a bare block discards writes)" {
  grep -qF 'h[k] = []' "$REPO_ROOT/rules/ruby/style.md"
  run grep -F 'builds a fresh object per key' "$REPO_ROOT/rules/ruby/style.md"
  [ "$status" -eq 1 ]
  run grep -F 'Hash.new { [] }' "$REPO_ROOT/rules/ruby/style.md"
  [ "$status" -eq 1 ]
}

@test "golang/security: timeout bullet matches net/http (ReadTimeout fallback, body read counted)" {
  grep -qF 'ReadTimeout' "$REPO_ROOT/rules/golang/security.md"
  grep -qF 'reading the body' "$REPO_ROOT/rules/golang/security.md"
  run grep -F 'holds the connection forever' "$REPO_ROOT/rules/golang/security.md"
  [ "$status" -eq 1 ]
}

@test "golang/README: the Receiver Type ledger row no longer claims the page does not state it" {
  run grep -F 'not stated on the Code Review Comments page' "$REPO_ROOT/rules/golang/README.md"
  [ "$status" -eq 1 ]
  grep -qF 'stated on the Code Review Comments page, but as a style preference' "$REPO_ROOT/rules/golang/README.md"
}

@test "rust/testing and README: the glob also matches src/tests/, and the README says so" {
  grep -qF 'integration tests need logic' "$REPO_ROOT/rules/rust/testing.md"
  run grep -F 'Unit tests inside `src/` are not matched' "$REPO_ROOT/rules/rust/README.md"
  [ "$status" -eq 1 ]
  grep -qF 'src/tests/' "$REPO_ROOT/rules/rust/README.md"
}

@test "web/headers: nosniff is a bullet of its own, and the README no longer defers it to the flask pack" {
  [ -n "$(bullet_line rules/web/headers.md 'X-Content-Type-Options')" ]
  grep -qF 'X-Content-Type-Options' "$REPO_ROOT/rules/web/README.md"
  run grep -F 'already a bullet in the `flask` pack' "$REPO_ROOT/rules/web/README.md"
  [ "$status" -eq 1 ]
  # the new source is named on the headers.md Sources row
  grep -F '| headers.md |' "$REPO_ROOT/rules/web/README.md" | grep -qF 'Headers/X-Content-Type-Options'
}

@test "ruby, golang, rust, web: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets ruby golang rust web)" ]
}
