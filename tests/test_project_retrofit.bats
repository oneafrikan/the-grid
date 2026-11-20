#!/usr/bin/env bats
# project-retrofit: retrofit.py moves blocks of an existing doc into the standard docs
# verbatim, and can prove nothing was lost. Fixtures are synthetic (tests/fixtures/retrofit
# plus files generated below); every run happens in a temp dir.

load helpers/setup
load helpers/portable

setup() {
  common_setup
  RF="$REPO_ROOT/project-factory/scripts/retrofit.py"
  FX="$REPO_ROOT/tests/fixtures/retrofit"
  R=$(mktemp_canon)    # the repo under retrofit
  T=$(mktemp_canon)    # plans and scratch, kept out of the repo tree
  export RETROFIT_DATE=2026-01-02
  # Generated fixtures: bytes that a committed text file could not keep reliably.
  printf '# Win\r\n\r\nline one\r\nline two\r\n\r\n- item\r\n  - sub\r\n' > "$T/crlf.md"
  printf '# Tabs\n\n-\tTabbed item\n\t- nested by tab\n\n\tindented paragraph\n' > "$T/tabs.md"
  printf '# No newline\n\nlast line without newline' > "$T/nonl.md"
  : > "$T/empty.md"
  printf '\n\n  \n\t\n' > "$T/blank.md"
  printf '\n\n# Leading blanks\n\n\n\nText   \n\n\n' > "$T/lead.md"
}

teardown() {
  rm -rf "$R" "$T"
  common_teardown
}

rf() { python3 "$RF" "$@"; }

# tree_sum DIR: checksum of every file below DIR (not .git).
tree_sum() { (cd "$1" && find . -name .git -prune -o -type f -exec cksum {} + | sort); }

# bid FILE N: id of the Nth block of FILE.
bid() { rf blocks "$1" | awk -v n="$2" '/^B[0-9]/ { c++; if (c == n) print $1 }'; }

# repo_docs: minimal destinations with headings to anchor on.
repo_docs() {
  printf '# Guardrails\n\nIntro.\n' > "$R/GUARDRAILS.md"
  printf '# Conventions\n\n## Naming\n\nname text\n\n## Common tasks\n\ntask text\n' > "$R/CONVENTIONS.md"
  printf '# Design\n' > "$R/DESIGN.md"
}

# plan_all SRCFILE REL DEST: a plan sending every block of SRCFILE (named REL in the repo) to DEST.
plan_all() {
  { echo "## source: $2"; rf blocks "$1" | awk -v d="$3" '/^B[0-9]/ { print $1 " -> " d }'; } > "$T/plan.txt"
}

# plain_plan: split plain.md (7 blocks) over keep, unsorted and two destinations.
plain_plan() {
  cp "$FX/plain.md" "$R/CLAUDE.md"
  repo_docs
  local f="$R/CLAUDE.md"
  cat > "$T/plan.txt" <<EOF
# comment lines are ignored
## source: CLAUDE.md
$(bid "$f" 1)..$(bid "$f" 2) -> keep
$(bid "$f" 3) -> unsorted
$(bid "$f" 4)..$(bid "$f" 5) -> CONVENTIONS.md#Naming
$(bid "$f" 6) -> DESIGN.md
$(bid "$f" 7) -> DESIGN.md
EOF
}

# ---- blocks: parser and round trip ----------------------------------------------------

