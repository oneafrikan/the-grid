#!/usr/bin/env bats
# Content checks for rules/bash (WP-061, records R22a.qa.F1/F2/F5/F6/F7/F8/F9): the wording of
# the real pack must match what its cited sources say. grep -F on repo files; the format
# itself is checked by `rules.py lint` (tests/test_rules.bats "real packs lint clean").
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

SAFETY=rules/bash/safety.md
STYLE=rules/bash/style.md

@test "bash/safety: no ln -sf advice (re-run onto a directory nests the link; onto a file it destroys it)" {
  run grep -rn 'ln -sf' "$REPO_ROOT/rules/bash/"
  [ "$status" -eq 1 ]
}

@test "bash/README: the ln.html source is gone with the bullet that cited it" {
  run grep -F 'utilities/ln.html' "$REPO_ROOT/rules/bash/README.md"
  [ "$status" -eq 1 ]
}

@test "bash/safety: set -e bullet describes behaviour, it does not tell the reader to avoid set -e" {
  run grep -F 'instead of relying on' "$REPO_ROOT/$SAFETY"
  [ "$status" -eq 1 ]
  grep -qF 'Check return values explicitly; `set -e` does not exit' "$REPO_ROOT/$SAFETY"
}

@test "bash/safety: set -u and pipefail are descriptions of documented behaviour, not imperatives" {
  run grep -F -e '- Add `set -u`' -e '- Add `set -o pipefail`' "$REPO_ROOT/$SAFETY"
  [ "$status" -eq 1 ]
  grep -qF '`set -u` makes expanding an unset variable an error' "$REPO_ROOT/$SAFETY"
}

@test "bash-only bullets say 'In a bash script' because the globs also load on #!/bin/sh scripts" {
  # safety.md pipefail; style.md arrays, [[ ]], (( )) and < <(cmd)
  [ -n "$(bullet_line $SAFETY 'In a bash script, `set -o pipefail`')" ]
  [ -n "$(bullet_line $STYLE 'In a bash script, store a list of arguments in an array')" ]
  [ -n "$(bullet_line $STYLE 'In a bash script, quote the right side of `==` in `[[ ]]`')" ]
  [ -n "$(bullet_line $STYLE 'In a bash script, use `(( ))` for numeric tests')" ]
  [ -n "$(bullet_line $STYLE 'In a bash script, feed a `while read` loop with `< <(cmd)`')" ]
}

@test "bash/README: Scope says the globs load on sh scripts and where the bash-only bullets say so" {
  grep -qF '#!/bin/sh' "$REPO_ROOT/rules/bash/README.md"
  grep -qF 'In a bash script' "$REPO_ROOT/rules/bash/README.md"
}

@test "bash/safety: cd bullet covers functions (return) and trap bullet no longer carries an unguarded rm -rf" {
  grep -qF '|| return' "$REPO_ROOT/$SAFETY"
  run grep -F 'rm -rf "$tmp"' "$REPO_ROOT/$SAFETY"
  [ "$status" -eq 1 ]
  grep -qF 'Quote a `trap` command in single quotes' "$REPO_ROOT/$SAFETY"
}

@test "bash/style: 'quote every expansion' is replaced by a rule with its documented exceptions" {
  run grep -F 'Quote every expansion' "$REPO_ROOT/$STYLE"
  [ "$status" -eq 1 ]
  grep -qF 'unless careful unquoted expansion is required' "$REPO_ROOT/$STYLE"
}

@test "bash/style: the for-glob bullet keeps SC2045's no-match guard" {
  grep -qF '[[ -e "$f" ]] || break' "$REPO_ROOT/$STYLE"
}

@test "bash: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets bash)" ]
}
