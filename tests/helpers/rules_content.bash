#!/usr/bin/env bash
# Helpers for the tests/test_rules_*_content.bats files: assertions on the TEXT of the
# real rule packs under rules/. Each test file loads this after helpers/setup, which sets
# REPO_ROOT. These are the author's own checks; independent verification is qa-engineer's.

# over_cap_bullets PACK...: print `file: bullet` for every bullet in rules/<pack>/*.md
# longer than 240 characters (continuation lines joined by one space, as the linter
# measures them); empty output = all within the cap. Lint also enforces this, but a content
# test keeps the cap visible next to the wording it constrains.
over_cap_bullets() {
  local pack files
  for pack in "$@"; do
    # an array, not an unquoted $(...): a path with a space must stay one argument (SC2046)
    mapfile -t files < <(find "$REPO_ROOT/rules/$pack" -maxdepth 1 -name '*.md' ! -name README.md | sort)
    LC_ALL=C.UTF-8 awk '
      function flush() { if (b != "" && length(b) > 240) print FILENAME ": " b; b = "" }
      FNR == 1 { flush() }
      /^- / { flush(); b = substr($0, 3); next }
      /^  [^ ]/ && b != "" { sub(/^  /, ""); b = b " " $0; next }
      { flush() }
      END { flush() }
    ' "${files[@]}"
  done
}

# bullet_line FILE PATTERN: the bullet lines of FILE (repo-relative) matching fixed string PATTERN.
bullet_line() {
  grep -F -- "$2" "$REPO_ROOT/$1" | grep '^- ' || true
}
