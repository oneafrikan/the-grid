#!/usr/bin/env bats
# Tests for scripts/rules.py (lint, list, emit). Every fixture pack is built in a temp
# dir inside the test (nothing is committed under tests/ for them) and linted with
# --root, so the real rules/ is only touched by the one `real packs lint clean` test.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup

setup() {
  common_setup
  R=$(mktemp -d)
  mkdir -p "$R/rules"
  # The real denylist and notices travel with every fixture root, as in a real tree.
  cp "$REPO_ROOT/rules/denylist.txt" "$REPO_ROOT/rules/THIRD_PARTY_NOTICES.txt" "$R/rules/"
}

teardown() {
  rm -rf "$R"
  common_teardown
}

lint() { python3 "$REPO_ROOT/scripts/rules.py" lint --root "$R" "$@"; }

# n_chars N: print N 'x' characters (no newline), for exact-length bullets.
n_chars() { printf '%*s' "$1" '' | tr ' ' x; }

# write_rule FILE [GLOB]: a minimal valid rule file with one bullet.
write_rule() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\npaths:\n  - "%s"\n---\n# Title\n\n- Use `foo` for bar.\n' "${2:-**/*.sql}" > "$1"
}

# make_pack NAME [TIER]: a valid pack with one rule file, style.md. Tier 1 by default.
make_pack() {
  local d="$R/rules/$1"
  mkdir -p "$d"
  write_rule "$d/style.md"
  if [ "${2:-1}" = "2" ]; then
    printf 'summary: Test pack\ntier: 2\nadapted_from: affaan-m/ECC rules/x @ ef648e0 (MIT)\n' > "$d/pack.yaml"
    printf '# %s\n\nAdapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt\n\n## Sources\n\n| Rule file | Source |\n|---|---|\n| style.md | https://example.com/style |\n' "$1" > "$d/README.md"
    printf '%s\n' "$1" >> "$R/rules/THIRD_PARTY_NOTICES.txt"
  else
    printf 'summary: Test pack\ntier: 1\n' > "$d/pack.yaml"
    printf '# %s\n\n## Sources\n\n| Rule file | Source |\n|---|---|\n| style.md | https://example.com/style |\n' "$1" > "$d/README.md"
  fi
}

# expect_only CODE: lint failed (exit 1) and every finding line carries CODE.
expect_only() {
  run lint
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  while IFS= read -r line; do
    [[ "$line" == "$1 "* ]] || { echo "unexpected finding: $line"; return 1; }
  done <<< "$output"
}

# expect_code CODE: lint failed and at least one finding carries CODE.
expect_code() {
  run lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"$1 "* ]] || { echo "no $1 in: $output"; return 1; }
}

# --- clean cases ---------------------------------------------------------------------

@test "no rules/ directory at all lints clean" {
  rm -rf "$R/rules"
  run lint
  [ "$status" -eq 0 ]
}

@test "an empty rules/ (no packs) lints clean" {
  run lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a valid tier 1 pack passes" {
  make_pack good
  run lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a valid tier 2 pack passes (attribution line + listed in notices)" {
  make_pack adapted 2
  run lint
  [ "$status" -eq 0 ]
}

@test "lint writes nothing: a second run leaves the tree byte-identical" {
  make_pack good
  before="$(cd "$R" && find . -type f | LC_ALL=C sort | xargs cksum)"
  lint >/dev/null
  lint >/dev/null
  after="$(cd "$R" && find . -type f | LC_ALL=C sort | xargs cksum)"
  [ "$before" = "$after" ]
}

# --- E_FRONTMATTER / E_PATHS -----------------------------------------------------------

@test "E_FRONTMATTER: a rule file with no frontmatter" {
  make_pack bad
  printf '# Title\n\n- Use `foo` for bar.\n' > "$R/rules/bad/style.md"
  expect_only E_FRONTMATTER
}

@test "E_FRONTMATTER: an extra frontmatter key" {
  make_pack bad
  printf -- '---\ndescription: x\npaths:\n  - "**/*.sql"\n---\n# Title\n\n- Use `foo` for bar.\n' > "$R/rules/bad/style.md"
  expect_only E_FRONTMATTER
}