@test "round trip: every fixture rebuilds byte for byte from its blocks" {
  for f in "$FX"/*.md "$T"/*.md; do
    rf blocks "$f" --rebuild > "$T/rebuilt.out"
    cmp "$f" "$T/rebuilt.out" || { echo "round trip failed: $f"; false; }
  done
}

@test "blocks: fenced code is atomic and a fake heading inside it is not a heading" {
  run rf blocks "$FX/mixed.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fence"* ]] || false
  [[ "$output" != *"fake heading"* ]] || false
  # the whole bash fence (6 lines, blank line inside it included) is one block
  [[ "$output" == *"L32-37  fence"* ]] || false
}

@test "blocks: nested list items stay inside their parent item" {
  run rf blocks "$FX/mixed.md"
  # "Always back up" item spans its nested items and their continuation paragraph
  [[ "$output" == *"L17-22  item"* ]] || false
  [[ "$output" != *"nested item one"* ]] || false
}

@test "blocks: front matter, table, comment, quote, rule and setext heading are units" {
  run rf blocks "$FX/mixed.md"
  [[ "$output" == *"L1-4  frontmatter"* ]] || false
  [[ "$output" == *"table"* ]] || false
  [[ "$output" == *"L48-49  comment"* ]] || false
  [[ "$output" == *"L51-52  quote"* ]] || false
  [[ "$output" == *"hr"* ]] || false
  [[ "$output" == *"L11-12  heading"* ]] || false
}

@test "blocks: duplicate blocks share a hash but get distinct indexes" {
  run rf blocks "$FX/dups.md"
  [ "$status" -eq 0 ]
  a=$(bid "$FX/dups.md" 2); b=$(bid "$FX/dups.md" 4)
  [ "${a#*-}" = "${b#*-}" ]
  [ "${a%%-*}" != "${b%%-*}" ]
}

@test "blocks: empty and blank-only files have zero blocks and still round trip" {
  run rf blocks "$T/empty.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 blocks"* ]] || false
  run rf blocks "$T/blank.md"
  [[ "$output" == *"0 blocks"* ]] || false
}

@test "blocks: hash ignores CRLF and trailing blanks, not words" {
  printf 'Same words\n' > "$T/a.md"
  printf 'Same words  \r\n' > "$T/b.md"
  printf 'Same word\n' > "$T/c.md"
  [ "$(bid "$T/a.md" 1)" = "$(bid "$T/b.md" 1)" ]
  [ "$(bid "$T/a.md" 1)" != "$(bid "$T/c.md" 1)" ]
}

# ---- plan parser: strict ---------------------------------------------------------------

# plan_fails ERRPART: the plan is rejected with exit 2, a line number, and nothing written.
plan_fails() {
  before=$(tree_sum "$R")
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan.txt:"*"$1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"nothing written"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
}

@test "plan error: unknown block id" {
  plain_plan
  printf '## source: CLAUDE.md\nB099-abcd -> keep\n' > "$T/plan.txt"
  plan_fails "unknown block id"
}

@test "plan error: stale hash" {
  plain_plan
  sed -i.bak "s/^\(B001-\)[0-9a-f]\{4\}/\10000/" "$T/plan.txt" && rm -f "$T/plan.txt.bak"
  plan_fails "stale hash"
}

@test "plan error: a block that is not mentioned" {
  plain_plan
  grep -v "DESIGN.md" "$T/plan.txt" > "$T/p2" && mv "$T/p2" "$T/plan.txt"
  plan_fails "not accounted for"
}

@test "plan error: a block mentioned twice" {
  plain_plan
  echo "$(bid "$R/CLAUDE.md" 1) -> keep" >> "$T/plan.txt"
  plan_fails "mentioned twice"
}

@test "plan error: destination path escapes the repo" {
  plain_plan
  echo x > "$T/outside.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md "../$(basename "$T")/outside.md"
  plan_fails "escapes the repo"
}

@test "plan error: destination reached through a symlink out of the repo" {
  plain_plan
  echo x > "$T/outside.md"
  ln -s "$T/outside.md" "$R/link.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md link.md
  plan_fails "escapes the repo"
  [ "$(cat "$T/outside.md")" = x ]
}

@test "plan error: absolute destination" {
  plain_plan
  plan_all "$R/CLAUDE.md" CLAUDE.md "$T/outside.md"
  plan_fails "escapes the repo"
}

@test "plan error: a standard doc that was not scaffolded yet" {
  plain_plan
  plan_all "$R/CLAUDE.md" CLAUDE.md HUMANS.md
  plan_fails "scaffold it first"
}

@test "plan error: a destination that is neither standard nor existing" {
  plain_plan
  plan_all "$R/CLAUDE.md" CLAUDE.md random.md
  plan_fails "not a standard doc and does not exist"
}

@test "plan error: the source cannot be its own destination, MAP.md is refused" {
  plain_plan
  plan_all "$R/CLAUDE.md" CLAUDE.md CLAUDE.md
  plan_fails "the source itself"
  echo "# Map" > "$R/MAP.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md MAP.md
  plan_fails "generated"
}

@test "plan error: a source outside the repo" {
  plain_plan
  plan_all "$T/crlf.md" "../$(basename "$T")/crlf.md" keep
  plan_fails "escapes the repo"
}

@test "plan error: unparseable line and heading anchor that does not exist" {
  plain_plan
  echo "this is not a mapping" >> "$T/plan.txt"
  plan_fails "cannot parse line"
  plain_plan
  plan_all "$R/CLAUDE.md" CLAUDE.md "CONVENTIONS.md#No such heading"
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found in destination"* ]] || false
}

# ---- apply -------------------------------------------------------------------------------

@test "apply: a dry run writes nothing and says what it would do" {
  plain_plan
  before=$(tree_sum "$R")
  run rf apply "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]] || false
  [[ "$output" == *"CONVENTIONS.md"*"2 block(s)"* ]] || false
  [[ "$output" == *"UNSORTED.md (will be created)"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
  [ ! -e "$R/UNSORTED.md" ]
}

@test "apply --yes: blocks land verbatim after a provenance comment, the source is byte-identical" {
  plain_plan
  src_before=$(cksum < "$R/CLAUDE.md")
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 0 ]
  [ "$src_before" = "$(cksum < "$R/CLAUDE.md")" ]
  grep -qF -- '<!-- moved from CLAUDE.md B004-' "$R/CONVENTIONS.md"
  grep -qxF -- '- a1' "$R/CONVENTIONS.md"
  grep -qxF -- '- a2' "$R/CONVENTIONS.md"
  grep -qxF -- 'Beta paragraph.' "$R/DESIGN.md"
  grep -qF -- '## Moved from CLAUDE.md' "$R/DESIGN.md"
}

@test "apply --yes: an anchor appends at the end of that heading's section, before the next heading" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  naming=$(grep -n '^name text' "$R/CONVENTIONS.md" | cut -d: -f1)
  a1=$(grep -n '^- a1' "$R/CONVENTIONS.md" | cut -d: -f1)
  tasks=$(grep -n '^## Common tasks' "$R/CONVENTIONS.md" | cut -d: -f1)
  [ "$naming" -lt "$a1" ]
  [ "$a1" -lt "$tasks" ]
  # text that was already there is untouched
  grep -qxF -- 'task text' "$R/CONVENTIONS.md"
}

@test "apply --yes twice: the second run adds nothing" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  after_one=$(tree_sum "$R")
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already applied"* ]] || false
  [[ "$output" == *"wrote 0 file(s)"* ]] || false
  [ "$after_one" = "$(tree_sum "$R")" ]
}

@test "apply --yes: unsorted blocks go to UNSORTED.md, created if absent" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  [ -f "$R/UNSORTED.md" ]
  grep -qxF -- '## Section A' "$R/UNSORTED.md"
  grep -qF -- '<!-- moved from CLAUDE.md B003-' "$R/UNSORTED.md"
}

@test "apply --yes: every fixture moved whole into one doc keeps all its text" {
  repo_docs
  for f in "$FX/mixed.md" "$FX/dups.md" "$T/crlf.md" "$T/tabs.md" "$T/nonl.md" "$T/lead.md"; do
    cp "$f" "$R/CLAUDE.md"
    plan_all "$R/CLAUDE.md" CLAUDE.md DESIGN.md
    run rf apply "$T/plan.txt" --repo "$R" --yes
    [ "$status" -eq 0 ]
    run rf check "$T/plan.txt" --repo "$R"
    [ "$status" -eq 0 ] || { echo "$f: $output"; false; }
    printf '# Design\n' > "$R/DESIGN.md"
  done
}

@test "apply --yes: CRLF source text lands byte-identical in an LF destination" {
  repo_docs
  cp "$T/crlf.md" "$R/CLAUDE.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md DESIGN.md
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  grep -qF "$(printf 'line one\r')" "$R/DESIGN.md"
}

# ---- check -------------------------------------------------------------------------------

@test "check: passes after a good apply, with counts" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accounted: 7/7"*"missing or altered: 0"* ]] || false
  [[ "$output" == *"DESIGN.md"* ]] || false
}

@test "check: fails when a moved block is deleted from its destination" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  grep -vxF -- '- a2' "$R/CONVENTIONS.md" > "$T/c" && mv "$T/c" "$R/CONVENTIONS.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING CLAUDE.md:B005-"* ]] || false
}

@test "check: fails when a moved block is edited by one character" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  sed_i 's/^Beta paragraph\./Beta paragraph!/' "$R/DESIGN.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING CLAUDE.md:B007-"* ]] || false
}

@test "check: fails when an unsorted block is removed from UNSORTED.md" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  rm "$R/UNSORTED.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNSORTED.md"* ]] || false
}

@test "check: duplicate blocks need as many copies as the source had" {
  repo_docs
  cp "$FX/dups.md" "$R/CLAUDE.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md DESIGN.md
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  # drop one of the two copies of the repeated paragraph
  awk '/^Same paragraph twice\.$/ { if (seen++) next } { print }' "$R/DESIGN.md" > "$T/d" && mv "$T/d" "$R/DESIGN.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
}

@test "check: a source edited after the plan was made is a stale plan (exit 2), not a pass" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  # the source changed since blocks: plan is stale (exit 2), not silently passing
  printf '# Plain\n' > "$R/CLAUDE.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 2 ]
}

@test "check --report: writes a coverage file listing every block and where it went" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  run rf check "$T/plan.txt" --repo "$R" --report
  [ "$status" -eq 0 ]
  rep="$R/docs/archive/retrofit-CLAUDE.md-2026-01-02-coverage.md"
  [ -f "$rep" ]
  grep -qF 'Result: PASS (7 of 7 blocks accounted)' "$rep"
  [ "$(grep -c '^| B0' "$rep")" -eq 7 ]
  grep -qF '| keep | ok |' "$rep"
  grep -qF '| UNSORTED.md | ok |' "$rep"
  grep -qF '| CONVENTIONS.md | ok |' "$rep"
  grep -qF 'Alpha paragraph.' "$rep"
}

# ---- finalize ----------------------------------------------------------------------------

# git_repo: make $R a git repo with everything committed.
git_repo() {
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" -c user.email=t@example.com -c user.name=t commit -q -m init
}

@test "finalize: refuses while check fails, changing nothing" {
  plain_plan
  git_repo
  printf '# Slim\n' > "$T/slim.md"
  before=$(tree_sum "$R")
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"finalize refused: check fails"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
}

@test "finalize: a dry run changes nothing; --yes archives the original and installs the slim doc" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/slim.md"
  orig=$(cksum < "$R/CLAUDE.md")
  before=$(tree_sum "$R")
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Undo: git checkout -- CLAUDE.md"* ]] || false
  [ "$orig" = "$(cksum < "$R/docs/archive/CLAUDE.md.2026-01-02.orig")" ]
  cmp "$T/slim.md" "$R/CLAUDE.md"
}

@test "finalize: never overwrites an existing archive" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  mkdir -p "$R/docs/archive"
  echo precious > "$R/docs/archive/CLAUDE.md.2026-01-02.orig"
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/slim.md"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"archive already exists"* ]] || false
  [ "$(cat "$R/docs/archive/CLAUDE.md.2026-01-02.orig")" = precious ]
  cmp "$FX/plain.md" "$R/CLAUDE.md"
}

@test "finalize: refuses a replacement that lacks a keep block" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  printf '# Slim\n\nNothing kept.\n' > "$T/slim.md"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"KEEP BLOCK NOT IN REPLACEMENT"* ]] || false
  cmp "$FX/plain.md" "$R/CLAUDE.md"
}

@test "finalize: refuses an uncommitted source unless --allow-dirty" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/slim.md"
  printf '\n' >> "$R/CLAUDE.md"
  # the blank line is trailing whitespace of the last block, so the plan is still valid
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"not tracked-and-clean"* ]] || false
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes --allow-dirty
  [ "$status" -eq 0 ]
}

# ---- survey ------------------------------------------------------------------------------

@test "survey: lists sources with sizes and block counts, and changes nothing" {
  cp "$FX/mixed.md" "$R/CLAUDE.md"
  cp "$FX/plain.md" "$R/TODO.md"
  mkdir -p "$R/LOGS" "$R/docs"
  : > "$R/LOGS/2026-01-01-handoff.md"
  cp "$FX/plain.md" "$R/docs/guide.md"
  printf '# Guardrails\n' > "$R/GUARDRAILS.md"
  before=$(tree_sum "$R")
  run rf survey "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE.md"*"23 blocks"* ]] || false
  [[ "$output" == *"TODO.md"*"7 blocks"* ]] || false
  [[ "$output" == *"docs/guide.md"* ]] || false
  [[ "$output" == *"2026-01-01-handoff.md"* ]] || false
  [[ "$output" == *"GUARDRAILS.md"*"exists"* ]] || false
  [[ "$output" == *"DESIGN.md"*"missing"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
}

@test "usage errors exit 2 and the script is portable python (no third-party imports)" {
  run rf bogus
  [ "$status" -eq 2 ]
  run rf apply "$T/nope.txt" --repo "$R"
  [ "$status" -eq 2 ]
  ! grep -E '^(import|from) (yaml|requests|numpy)' "$RF"
}
