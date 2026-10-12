#!/usr/bin/env bats
# Tests for scripts/rules.py (lint, list, emit). Every fixture pack is built in a temp
# dir inside the test (nothing is committed under tests/ for them) and linted with
# --root, so the real rules/ is only touched by the one `real packs lint clean` test.
# These are the author's own checks; independent verification is qa-engineer's.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`

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
  [ "$output" = "would write $R/out/grid-sql-style.mdc" ]
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

# --- emit --harness agents-md | gemini -------------------------------------------------------
# The managed block between BEGIN/END markers. Every test uses a temp --out or cd's into
# a temp dir. BEGIN_LINE / END_LINE are the exact marker lines from design.md.

BEGIN_LINE='<!-- BEGIN the-grid rules (generated by scripts/rules.py; edits inside are overwritten) -->'
END_LINE='<!-- END the-grid rules -->'

# Block for the make_pack fixture (one rule, style.md, glob **/*.sql, title "Title").
fixture_block() {
  printf '%s\n## Coding rules (the-grid)\n\nApply each rule only when working on files matching its globs.\n\n### %s / style (applies to: `**/*.sql`)\n\n- Use `foo` for bar.\n%s\n' \
    "$BEGIN_LINE" "$1" "$END_LINE"
}

# pad_pack PACK N: a pack of five lint-clean rule files whose bodies hold exactly N bytes in
# all (bullet lines, newlines included), so the block size is controllable: block bytes =
# fixed overhead + N. Valid fixtures, because emit re-lints every selected pack. N >= 20.
pad_pack() {
  python3 - "$R/rules/$1" "$2" <<'PY'
import os, sys
d, n = sys.argv[1], int(sys.argv[2])
os.makedirs(d, exist_ok=True)
files = 5
for i in range(files):
    t = n // files + (1 if i < n % files else 0)      # body bytes of this file
    lines = -(-t // 240)                               # fewest bullets of at most 240 bytes
    sizes = [t // lines + (1 if k < t % lines else 0) for k in range(lines)]
    body = "".join("- " + "x" * (sz - 3) + "\n" for sz in sizes)
    with open(os.path.join(d, "pad%d.md" % i), "w") as fh:
        fh.write('---\npaths:\n  - "**/*.sql"\n---\n# Pad\n\n' + body)
PY
}

@test "emit agents-md: creates the file with exactly one block (H1 removed, header carries globs)" {
  make_pack sql
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" = "wrote $R/AGENTS.md" ]
  [ "$(cat "$R/AGENTS.md")" = "$(fixture_block sql)" ]
  ! grep -q '^# Title' "$R/AGENTS.md"
}

@test "emit agents-md and gemini: default --out is ./AGENTS.md and ./GEMINI.md" {
  make_pack sql
  W=$(mktemp -d)
  cd "$W"
  run emit --harness agents-md --packs sql
  [ "$status" -eq 0 ]
  [ "$output" = "wrote AGENTS.md" ]
  run emit --harness gemini --packs sql
  [ "$status" -eq 0 ]
  [ "$output" = "wrote GEMINI.md" ]
  [ -f "$W/AGENTS.md" ]
  [ -f "$W/GEMINI.md" ]
  rm -rf "$W"
}

@test "emit agents-md: --out into a not-yet-existing nested dir creates the parents" {
  make_pack sql
  run emit --harness agents-md --packs sql --out "$R/deep/er/AGENTS.md"
  [ "$status" -eq 0 ]
  [ -f "$R/deep/er/AGENTS.md" ]
}

@test "emit agents-md and gemini produce byte-identical blocks" {
  make_pack sql
  make_pack bash
  emit --harness agents-md --packs sql,bash --out "$R/a.md" >/dev/null
  emit --harness gemini --packs sql,bash --out "$R/g.md" >/dev/null
  cmp "$R/a.md" "$R/g.md"
}

@test "emit agents-md: sections are sorted and --packs order is irrelevant" {
  make_pack sql
  make_pack bash
  emit --harness agents-md --packs sql,bash --out "$R/a.md" >/dev/null
  emit --harness agents-md --packs bash,sql --out "$R/b.md" >/dev/null
  cmp "$R/a.md" "$R/b.md"
  # The bash section comes before the sql section.
  [ "$(grep -n '^### bash' "$R/a.md" | cut -d: -f1)" -lt "$(grep -n '^### sql' "$R/a.md" | cut -d: -f1)" ]
}

@test "emit agents-md: replaces the block and leaves the surrounding bytes unchanged" {
  make_pack sql
  make_pack bash
  # Awkward surrounding bytes: CRLF in the head, no newline at EOF in the tail.
  printf 'top line\r\nsecond\n\n' > "$R/head.bin"
  printf '\n\ntail text, no newline at EOF' > "$R/tail.bin"
  { cat "$R/head.bin"; printf '%s\nstale block body\n%s' "$BEGIN_LINE" "$END_LINE"; cat "$R/tail.bin"; } > "$R/AGENTS.md"
  run emit --harness agents-md --packs sql,bash --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  # Everything before the BEGIN line and after the END line is byte-identical to the originals.
  head_len=$(wc -c < "$R/head.bin")
  tail_len=$(wc -c < "$R/tail.bin")
  [ "$(head -c "$head_len" "$R/AGENTS.md" | cksum)" = "$(cksum < "$R/head.bin")" ]
  [ "$(tail -c "$tail_len" "$R/AGENTS.md" | cksum)" = "$(cksum < "$R/tail.bin")" ]
  grep -q '^### bash / style' "$R/AGENTS.md"
  ! grep -q 'stale block body' "$R/AGENTS.md" || false
  [ "$(grep -c '^<!-- BEGIN the-grid rules' "$R/AGENTS.md")" -eq 1 ]
  [ "$(grep -c '^<!-- END the-grid rules' "$R/AGENTS.md")" -eq 1 ]
}

@test "emit agents-md: appends to a file with no block, original bytes kept as a prefix" {
  make_pack sql
  printf '# My notes\n\nkeep me' > "$R/AGENTS.md"      # no trailing newline
  cp "$R/AGENTS.md" "$R/orig"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  orig_len=$(wc -c < "$R/orig")
  [ "$(head -c "$orig_len" "$R/AGENTS.md" | cksum)" = "$(cksum < "$R/orig")" ]
  grep -q '^<!-- BEGIN the-grid rules' "$R/AGENTS.md"
}

@test "emit agents-md: second emit is byte-identical, prints nothing, --check exits 0" {
  make_pack sql
  printf 'before\n' > "$R/AGENTS.md"
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  before="$(cksum < "$R/AGENTS.md")"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cksum < "$R/AGENTS.md")" = "$before" ]
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit agents-md: --check exits 1 and writes nothing when the file is missing" {
  make_pack sql
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
  [ "$status" -eq 1 ]
  [ "$output" = "would write $R/AGENTS.md" ]
  [ ! -e "$R/AGENTS.md" ]
}

@test "emit agents-md: --check exits 1 when the block was edited, and does not fix it" {
  make_pack sql
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  sed -i 's/Use `foo` for bar./Tampered./' "$R/AGENTS.md"
  before="$(cksum < "$R/AGENTS.md")"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
  [ "$status" -eq 1 ]
  [ "$(cksum < "$R/AGENTS.md")" = "$before" ]
  # A real emit then repairs it.
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
  [ "$status" -eq 0 ]
}

@test "emit agents-md: --check exits 1 when the pack list changed" {
  make_pack sql
  make_pack bash
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  run emit --harness agents-md --packs sql,bash --out "$R/AGENTS.md" --check
  [ "$status" -eq 1 ]
}

@test "emit agents-md: a block of exactly 12288 bytes is accepted, 12289 is refused" {
  # Measure the fixed overhead with a 20-byte body, then pad to the exact cap.
  pad_pack pad 20
  emit --harness agents-md --packs pad --out "$R/probe.md" >/dev/null
  base=$(wc -c < "$R/probe.md")
  pad_pack pad $((20 + 12288 - base))
  run emit --harness agents-md --packs pad --out "$R/at-cap.md"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$R/at-cap.md")" -eq 12288 ]
  pad_pack pad $((20 + 12289 - base))
  run emit --harness agents-md --packs pad --out "$R/over.md"
  [ "$status" -eq 3 ]
  [ ! -e "$R/over.md" ]
}