@test "E_FRONTMATTER: a malformed paths entry (single quotes)" {
  make_pack bad
  printf -- "---\npaths:\n  - '**/*.sql'\n---\n# Title\n\n- Use \`foo\` for bar.\n" > "$R/rules/bad/style.md"
  expect_only E_FRONTMATTER
}

@test "E_PATHS: an empty paths: list" {
  make_pack bad
  printf -- '---\npaths:\n---\n# Title\n\n- Use `foo` for bar.\n' > "$R/rules/bad/style.md"
  expect_only E_PATHS
}

@test "E_PATHS: banned glob **/*" {
  make_pack bad
  write_rule "$R/rules/bad/style.md" '**/*'
  expect_only E_PATHS
}

@test "E_PATHS: banned glob **/*.*" {
  make_pack bad
  write_rule "$R/rules/bad/style.md" '**/*.*'
  expect_only E_PATHS
}

@test "E_PATHS: absolute glob and .. glob" {
  make_pack bad
  write_rule "$R/rules/bad/style.md" '/etc/*.conf'
  expect_only E_PATHS
  write_rule "$R/rules/bad/style.md" '../x/*.sql'
  expect_only E_PATHS
}

@test "E_PATHS: nested braces" {
  make_pack bad
  write_rule "$R/rules/bad/style.md" '**/*.{a,{b,c}}'
  expect_only E_PATHS
}

@test "E_PATHS: empty brace alternative" {
  make_pack bad
  write_rule "$R/rules/bad/style.md" '**/*.py{,i}'
  expect_only E_PATHS
}

@test "E_PATHS: more than 2 brace groups" {
  make_pack bad
  write_rule "$R/rules/bad/style.md" '{a,b}/{c,d}/*.{e,f}'
  expect_only E_PATHS
}

@test "paths with up to 2 brace groups pass" {
  make_pack good
  write_rule "$R/rules/good/style.md" '**/*.{test,spec}.{tsx,jsx}'
  run lint
  [ "$status" -eq 0 ]
}

# --- E_TITLE / E_STYLE ---------------------------------------------------------------

@test "E_TITLE: no # Title after the frontmatter" {
  make_pack bad
  printf -- '---\npaths:\n  - "**/*.sql"\n---\n- Use `foo` for bar.\n' > "$R/rules/bad/style.md"
  expect_only E_TITLE
}