@test "emit agents-md: two packs over the cap exit 3 (nothing written) and leave the file unchanged" {
  pad_pack big1 7000
  pad_pack big2 7000
  printf 'user text\n%s\nold\n%s\nmore\n' "$BEGIN_LINE" "$END_LINE" > "$R/AGENTS.md"
  before="$(cksum < "$R/AGENTS.md")"
  run emit --harness agents-md --packs big1,big2 --out "$R/AGENTS.md"
  [ "$status" -eq 3 ]
  [[ "$output" == *"12288"* ]]
  [[ "$output" == *"nothing written"* ]]
  [ "$(cksum < "$R/AGENTS.md")" = "$before" ]
  # Each pack alone fits.
  run emit --harness agents-md --packs big1 --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "emit agents-md: over the cap with no existing file creates nothing" {
  pad_pack big1 7000
  pad_pack big2 7000
  run emit --harness gemini --packs big1,big2 --out "$R/deep/GEMINI.md"
  [ "$status" -eq 3 ]
  [ ! -e "$R/deep" ]
}

@test "emit agents-md: unbalanced or misordered markers exit 2 and write nothing" {
  make_pack sql
  local cases=(
    "$BEGIN_LINE\nno end\n"
    "no begin\n$END_LINE\n"
    "$BEGIN_LINE\na\n$END_LINE\n$BEGIN_LINE\nb\n$END_LINE\n"
    "$END_LINE\nbackwards\n$BEGIN_LINE\n"
    "$BEGIN_LINE\n$BEGIN_LINE\n$END_LINE\n"
  )
  local c
  for c in "${cases[@]}"; do
    printf "$c" > "$R/AGENTS.md"
    before="$(cksum < "$R/AGENTS.md")"
    run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"marker"* ]]
    [ "$(cksum < "$R/AGENTS.md")" = "$before" ]
    # The refusal also applies to an empty selection and to --check.
    run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
    [ "$status" -eq 2 ]
    run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
    [ "$status" -eq 2 ]
    [ "$(cksum < "$R/AGENTS.md")" = "$before" ]
  done
}

@test "emit agents-md: an empty --packs removes the block and keeps the surrounding text" {
  make_pack sql
  printf 'head\n' > "$R/AGENTS.md"
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  printf 'tail\n' >> "$R/AGENTS.md"
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" = "wrote $R/AGENTS.md" ]
  ! grep -q 'the-grid rules' "$R/AGENTS.md" || false
  grep -q '^head$' "$R/AGENTS.md"
  grep -q '^tail$' "$R/AGENTS.md"
  # Removing again is a no-op.
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit agents-md: an empty --packs truncates a block-only file to 0 bytes and keeps it (and its mode)" {
  make_pack sql
  : > "$R/GEMINI.md"
  chmod 600 "$R/GEMINI.md"
  emit --harness gemini --packs sql --out "$R/GEMINI.md" >/dev/null
  run emit --harness gemini --packs "" --out "$R/GEMINI.md" --check
  [ "$status" -eq 1 ]
  [ -s "$R/GEMINI.md" ]
  run emit --harness gemini --packs "" --out "$R/GEMINI.md"
  [ "$status" -eq 0 ]
  [ "$output" = "wrote $R/GEMINI.md" ]
  [ -f "$R/GEMINI.md" ]
  [ ! -s "$R/GEMINI.md" ]
  [ "$(stat -c %a "$R/GEMINI.md")" = 600 ]
  # Removing again is a no-op on the kept empty file.
  run emit --harness gemini --packs "" --out "$R/GEMINI.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit agents-md: an empty --packs on a missing file or a file with no block is a no-op" {
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$R/AGENTS.md" ]
  printf 'just user text\n' > "$R/AGENTS.md"
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$(cat "$R/AGENTS.md")" = "just user text" ]
}

@test "emit agents-md: unknown pack exits 2 and leaves the file unchanged" {
  make_pack sql
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  before="$(cksum < "$R/AGENTS.md")"
  run emit --harness agents-md --packs sql,nope --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown pack"* ]]
  [ "$(cksum < "$R/AGENTS.md")" = "$before" ]
}

@test "emit agents-md: --out that is an existing directory exits 2" {
  make_pack sql
  mkdir -p "$R/adir"
  run emit --harness agents-md --packs sql --out "$R/adir"
  [ "$status" -eq 2 ]
}

@test "emit agents-md: a malformed rule file exits 2 and writes nothing" {
  make_pack sql
  printf -- '---\npaths:\n  - "**/*.sql"\n' > "$R/rules/sql/broken.md"   # frontmatter never closed
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [ ! -e "$R/AGENTS.md" ]
}

# --- write safety (WP-052): atomic write, no symlinks, no tracebacks -----------------------------
# rules.py replaces the instruction file via a temp file in the same directory, so a failed
# write can never truncate the operator's file, and a symlinked --out is refused outright.

# no_tmp_left DIR: a failed or finished emit leaves no temp file next to the target.
no_tmp_left() { [ -z "$(find "$1" -maxdepth 1 -name '*.tmp' -print -quit)" ]; }

@test "emit agents-md: a failed write (file size limit) exits 2 with one line and keeps the original" {
  make_pack sql
  # ~9 KB of operator text, bigger than the 4 KB limit applied to the emit below.
  for i in $(seq 1 300); do printf 'operator line number %s\n' "$i"; done > "$R/AGENTS.md"
  cp "$R/AGENTS.md" "$R/orig"
  run bash -c 'ulimit -f 4; python3 "$1" emit --root "$2" --harness agents-md --packs sql --out "$3"' \
    _ "$REPO_ROOT/scripts/rules.py" "$R" "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [[ "$output" != *Traceback* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  cmp "$R/AGENTS.md" "$R/orig"
  no_tmp_left "$R"
}

@test "emit agents-md: a read-only file exits 2 with one line, no traceback, file unchanged" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  make_pack sql
  printf 'keep me\n' > "$R/AGENTS.md"
  chmod 444 "$R/AGENTS.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [[ "$output" != *Traceback* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [ "$(cat "$R/AGENTS.md")" = "keep me" ]
  no_tmp_left "$R"
}