@test "E_STYLE: a prose paragraph line" {
  make_pack bad
  printf 'This paragraph explains things in prose.\n' >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

@test "E_STYLE: a block-quote line" {
  make_pack bad
  printf '> quoted advice\n' >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

@test "E_STYLE: a second # heading" {
  make_pack bad
  printf '\n# Another\n' >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

@test "E_STYLE: a 241-character bullet fails, a 240-character bullet passes" {
  make_pack bad
  # Bullet length counts the leading "- ": 2 + 238 = 240 passes, 2 + 239 = 241 fails.
  write_rule "$R/rules/bad/style.md"
  printf -- '- %s\n' "$(n_chars 238)" >> "$R/rules/bad/style.md"
  run lint
  [ "$status" -eq 0 ]
  printf -- '- %s\n' "$(n_chars 239)" >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

@test "E_STYLE: a bullet is measured with its continuation lines" {
  make_pack bad
  write_rule "$R/rules/bad/style.md"
  printf -- '- start\n  %s\n  %s\n' "$(n_chars 120)" "$(n_chars 120)" >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

@test "E_STYLE: an 11-line fenced block fails, a 10-line one passes" {
  make_pack bad
  write_rule "$R/rules/bad/style.md"
  { printf '\n```\n'; for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done; printf '```\n'; } >> "$R/rules/bad/style.md"
  run lint
  [ "$status" -eq 0 ]
  write_rule "$R/rules/bad/style.md"
  { printf '\n```\n'; for i in 1 2 3 4 5 6 7 8 9 10 11; do echo "line $i"; done; printf '```\n'; } >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

@test "E_STYLE: an unclosed fenced block" {
  make_pack bad
  printf '\n```\ncode\n' >> "$R/rules/bad/style.md"
  expect_only E_STYLE
}

# --- E_FILE_SIZE / E_PACK_SIZE ------------------------------------------------------------

# big_rule FILE BYTES: a valid rule file of exactly BYTES bytes (bullets of 99 chars).
big_rule() {
  python3 - "$1" "$2" <<'PYEOF'
import sys
path, target = sys.argv[1], int(sys.argv[2])
head = '---\npaths:\n  - "**/*.sql"\n---\n# Title\n\n'
body = head
while len(body) + 100 <= target - 100:
    body += "- " + "x" * 97 + "\n"
rest = target - len(body)          # remaining bytes, including the final newline
body += "- " + "x" * (rest - 3) + "\n"
open(path, "w").write(body)
PYEOF
}

@test "E_FILE_SIZE: a 4097-byte file fails, a 4096-byte file passes" {
  make_pack bad
  big_rule "$R/rules/bad/style.md" 4096
  [ "$(wc -c < "$R/rules/bad/style.md")" -eq 4096 ]
  run lint
  [ "$status" -eq 0 ]
  big_rule "$R/rules/bad/style.md" 4097
  [ "$(wc -c < "$R/rules/bad/style.md")" -eq 4097 ]
  expect_only E_FILE_SIZE
}

@test "E_PACK_SIZE: a pack over 9216 bytes fails" {
  make_pack bad
  big_rule "$R/rules/bad/style.md" 3500
  big_rule "$R/rules/bad/other.md" 3500
  big_rule "$R/rules/bad/third.md" 3500
  printf '| other.md | https://example.com/o |\n| third.md | https://example.com/t |\n' >> "$R/rules/bad/README.md"
  expect_only E_PACK_SIZE
}

# --- E_OPINION ---------------------------------------------------------------------------

@test "E_OPINION: a denylist hit (house-opinion phrase)" {
  make_pack bad
  printf -- '- Mark blockers (CRITICAL) in review.\n' >> "$R/rules/bad/style.md"
  expect_only E_OPINION
}

@test "E_OPINION: a hedged bullet (- You should ...)" {
  make_pack bad
  printf -- '- You should use `foo` for bar.\n' >> "$R/rules/bad/style.md"
  expect_only E_OPINION
}

@test "E_OPINION: an 'extends [common/x.md]' pointer line" {
  make_pack bad
  printf 'This file extends [common/x.md] with specifics.\n' >> "$R/rules/bad/style.md"
  # The prose shape also trips E_STYLE; the pointer itself must be E_OPINION.
  expect_code E_OPINION
}

@test "E_OPINION: denylist patterns are not applied to READMEs" {
  make_pack good
  printf '\nAdapted from ECC; see the sub-agents note.\n' >> "$R/rules/good/README.md"
  run lint
  [ "$status" -eq 0 ]
}

@test "E_OPINION: a missing denylist fails closed when packs exist" {
  make_pack good
  rm "$R/rules/denylist.txt"
  expect_only E_OPINION
}

# --- E_PACK_META -------------------------------------------------------------------------

@test "E_PACK_META: bad tier value" {
  make_pack bad
  printf 'summary: Test\ntier: 3\n' > "$R/rules/bad/pack.yaml"
  expect_only E_PACK_META
}

@test "E_PACK_META: tier 2 without adapted_from" {
  make_pack bad 2
  printf 'summary: Test\ntier: 2\n' > "$R/rules/bad/pack.yaml"
  expect_only E_PACK_META
}

@test "E_PACK_META: tier 1 with adapted_from" {
  make_pack bad
  printf 'summary: Test\ntier: 1\nadapted_from: x\n' > "$R/rules/bad/pack.yaml"
  expect_only E_PACK_META
}

@test "E_PACK_META: missing pack.yaml" {
  make_pack bad
  rm "$R/rules/bad/pack.yaml"
  expect_only E_PACK_META
}

@test "E_PACK_META: missing summary" {
  make_pack bad
  printf 'tier: 1\n' > "$R/rules/bad/pack.yaml"
  expect_only E_PACK_META
}

@test "E_PACK_META: an unknown key" {
  make_pack bad
  printf 'summary: Test\ntier: 1\nowner: me\n' > "$R/rules/bad/pack.yaml"
  expect_only E_PACK_META
}

@test "pack.yaml trailing comments are stripped" {
  make_pack good
  printf 'summary: Test pack   # why\ntier: 1   # written fresh\n' > "$R/rules/good/pack.yaml"
  run lint
  [ "$status" -eq 0 ]
}

# --- E_SOURCES / E_ATTRIBUTION ---------------------------------------------------------------

@test "E_SOURCES: README missing a row for a rule file" {
  make_pack bad
  write_rule "$R/rules/bad/second.md"
  expect_only E_SOURCES
}

@test "E_SOURCES: a row without an https URL" {
  make_pack bad
  printf '# bad\n\n## Sources\n\n| Rule file | Source |\n|---|---|\n| style.md | http://example.com/style |\n' > "$R/rules/bad/README.md"
  expect_only E_SOURCES
}

@test "E_SOURCES: no README" {
  make_pack bad
  rm "$R/rules/bad/README.md"
  expect_only E_SOURCES
}

@test "E_ATTRIBUTION: tier 2 README without the attribution line" {
  make_pack bad 2
  printf '# bad\n\n## Sources\n\n| Rule file | Source |\n|---|---|\n| style.md | https://example.com/style |\n' > "$R/rules/bad/README.md"
  expect_only E_ATTRIBUTION
}

@test "E_ATTRIBUTION: tier 2 pack not listed in THIRD_PARTY_NOTICES.txt" {
  make_pack bad 2
  cp "$REPO_ROOT/rules/THIRD_PARTY_NOTICES.txt" "$R/rules/THIRD_PARTY_NOTICES.txt"
  expect_only E_ATTRIBUTION
}

# --- E_NAME -----------------------------------------------------------------------------

@test "E_NAME: an uppercase rule file name" {
  make_pack bad
  write_rule "$R/rules/bad/Style.md"
  printf '| Style.md | https://example.com/style |\n' >> "$R/rules/bad/README.md"
  expect_only E_NAME
}

@test "E_NAME: an uppercase pack name" {
  make_pack Bad
  expect_only E_NAME
}

@test "E_NAME: an unexpected non-.md file in a pack" {
  make_pack bad
  printf 'x\n' > "$R/rules/bad/notes.txt"
  expect_only E_NAME
}

# --- list ---------------------------------------------------------------------------------

@test "list prints pack tier files bytes summary, sorted, stable across runs" {
  make_pack zeta
  make_pack alpha
  make_pack mid
  run python3 "$REPO_ROOT/scripts/rules.py" list --root "$R"
  [ "$status" -eq 0 ]
  first="$output"
  # Columns are padded to the widest cell; squeeze runs of spaces to compare content.
  squeezed="$(printf '%s\n' "$first" | tr -s ' ')"
  [ "$(printf '%s\n' "$squeezed" | sed -n 1p)" = "pack tier files bytes summary" ]
  # Rows follow the header in sorted pack-name order (C locale).
  [[ "$(printf '%s\n' "$squeezed" | sed -n 2p)" == "alpha 1 1 "*" Test pack" ]] || false
  [[ "$(printf '%s\n' "$squeezed" | sed -n 3p)" == "mid 1 1 "* ]] || false
  [[ "$(printf '%s\n' "$squeezed" | sed -n 4p)" == "zeta 1 1 "* ]] || false
  run python3 "$REPO_ROOT/scripts/rules.py" list --root "$R"
  [ "$output" = "$first" ]
}

@test "list on an empty rules/ prints only the header" {
  run python3 "$REPO_ROOT/scripts/rules.py" list --root "$R"
  [ "$status" -eq 0 ]
  [ "$output" = "pack  tier  files  bytes  summary" ]
}

# --- emit --harness cursor -------------------------------------------------------------------
# Every emit test passes a temp --out or cd's into a temp dir; none touches the real tree.

emit() { python3 "$REPO_ROOT/scripts/rules.py" emit --root "$R" "$@"; }

# write_rule_titled FILE TITLE GLOB...: a valid rule file with a custom title and glob list.
write_rule_titled() {
  local f="$1" title="$2"; shift 2
  mkdir -p "$(dirname "$f")"
  { printf -- '---\npaths:\n'
    for g in "$@"; do printf -- '  - "%s"\n' "$g"; done
    printf -- '---\n# %s\n\n- Name columns.\n- Filter the partition.\n' "$title"; } > "$f"
}

@test "emit cursor: default --out lands in ./.cursor/rules" {
  make_pack sql
  W=$(mktemp -d)
  cd "$W"
  run emit --harness cursor --packs sql
  [ "$status" -eq 0 ]
  [ "$output" = "wrote .cursor/rules/grid-sql-style.mdc" ]
  [ -f "$W/.cursor/rules/grid-sql-style.mdc" ]
  rm -rf "$W"
}

@test "emit cursor: explicit --out DIR lands there and creates parents" {
  make_pack sql
  run emit --harness cursor --packs sql --out "$R/deep/er/rules"
  [ "$status" -eq 0 ]
  [ "$output" = "wrote $R/deep/er/rules/grid-sql-style.mdc" ]
  [ -f "$R/deep/er/rules/grid-sql-style.mdc" ]
}

@test "emit: unknown --harness exits 2 and writes nothing" {
  make_pack sql
  run emit --harness vim --packs sql --out "$R/out"
  [ "$status" -eq 2 ]
  [ ! -e "$R/out" ]
}

@test "emit cursor: unknown pack exits 2 and writes nothing (even for the known pack)" {
  make_pack sql
  run emit --harness cursor --packs sql,nope --out "$R/out"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown pack"* ]]
  [ ! -e "$R/out" ]
}

@test "emit: a pack name that tries to escape rules/ is an unknown pack" {
  make_pack sql
  run emit --harness cursor --packs ../rules/sql --out "$R/out"
  [ "$status" -eq 2 ]
  [ ! -e "$R/out" ]
}

@test "emit agents-md and gemini exit 2 not implemented and write nothing" {
  make_pack sql
  for h in agents-md gemini; do
    run emit --harness "$h" --packs sql --out "$R/out-$h"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not implemented"* ]]
    [ ! -e "$R/out-$h" ]
  done
}

@test "emit: --packs is required" {
  run emit --harness cursor --out "$R/out"
  [ "$status" -eq 2 ]
}

@test "emit cursor: exact .mdc text for a fixture rule" {
  mkdir -p "$R/rules/sql"
  write_rule_titled "$R/rules/sql/bigquery.md" "BigQuery" "**/*.sql"
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 0 ]
  expected="$(printf -- '---\ndescription: BigQuery\nglobs: ["**/*.sql"]\nalwaysApply: false\n---\n<!-- the-grid:rules generated from rules/sql/bigquery.md; do not edit -->\n# BigQuery\n\n- Name columns.\n- Filter the partition.\nEND')"
  [ "$(cat "$R/out/grid-sql-bigquery.mdc"; printf END)" = "$expected" ]
}

@test "emit cursor: a title that is unsafe as a bare YAML scalar is quoted" {
  mkdir -p "$R/rules/sql"
  write_rule_titled "$R/rules/sql/style.md" "Style: naming" "**/*.sql"
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 0 ]
  grep -qxF 'description: "Style: naming"' "$R/out/grid-sql-style.mdc"
}

@test "emit cursor: brace expansion, one group" {
  mkdir -p "$R/rules/web"
  write_rule_titled "$R/rules/web/style.md" "Style" '**/*.{ts,tsx}'
  run emit --harness cursor --packs web --out "$R/out"
  [ "$status" -eq 0 ]
  grep -qxF 'globs: ["**/*.ts", "**/*.tsx"]' "$R/out/grid-web-style.mdc"
}

@test "emit cursor: brace expansion, two groups in source order" {
  mkdir -p "$R/rules/web"
  write_rule_titled "$R/rules/web/testing.md" "Testing" '**/*.{test,spec}.{tsx,jsx}'
  run emit --harness cursor --packs web --out "$R/out"
  [ "$status" -eq 0 ]
  grep -qxF 'globs: ["**/*.test.tsx", "**/*.test.jsx", "**/*.spec.tsx", "**/*.spec.jsx"]' "$R/out/grid-web-testing.mdc"
}

@test "emit cursor: multiple globs keep order and drop duplicates" {
  mkdir -p "$R/rules/web"
  write_rule_titled "$R/rules/web/style.md" "Style" '**/*.{ts,tsx}' '**/*.tsx' '**/*.js'
  run emit --harness cursor --packs web --out "$R/out"
  [ "$status" -eq 0 ]
  grep -qxF 'globs: ["**/*.ts", "**/*.tsx", "**/*.js"]' "$R/out/grid-web-style.mdc"
}

@test "emit cursor: second emit is byte-identical, prints nothing, --check exits 0" {
  make_pack sql
  make_pack bash
  emit --harness cursor --packs sql,bash --out "$R/out" >/dev/null
  before="$(cat "$R"/out/*.mdc | cksum)"
  run emit --harness cursor --packs bash,sql --out "$R/out"   # order of --packs is irrelevant
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$R"/out/*.mdc | cksum)" = "$before" ]
  run emit --harness cursor --packs sql,bash --out "$R/out" --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit cursor: dropping a pack deletes only its marked files" {
  make_pack sql
  make_pack bash
  emit --harness cursor --packs sql,bash --out "$R/out" >/dev/null
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 0 ]
  [ "$output" = "removed $R/out/grid-bash-style.mdc" ]
  [ -f "$R/out/grid-sql-style.mdc" ]
  [ ! -e "$R/out/grid-bash-style.mdc" ]
}

@test "emit cursor: an empty --packs removes all marked files" {
  make_pack sql
  emit --harness cursor --packs sql --out "$R/out" >/dev/null
  run emit --harness cursor --packs "" --out "$R/out"
  [ "$status" -eq 0 ]
  [ ! -e "$R/out/grid-sql-style.mdc" ]
}

@test "emit cursor: a hand-written grid-keep.mdc without the marker survives" {
  make_pack sql
  mkdir -p "$R/out"
  printf -- '---\ndescription: mine\n---\nhand written\n' > "$R/out/grid-keep.mdc"
  printf 'other\n' > "$R/out/notes.mdc"
  before="$(cat "$R/out/grid-keep.mdc" "$R/out/notes.mdc" | cksum)"
  emit --harness cursor --packs sql --out "$R/out" >/dev/null
  emit --harness cursor --packs "" --out "$R/out" >/dev/null
  [ "$(cat "$R/out/grid-keep.mdc" "$R/out/notes.mdc" | cksum)" = "$before" ]
}

@test "emit cursor: refuses to overwrite an unmarked file at a target path" {
  make_pack sql
  mkdir -p "$R/out"
  printf 'hand written\n' > "$R/out/grid-sql-style.mdc"
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 2 ]
  [ "$(cat "$R/out/grid-sql-style.mdc")" = "hand written" ]
}

@test "emit cursor: --out that is an existing file exits 2" {
  make_pack sql
  printf 'x\n' > "$R/afile"
  run emit --harness cursor --packs sql --out "$R/afile"
  [ "$status" -eq 2 ]
  [ "$(cat "$R/afile")" = "x" ]
}

@test "emit cursor: --check exits 1 and writes nothing when output is missing" {
  make_pack sql
  run emit --harness cursor --packs sql --out "$R/out" --check
  [ "$status" -eq 1 ]
  [ "$output" = "wrote $R/out/grid-sql-style.mdc" ]
  [ ! -e "$R/out" ]
}

@test "emit cursor: --check exits 1 when a generated file is edited, and does not fix it" {
  make_pack sql
  emit --harness cursor --packs sql --out "$R/out" >/dev/null
  printf 'tampered\n' >> "$R/out/grid-sql-style.mdc"
  before="$(cksum < "$R/out/grid-sql-style.mdc")"
  run emit --harness cursor --packs sql --out "$R/out" --check
  [ "$status" -eq 1 ]
  [ "$(cksum < "$R/out/grid-sql-style.mdc")" = "$before" ]
  # A real emit then repairs it.
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 0 ]
  run emit --harness cursor --packs sql --out "$R/out" --check
  [ "$status" -eq 0 ]
}

@test "emit cursor: --check exits 1 for a stale marked file and keeps it" {
  make_pack sql
  make_pack bash
  emit --harness cursor --packs sql,bash --out "$R/out" >/dev/null
  run emit --harness cursor --packs sql --out "$R/out" --check
  [ "$status" -eq 1 ]
  [ -f "$R/out/grid-bash-style.mdc" ]
}

@test "emit cursor: a malformed rule file exits 2 and writes nothing" {
  make_pack sql
  printf -- '---\npaths:\n  - "**/*.sql"\n' > "$R/rules/sql/broken.md"   # frontmatter never closed
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 2 ]
  [ ! -e "$R/out" ]
}

# --- the real tree --------------------------------------------------------------------------

@test "real packs lint clean" {
  cd "$REPO_ROOT"
  run python3 scripts/rules.py lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