@test "emit agents-md: a symlinked --out is refused for emit and for the empty selection" {
  make_pack sql
  printf 'victim text\n' > "$R/real.md"
  ln -s "$R/real.md" "$R/AGENTS.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"symlink"* ]]
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [ -L "$R/AGENTS.md" ]
  [ "$(cat "$R/real.md")" = "victim text" ]
}

@test "emit cursor: a symlink at a target path pointing at a marker-bearing file is refused, victim survives" {
  make_pack sql
  mkdir -p "$R/out"
  # A genuine generated file as the victim (marker right after the frontmatter).
  emit --harness cursor --packs sql --out "$R/gen" >/dev/null
  cp "$R/gen/grid-sql-style.mdc" "$R/victim.mdc"
  cp "$R/victim.mdc" "$R/victim.orig"
  ln -s "$R/victim.mdc" "$R/out/grid-sql-style.mdc"
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 2 ]
  cmp "$R/victim.mdc" "$R/victim.orig"
  [ -L "$R/out/grid-sql-style.mdc" ]
  # A stale symlinked grid-*.mdc is not removed either.
  ln -s "$R/victim.mdc" "$R/out/grid-gone-x.mdc"
  rm "$R/out/grid-sql-style.mdc"
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 0 ]
  [ -L "$R/out/grid-gone-x.mdc" ]
  cmp "$R/victim.mdc" "$R/victim.orig"
}

@test "emit agents-md: the file mode survives a rewrite and no temp file is left" {
  make_pack sql
  printf 'notes\n' > "$R/AGENTS.md"
  chmod 600 "$R/AGENTS.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$R/AGENTS.md")" = 600 ]
  no_tmp_left "$R"
}

@test "emit agents-md: a hard-linked second name keeps the old content (the replace breaks the link)" {
  make_pack sql
  printf 'notes\n' > "$R/AGENTS.md"
  ln "$R/AGENTS.md" "$R/other.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  grep -q 'the-grid rules' "$R/AGENTS.md"
  [ "$(cat "$R/other.md")" = "notes" ]
}

# --- separator and line endings (WP-052) ------------------------------------------------------
# `emit` then `emit ''` must give the operator's bytes back. A file with no final newline
# gains exactly one (documented: the original cannot be told apart from "newline-terminated").

# roundtrip INPUT_PRINTF_FORMAT EXPECTED_PRINTF_FORMAT
roundtrip() {
  printf "$1" > "$R/AGENTS.md"
  printf "$2" > "$R/expected"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  cmp "$R/AGENTS.md" "$R/expected"
}

@test "emit agents-md: emit then emit '' restores newline-terminated input byte for byte" {
  make_pack sql
  roundtrip 'hello\nworld\n' 'hello\nworld\n'
  roundtrip '\n' '\n'
  roundtrip '\xef\xbb\xbfhello\n' '\xef\xbb\xbfhello\n'
  roundtrip 'a\n\n' 'a\n\n'
  roundtrip 'a\n\n\n' 'a\n\n\n'
  roundtrip 'hello\r\nworld\r\n' 'hello\r\nworld\r\n'
  roundtrip '' ''
}

@test "emit agents-md: a file with no final newline gains exactly one newline after emit then remove" {
  make_pack sql
  roundtrip 'hello\nworld' 'hello\nworld\n'
  roundtrip 'hello\r\nworld' 'hello\r\nworld\r\n'
}

@test "emit agents-md: a CRLF file gets a CRLF block, and --check is clean after an editor re-save as CRLF" {
  make_pack sql
  printf 'one\r\ntwo\r\n' > "$R/AGENTS.md"
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  # Every LF in the file is part of a CRLF (no bare LF in the block).
  [ "$(grep -c $'\r$' "$R/AGENTS.md")" -eq "$(wc -l < "$R/AGENTS.md")" ]
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
  [ "$status" -eq 0 ]
  # An LF file that an editor re-saves with CRLF endings is not drift either.
  printf 'one\ntwo\n' > "$R/AGENTS.md"
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  sed -i 's/$/\r/' "$R/AGENTS.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md" --check
  [ "$status" -eq 0 ]
}

# --- marker handling and poisoning (WP-053) ---------------------------------------------------
# Markers match only our exact lines; rule bodies may not carry marker text; emit re-lints.

# A rule file whose fenced block holds a bare BEGIN/END marker pair (lint skips fenced text).
write_poison_rule() {
  printf -- '---\npaths:\n  - "**/*.sql"\n---\n# Poison\n\n```\n<!-- BEGIN the-grid rules -->\nx\n<!-- END the-grid rules -->\n```\n' > "$1"
}

@test "emit agents-md: a user fence quoting bare BEGIN/END lines survives emit and emit ''" {
  make_pack sql
  printf 'notes\n```\n<!-- BEGIN the-grid rules -->\nexample\n<!-- END the-grid rules -->\n```\n' > "$R/AGENTS.md"
  cp "$R/AGENTS.md" "$R/orig"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  head -c "$(wc -c < "$R/orig")" "$R/AGENTS.md" | cmp - "$R/orig"
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  cmp "$R/AGENTS.md" "$R/orig"
}

@test "emit agents-md: lines that merely start like the markers (rules-docs) are user text" {
  make_pack sql
  printf 'keep1\n<!-- BEGIN the-grid rules-docs -->\nuser text between\n<!-- END the-grid rules-docs -->\nkeep2\n' > "$R/AGENTS.md"
  cp "$R/AGENTS.md" "$R/orig"
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  cmp "$R/AGENTS.md" "$R/orig"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  grep -q 'user text between' "$R/AGENTS.md"
}

@test "E_MARKER: a marker line in a rule file is reported, bare or fenced, and a lone the-grid:rules mention too" {
  make_pack bare
  printf '<!-- BEGIN the-grid rules -->\n' >> "$R/rules/bare/style.md"
  expect_code E_MARKER
  rm -rf "$R/rules/bare"
  make_pack fenced
  write_poison_rule "$R/rules/fenced/style.md"
  expect_only E_MARKER
  rm -rf "$R/rules/fenced"
  make_pack mention
  printf -- '- Do not copy the-grid:rules lines.\n' >> "$R/rules/mention/style.md"
  expect_only E_MARKER
}

@test "E_MARKER: prose that merely says the-grid rules (with a space) is not flagged" {
  make_pack prose
  printf -- '- Follow the-grid rules for naming.\n' >> "$R/rules/prose/style.md"
  run lint
  [ "$status" -eq 0 ]
}

@test "emit refuses a rule body that carries a marker line and does not write it" {
  make_pack sql
  write_poison_rule "$R/rules/sql/style.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [ ! -e "$R/AGENTS.md" ]
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 2 ]
  [ ! -e "$R/out" ]
}

@test "emit agents-md: a pack that fails lint is excluded and named, the clean pack is delivered (exit 2)" {
  make_pack good
  make_pack bad
  write_poison_rule "$R/rules/bad/style.md"
  run --separate-stderr emit --harness agents-md --packs good,bad --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bad"* ]]
  [[ "$stderr" == *"E_MARKER"* ]]
  grep -q '^### good / style' "$R/AGENTS.md"
  ! grep -q '^### bad / ' "$R/AGENTS.md" || false
  # The delivered file still has exactly one block, so a later clean run can replace it.
  [ "$(grep -c '^<!-- BEGIN the-grid rules' "$R/AGENTS.md")" -eq 1 ]
}

@test "emit cursor: a pack that fails lint is excluded, the clean pack is written (exit 2)" {
  make_pack good
  make_pack bad
  write_poison_rule "$R/rules/bad/style.md"
  run emit --harness cursor --packs good,bad --out "$R/out"
  [ "$status" -eq 2 ]
  [ -f "$R/out/grid-good-style.mdc" ]
  [ ! -e "$R/out/grid-bad-style.mdc" ]
}

@test "render_block itself refuses marker text even when lint is bypassed (backstop)" {
  make_pack sql
  write_poison_rule "$R/rules/sql/style.md"
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/scripts')
import rules
try:
    rules.render_block('$R', ['sql'])
except rules.Refusal as exc:
    print('refused:', exc)
    sys.exit(0)
sys.exit(1)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused"* ]]
}

@test "emit: a rule-file lint finding (E_STYLE prose line) blocks that pack" {
  make_pack sql
  printf 'This is a prose paragraph line.\n' >> "$R/rules/sql/style.md"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 2 ]
  [ ! -e "$R/AGENTS.md" ]
}

@test "emit: pack-level findings (README, pack.yaml) do not block delivery" {
  make_pack sql
  rm "$R/rules/sql/README.md" "$R/rules/sql/pack.yaml"
  run emit --harness agents-md --packs sql --out "$R/AGENTS.md"
  [ "$status" -eq 0 ]
  [ -f "$R/AGENTS.md" ]
}

@test "emit cursor: a hand-written grid-*.mdc quoting the marker mid-file survives emit '' and is refused as a target" {
  make_pack sql
  mkdir -p "$R/out"
  printf -- '---\ndescription: mine\n---\nnotes\n<!-- the-grid:rules generated from rules/x/y.md; do not edit -->\nmore\n' > "$R/out/grid-mine.mdc"
  cp "$R/out/grid-mine.mdc" "$R/mine.orig"
  run emit --harness cursor --packs "" --out "$R/out"
  [ "$status" -eq 0 ]
  cmp "$R/out/grid-mine.mdc" "$R/mine.orig"
  cp "$R/out/grid-mine.mdc" "$R/out/grid-sql-style.mdc"
  run emit --harness cursor --packs sql --out "$R/out"
  [ "$status" -eq 2 ]
  cmp "$R/out/grid-sql-style.mdc" "$R/mine.orig"
}

# --- delivery wording and visibility (WP-054) -------------------------------------------------

@test "emit --check says would write / would remove and never wrote / removed" {
  make_pack sql
  make_pack bash
  # cursor: a missing file and a stale one.
  emit --harness cursor --packs sql,bash --out "$R/out" >/dev/null
  rm "$R/out/grid-sql-style.mdc"
  run emit --harness cursor --packs sql --out "$R/out" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"would write $R/out/grid-sql-style.mdc"* ]]
  [[ "$output" == *"would remove $R/out/grid-bash-style.mdc"* ]]
  [[ "$output" != *"wrote "* ]]
  [[ "$output" != *"removed "* ]]
  # agents-md: block present, empty selection.
  emit --harness agents-md --packs sql --out "$R/AGENTS.md" >/dev/null
  run emit --harness agents-md --packs "" --out "$R/AGENTS.md" --check
  [ "$status" -eq 1 ]
  [ "$output" = "would write $R/AGENTS.md" ]
}

# --- the real tree --------------------------------------------------------------------------

@test "real packs lint clean" {
  cd "$REPO_ROOT"
  run python3 scripts/rules.py lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
