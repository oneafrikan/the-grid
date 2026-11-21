#!/usr/bin/env bats
# project-retrofit: retrofit.py moves blocks of an existing doc into the standard docs
# verbatim, and can prove nothing was lost. Fixtures are synthetic (tests/fixtures/retrofit
# plus files generated below); every run happens in a temp dir.

load helpers/setup
load helpers/portable

setup() {
  common_setup
  isolate_git_config    # commits below must not read the operator's global git config
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

# blk FILE [ARGS]: `blocks` for FILE, run from FILE's directory with its bare name. `blocks` takes a
# path relative to the repo root (the cwd) and refuses an absolute one, so tests that name files
# by absolute path go through this.
blk() { local f="$1"; shift; (cd "$(dirname "$f")" && python3 "$RF" blocks "$(basename "$f")" "$@"); }

# tree_sum DIR: checksum of every file below DIR (not .git).
tree_sum() { (cd "$1" && find . -name .git -prune -o -type f -exec cksum {} + | sort); }

# bid FILE N: id of the Nth block of FILE.
bid() { blk "$1" | awk -v n="$2" '/^B[0-9]/ { c++; if (c == n) print $1 }'; }

# repo_docs: minimal destinations with headings to anchor on.
repo_docs() {
  printf '# Guardrails\n\nIntro.\n' > "$R/GUARDRAILS.md"
  printf '# Conventions\n\n## Naming\n\nname text\n\n## Common tasks\n\ntask text\n' > "$R/CONVENTIONS.md"
  printf '# Design\n' > "$R/DESIGN.md"
}

# sha_of FILE: sha256 of the whole file (the plan header pins it).
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# hdr REL: the plan header line for the repo file REL, as `blocks` prints it.
hdr() { echo "## source: $1 sha256:$(sha_of "$R/$1")"; }

# plan_all SRCFILE REL DEST: a plan sending every block of SRCFILE (named REL in the repo) to DEST.
plan_all() {
  { echo "## source: $2 sha256:$(sha_of "$1")"; blk "$1" | awk -v d="$3" '/^B[0-9]/ { print $1 " -> " d }'; } > "$T/plan.txt"
}

# plain_plan: split plain.md (7 blocks) over keep, unsorted and two destinations.
plain_plan() {
  cp "$FX/plain.md" "$R/CLAUDE.md"
  repo_docs
  local f="$R/CLAUDE.md"
  cat > "$T/plan.txt" <<EOF
# comment lines are ignored
$(hdr CLAUDE.md)
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
    blk "$f" --rebuild > "$T/rebuilt.out"
    cmp "$f" "$T/rebuilt.out" || { echo "round trip failed: $f"; false; }
  done
}

@test "blocks: fenced code is atomic and a fake heading inside it is not a heading" {
  run blk "$FX/mixed.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fence"* ]] || false
  [[ "$output" != *"fake heading"* ]] || false
  # the whole bash fence (6 lines, blank line inside it included) is one block
  [[ "$output" == *"L32-37  fence"* ]] || false
}

@test "blocks: nested list items stay inside their parent item" {
  run blk "$FX/mixed.md"
  # "Always back up" item spans its nested items and their continuation paragraph
  [[ "$output" == *"L17-22  item"* ]] || false
  [[ "$output" != *"nested item one"* ]] || false
}

@test "blocks: front matter, table, comment, quote, rule and setext heading are units" {
  run blk "$FX/mixed.md"
  [[ "$output" == *"L1-4  frontmatter"* ]] || false
  [[ "$output" == *"table"* ]] || false
  [[ "$output" == *"L48-49  comment"* ]] || false
  [[ "$output" == *"L51-52  quote"* ]] || false
  [[ "$output" == *"hr"* ]] || false
  [[ "$output" == *"L11-12  heading"* ]] || false
}

@test "blocks: duplicate blocks share a hash but get distinct indexes" {
  run blk "$FX/dups.md"
  [ "$status" -eq 0 ]
  a=$(bid "$FX/dups.md" 2); b=$(bid "$FX/dups.md" 4)
  [ "${a#*-}" = "${b#*-}" ]
  [ "${a%%-*}" != "${b%%-*}" ]
}

@test "blocks: empty and blank-only files have zero blocks and still round trip" {
  run blk "$T/empty.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 blocks"* ]] || false
  run blk "$T/blank.md"
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
  printf '%s\nB099-abcd -> keep\n' "$(hdr CLAUDE.md)" > "$T/plan.txt"
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
  git -C "$R" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m init
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
  [[ "$output" == *"mv 'docs/archive/CLAUDE.md.2026-01-02.orig' 'CLAUDE.md'"* ]] || false
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
  [[ "$output" == *"archive already exists and differs"* ]] || false
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
  git -C "$R" rm -q --cached CLAUDE.md    # untracked now; the bytes (and so the plan's sha256) are unchanged
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

# ======================================================================================
# Hardening: every false pass found in independent QA must now fail (or be refused)
# ======================================================================================

# mini SRC [DEST]: a source (block 1 -> keep, the rest -> D.md) and a destination; applied.
mini() {
  printf '%b' "$1" > "$R/CLAUDE.md"
  printf '%b' "${2:-# D\n}" > "$R/D.md"
  { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1) -> keep"
    blk "$R/CLAUDE.md" | awk '/^B[0-9]/ { c++; if (c > 1) print $1 " -> D.md" }'; } > "$T/plan.txt"
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
}

@test "check: text that only sits inside a fenced block of the destination does not count" {
  mini '# T\n\n- Never commit secrets.\n'
  awk '$0 == "- Never commit secrets." { print "```"; print; print "```"; next } { print }' "$R/D.md" > "$T/d" && mv "$T/d" "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"* ]] || false
}

@test "check: text that only sits inside an HTML comment of the destination does not count" {
  mini '# T\n\n- Never commit secrets.\n'
  awk '$0 == "- Never commit secrets." { print "<!--"; print; print "-->"; next } { print }' "$R/D.md" > "$T/d" && mv "$T/d" "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
}

@test "check: a block that is only a line inside a longer destination block does not count" {
  mini '# T\n\nAlpha\n\nAlpha\nBeta\n'
  # drop the standalone Alpha; the Alpha line still sits inside the "Alpha / Beta" block
  awk '/^Alpha$/ && !done { done = 1; getline; next } { print }' "$R/D.md" > "$T/d" && mv "$T/d" "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
}

@test "check: one destination block cannot satisfy two source blocks" {
  mini '# T\n\nSame line.\n\nSame line.\n'
  awk '/^Same line\.$/ { if (seen++) next } { print }' "$R/D.md" > "$T/d" && mv "$T/d" "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
}

@test "check: a destination file that was deleted is a coverage failure (exit 1) naming the file" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  rm "$R/DESIGN.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DESIGN.md"*"file does not exist"* ]] || false
}

@test "blocks prints the plan header with the sha256 of the whole file" {
  cp "$FX/plain.md" "$R/CLAUDE.md"
  run bash -c "cd '$R' && python3 '$RF' blocks CLAUDE.md"
  [[ "$output" == *"## source: CLAUDE.md sha256:$(sha_of "$R/CLAUDE.md")"* ]] || false
}

@test "plan: a header without sha256 is rejected" {
  plain_plan
  sed_i 's/ sha256:[0-9a-f]*//' "$T/plan.txt"
  plan_fails "malformed source header"
}

@test "stale source: an edit in the MIDDLE of a range is caught before apply (exit 2, nothing written)" {
  plain_plan
  sed_i 's/^- a1$/- a1 changed/' "$R/CLAUDE.md"
  plan_fails "changed since 'blocks'"
}

@test "stale source: a middle block replaced by a different block (same count, same end ids) is caught" {
  printf '# T\n\nFirst.\n\nMiddle.\n\nLast.\n' > "$R/CLAUDE.md"
  repo_docs
  { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1)..$(bid "$R/CLAUDE.md" 4) -> DESIGN.md"; } > "$T/plan.txt"
  printf '# T\n\nFirst.\n\nSwapped in.\n\nLast.\n' > "$R/CLAUDE.md"
  plan_fails "changed since 'blocks'"
}

@test "stale source: an edit after apply makes check exit 2, not pass" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  sed_i 's/^- a1$/- a1 changed/' "$R/CLAUDE.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 2 ]
}

@test "an empty, comment-only or header-less plan is exit 2 for every subcommand" {
  plain_plan
  : > "$T/empty.txt"
  printf '# only a comment\n' > "$T/comment.txt"
  hdr CLAUDE.md > "$T/headeronly.txt"
  printf 'B001-aaaa -> keep\n' > "$T/noheader.txt"
  for p in empty comment headeronly noheader; do
    for c in apply check keep; do
      run rf "$c" "$T/$p.txt" --repo "$R"
      [ "$status" -eq 2 ] || { echo "$c $p: $status"; false; }
    done
    run rf finalize "$T/$p.txt" --repo "$R" --replace-with "$T/crlf.md"
    [ "$status" -eq 2 ] || { echo "finalize $p: $status"; false; }
  done
}

@test "destinations: only existing .md or .txt text files; no dotfiles, binaries or hard links to the source" {
  plain_plan
  printf 'KEY=1\n' > "$R/.env"
  printf 'print(1)\n' > "$R/app.py"
  printf '# bin\n\xff\xfe\n' > "$R/bin.md"
  ln "$R/CLAUDE.md" "$R/hard.md"
  for d in .env app.py bin.md hard.md; do
    plan_all "$R/CLAUDE.md" CLAUDE.md "$d"
    before=$(tree_sum "$R")
    run rf apply "$T/plan.txt" --repo "$R" --yes
    [ "$status" -eq 2 ] || { echo "$d: $output"; false; }
    [ "$before" = "$(tree_sum "$R")" ] || { echo "$d changed the tree"; false; }
  done
}

@test "destinations: the plan file itself and another source of the plan are refused" {
  plain_plan
  cp "$FX/plain.md" "$R/OTHER.md"
  cp "$T/plan.txt" "$R/inrepo-plan.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md inrepo-plan.md
  cp "$T/plan.txt" "$R/inrepo-plan.md"
  run rf apply "$R/inrepo-plan.md" --repo "$R"
  [ "$status" -eq 2 ]
  [[ "$output" == *"the plan file"* ]] || false
  plan_all "$R/CLAUDE.md" CLAUDE.md OTHER.md
  hdr OTHER.md >> "$T/plan.txt"
  blk "$R/OTHER.md" | awk '/^B[0-9]/ { print $1 " -> keep" }' >> "$T/plan.txt"
  run rf apply "$T/plan.txt" --repo "$R"
  [ "$status" -eq 2 ]
  [[ "$output" == *"another source of this plan"* ]] || false
}

@test "apply refuses a destination that ends inside an unclosed fence or comment" {
  plain_plan
  printf '# Design\n\n```\nnever closed\n' > "$R/DESIGN.md"
  before=$(tree_sum "$R")
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"unclosed"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
  printf '# Design\n\n<!-- todo\n' > "$R/DESIGN.md"
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"unclosed"* ]] || false
}

@test "apply separates appended text from a trailing list item with a blank line" {
  printf '# Plain\n\nMoved paragraph.\n' > "$R/CLAUDE.md"
  printf '# D\n\n- last item\n  continues' > "$R/D.md"    # no trailing newline
  { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1) -> keep"; echo "$(bid "$R/CLAUDE.md" 2) -> D.md#D"; } > "$T/plan.txt"
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 0 ]
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  # the existing item is still one block of its own and the provenance comment is a block
  run blk "$R/D.md"
  [[ "$output" == *"item"*"- last item"* ]] || false
  [[ "$output" == *"comment"* ]] || false
  grep -qxF -- '  continues' "$R/D.md"
}

@test "apply: a lookalike provenance comment does not hide a missing block (refused, exit 2)" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  grep -v '^- a2$' "$R/CONVENTIONS.md" > "$T/c" && mv "$T/c" "$R/CONVENTIONS.md"
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to apply"* ]] || false
}

# ---- anchors keep plan order ---------------------------------------------------------

@test "anchors: two runs into one heading land in plan order, a moved heading does not confuse a later anchor" {
  printf 'First.\n\n## Wellness\n\nSecond.\n\nThird.\n' > "$R/a.md"
  printf '# D\n\n## Sec\n\nbody\n\n## Wellness\n\nw original\n' > "$R/D.md"
  f="$R/a.md"
  { hdr a.md
    echo "$(bid "$f" 1)..$(bid "$f" 2) -> D.md#Sec"
    echo "$(bid "$f" 3) -> D.md#Sec"
    echo "$(bid "$f" 4) -> D.md#Wellness"; } > "$T/plan.txt"
  run rf apply "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"level-2 heading"* ]] || false
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  l() { grep -n -- "$1" "$R/D.md" | head -1 | cut -d: -f1; }
  [ "$(l '^body')" -lt "$(l '^First\.')" ]
  [ "$(l '^First\.')" -lt "$(l '^Second\.')" ]
  [ "$(l '^Second\.')" -lt "$(l '^w original')" ]
  [ "$(l '^w original')" -lt "$(l '^Third\.')" ]
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
}

# ---- preflight, exit codes ------------------------------------------------------------

@test "apply preflight: an unwritable directory stops the run before ANY file is written" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  plain_plan
  mkdir "$R/sub"
  printf '# Sub\n' > "$R/sub/S.md"
  sed_i 's|-> DESIGN.md|-> sub/S.md|' "$T/plan.txt"
  chmod 555 "$R/sub"
  before=$(tree_sum "$R")
  run rf apply "$T/plan.txt" --repo "$R" --yes
  chmod 755 "$R/sub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not writable"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
  [ ! -e "$R/UNSORTED.md" ]
}

@test "errors are one line, never a traceback" {
  [ "$(id -u)" -ne 0 ] || skip "root can read anything"
  printf '# x\n' > "$T/unreadable.md"
  chmod 000 "$T/unreadable.md"
  run blk "$T/unreadable.md"
  chmod 644 "$T/unreadable.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"retrofit: PermissionError"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
  plain_plan
  printf '\xff\xfe' > "$T/plan.txt"
  run rf apply "$T/plan.txt" --repo "$R"
  [ "$status" -eq 2 ]
  [[ "$output" != *"Traceback"* ]] || false
}

# ---- finalize: undo, retry, several sources -----------------------------------------------

@test "finalize: the printed undo (mv) restores exactly the original, for a clean and a dirty source" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/slim.md"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 0 ]
  cmd=$(printf '%s\n' "$output" | sed -n "s/^done. Undo.*: //p")
  [[ "$cmd" == "mv "* ]] || false
  (cd "$R" && eval "$cmd")
  cmp "$FX/plain.md" "$R/CLAUDE.md"
  [ ! -e "$R/docs/archive/CLAUDE.md.2026-01-02.orig" ]
  # dirty: untracked source, --allow-dirty
  git -C "$R" rm -q --cached CLAUDE.md
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes --allow-dirty
  [ "$status" -eq 0 ]
  cmd=$(printf '%s\n' "$output" | sed -n "s/^done. Undo.*: //p")
  (cd "$R" && eval "$cmd")
  cmp "$FX/plain.md" "$R/CLAUDE.md"
}

@test "finalize: a retry reuses a byte-identical archive left by a failed replace" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/slim.md"
  mkdir -p "$R/docs/archive"
  cp "$R/CLAUDE.md" "$R/docs/archive/CLAUDE.md.2026-01-02.orig"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"archive already holds"* ]] || false
  cmp "$T/slim.md" "$R/CLAUDE.md"
}

@test "finalize: a keep block only inside a fence, or reworded, in the replacement is refused" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  printf '# Plain\n\n```\nAlpha paragraph.\n```\n' > "$T/slim.md"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 1 ]
  printf '# Plain\n\nAlpha paragraph (reworded).\n' > "$T/slim.md"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 1 ]
  cmp "$FX/plain.md" "$R/CLAUDE.md"
}

@test "several sources: finalize A, check still passes, then finalize B with the same plan" {
  printf '# A\n\nOne.\n' > "$R/CLAUDE.md"
  printf '# N\n\nTwo.\n' > "$R/NOTES.md"
  printf '# D\n' > "$R/D.md"
  { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1) -> keep"; echo "$(bid "$R/CLAUDE.md" 2) -> D.md"
    hdr NOTES.md; echo "$(bid "$R/NOTES.md" 1) -> keep"; echo "$(bid "$R/NOTES.md" 2) -> D.md"; } > "$T/plan.txt"
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  printf '# A\n' > "$T/sa.md"
  printf '# N\n' > "$T/sn.md"
  run rf finalize "$T/plan.txt" --repo "$R" --source CLAUDE.md --replace-with "$T/sa.md" --yes
  [ "$status" -eq 0 ]
  cmp "$T/sa.md" "$R/CLAUDE.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"read from its archive"* ]] || false
  run rf finalize "$T/plan.txt" --repo "$R" --source NOTES.md --replace-with "$T/sn.md" --yes
  [ "$status" -eq 0 ]
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  # finalizing A twice is refused, not repeated
  run rf finalize "$T/plan.txt" --repo "$R" --source CLAUDE.md --replace-with "$T/sa.md" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"already finalized"* ]] || false
}

# ======================================================================================
# QA follow-ups: raw HTML blocks, finalize line limit, speed, path message
# ======================================================================================

@test "check: text that only sits inside a raw HTML script/style/pre/textarea block does not count" {
  for open in '<pre>' '<PRE class="x">' '<style>' '<script type="text/x">' '<textarea>'; do
    close="</$(printf '%s' "$open" | sed 's/^<\([A-Za-z]*\).*/\1/')>"
    mini '# T\n\nNever delete prod.\n'
    # blank lines inside the raw block: a paragraph of its own would otherwise match
    printf '# D\n\n%s\n\nNever delete prod.\n\n%s\n' "$open" "$close" > "$R/D.md"
    run rf check "$T/plan.txt" --repo "$R"
    [ "$status" -eq 1 ] || { echo "$open: status $status"; false; }
    [[ "$output" == *"MISSING"* ]] || false
  done
}

@test "check: text after a properly closed raw HTML block still counts" {
  mini '# T\n\nNever delete prod.\n'
  printf '# D\n\n<pre>\nx\n</pre>\n\nNever delete prod.\n' > "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  # a one-line block closes itself
  printf '# D\n\n<style>b{}</style>\n\nNever delete prod.\n' > "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  # an end tag of another raw kind closes it too (CommonMark)
  printf '# D\n\n<script>\nx\n</style>\n\nNever delete prod.\n' > "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
}

@test "check: an unclosed raw HTML block hides everything after it" {
  mini '# T\n\nNever delete prod.\n'
  printf '# D\n\n<pre>\nopen\n\nNever delete prod.\n' > "$R/D.md"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
}

@test "apply refuses a destination that ends inside an unclosed raw HTML block" {
  plain_plan
  for open in '<style>' '<SCRIPT src=x>' '<pre>' '<textarea>'; do
    printf '# Design\n\n%s\nbody{}\n' "$open" > "$R/DESIGN.md"
    before=$(tree_sum "$R")
    run rf apply "$T/plan.txt" --repo "$R" --yes
    [ "$status" -eq 2 ] || { echo "$open: status $status"; false; }
    [[ "$output" == *"unclosed"* ]] || false
    [[ "$output" == *"<style>"* ]] || false
    [ "$before" = "$(tree_sum "$R")" ]
  done
}

@test "apply: a moved raw HTML block that never closes is refused, not left to swallow what follows" {
  printf '# S\n\n<style>\nbody{}\n' > "$R/CLAUDE.md"
  printf '# D\n\n## A\n\nx\n\n## B\n\ny\n' > "$R/D.md"
  { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1) -> keep"; echo "$(bid "$R/CLAUDE.md" 2) -> D.md#A"; } > "$T/plan.txt"
  before=$(tree_sum "$R")
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 2 ]
  [ "$before" = "$(tree_sum "$R")" ]
}

@test "blocks --rebuild is byte-identical for raw HTML blocks (closed, unclosed, nested, uppercase, in items)" {
  printf 'a\n<pre>\nx\n\n</pre>\nb\n\n<STYLE media="x">\n.a{}\n</Style>\n\n<script>\n<pre>\n</script>\nz\n\n- item\n  <textarea>\n\n  t\n  </textarea>\n- two\n\n<pre>\nnever closed\n\ntail' > "$T/raw.md"
  printf 'x <pre>\n    <pre>\n<prefix>\n<pre/>\n<scripts>\n<styles>\n' > "$T/rawmix.md"
  for f in raw rawmix; do
    blk "$T/$f.md" --rebuild > "$T/$f.out"
    cmp "$T/$f.md" "$T/$f.out"
  done
  run blk "$T/raw.md"
  [[ "$output" == *"html"* ]] || false
  # a raw-block start line interrupts a paragraph ("a" / "<pre>"); <pre/>, <scripts>, <prefix> do not
  [[ "$output" == *"L1-1  "*"L2-"*"html"* ]] || { echo "$output"; false; }
  run blk "$T/rawmix.md"
  [[ "$output" != *"html"* ]] || { echo "$output"; false; }
}

@test "finalize: a replacement over the line limit is refused (dry run too); --max-lines overrides" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/slim.md"
  # pad to exactly 60 lines (allowed), then 61 (refused)
  while [ "$(wc -l < "$T/slim.md" | tr -d ' ')" -lt 60 ]; do echo "pad" >> "$T/slim.md"; done
  [ "$(wc -l < "$T/slim.md" | tr -d ' ')" -eq 60 ]
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md"
  [ "$status" -eq 0 ]
  echo "pad" >> "$T/slim.md"
  before=$(tree_sum "$R")
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"61 lines"* ]] || false
  [[ "$output" == *"--max-lines"* ]] || false
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"61 lines"* ]] || false
  [ "$before" = "$(tree_sum "$R")" ]
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --max-lines 60
  [ "$status" -eq 2 ]
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --max-lines 61
  [ "$status" -eq 0 ]
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --max-lines 0 --yes
  [ "$status" -eq 0 ]
  cmp "$T/slim.md" "$R/CLAUDE.md"
}

@test "check: 1500 altered blocks that share a first line finish fast (was quadratic)" {
  python3 - "$R" <<'PY'
import sys
r = sys.argv[1]
n = 1500
open(r + "/S.md", "w").write("".join("X\ny%d\n\n" % i for i in range(n)))
open(r + "/D.md", "w").write("".join("X\nz%d\n\n" % i for i in range(n)))
PY
  { hdr S.md; echo "$(bid "$R/S.md" 1)..$(bid "$R/S.md" 1500) -> D.md"; } > "$T/plan.txt"
  # about 0.2 s now and 20 s before the fix; 5 s leaves slack for a slow machine (timeout exits 124)
  run timeout 5 python3 "$RF" check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing or altered: 1500"* ]] || false
}

@test "check: the run matcher pairs a multi-block run once; a second source block needs a second run" {
  # front matter, mid-file, re-parses as a rule plus a heading: a run of two destination blocks
  printf -- '---\ntitle: T\n---\n\nBody.\n' > "$R/CLAUDE.md"
  printf '# D\n\nintro\n\n---\ntitle: T\n---\n\nBody.\n' > "$R/D.md"
  { hdr CLAUDE.md; blk "$R/CLAUDE.md" | awk '/^B[0-9]/ { print $1 " -> D.md" }'; } > "$T/plan.txt"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 0 ]
  # two identical source blocks need two destination runs; one copy is not enough
  printf -- 'title: T\n\n---\ntitle: T\n---\n' > "$R/CLAUDE.md"
  printf -- '# D\n\n---\ntitle: T\n---\n' > "$R/D.md"
  { hdr CLAUDE.md; blk "$R/CLAUDE.md" | awk '/^B[0-9]/ { print $1 " -> D.md" }'; } > "$T/plan.txt"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 1 ]
}

@test "blocks: an absolute path or a path outside the repo is refused with the fix, exit 2" {
  printf '# A\n\nx\n' > "$R/A.md"
  printf '# O\n' > "$T/out.md"
  run python3 "$RF" blocks "$R/A.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"use a relative path from the repo root"* ]] || false
  [[ "$output" != *"## source"* ]] || false
  cd "$R"
  run python3 "$RF" blocks "../$(basename "$T")/out.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"use a relative path from the repo root"* ]] || false
  run python3 "$RF" blocks A.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"## source: A.md sha256:"* ]] || false
}

@test "plan error: an absolute source path is one clear line, not a cascade" {
  plain_plan
  sed "s|^## source: CLAUDE.md|## source: $R/CLAUDE.md|" "$T/plan.txt" > "$T/p2" && mv "$T/p2" "$T/plan.txt"
  run rf check "$T/plan.txt" --repo "$R"
  [ "$status" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c 'plan.txt:')" -eq 1 ]
  [[ "$output" == *"use a relative path from the repo root"* ]] || false
  [[ "$output" != *"outside a valid"* ]] || false
}

# ---- the other CommonMark raw HTML kinds (<? ?>, <!LETTER >, <![CDATA[ ]]>), run-end refusal, BOM ----

@test "check: text hidden in a <? ?>, <!DOCTYPE/<!ELEMENT >, or <![CDATA[ ]]> block does not count" {
  # each row: opener, closer
  for pair in '<?php|?>' '<![CDATA[|]]>' '<!DOCTYPE html|>' '<!ELEMENT x|>' '  <?xml|?>'; do
    open="${pair%|*}"; close="${pair##*|}"
    mini '# T\n\nNever delete prod.\n'
    printf '# D\n\n%s\n\nNever delete prod.\n\n%s\n' "$open" "$close" > "$R/D.md"
    run rf check "$T/plan.txt" --repo "$R"
    [ "$status" -eq 1 ] || { echo "$open: status $status"; false; }
    # closed on its own line, the text after it counts again
    printf '# D\n\n%s\nx\n%s\n\nNever delete prod.\n' "$open" "$close" > "$R/D.md"
    run rf check "$T/plan.txt" --repo "$R"
    [ "$status" -eq 0 ] || { echo "$open closed: status $status"; false; }
  done
  # one-line forms close themselves; <! without a letter (<!-- is a comment, <![x]) is not this kind
  mini '# T\n\nNever delete prod.\n'
  for one in '<?php echo 1; ?>' '<!DOCTYPE html>' '<![CDATA[x]]>'; do
    printf '# D\n\n%s\n\nNever delete prod.\n' "$one" > "$R/D.md"
    run rf check "$T/plan.txt" --repo "$R"
    [ "$status" -eq 0 ] || { echo "$one: status $status"; false; }
  done
}

@test "apply refuses a destination that ends inside an unclosed <?, <!DOCTYPE or <![CDATA[ block" {
  plain_plan
  for open in '<?php' '<!DOCTYPE html' '<!ELEMENT x' '<![CDATA['; do
    printf '# Design\n\n%s\nbody\n' "$open" > "$R/DESIGN.md"
    before=$(tree_sum "$R")
    run rf apply "$T/plan.txt" --repo "$R" --yes
    [ "$status" -eq 2 ] || { echo "$open: status $status"; false; }
    [[ "$output" == *"unclosed"* ]] || false
    [ "$before" = "$(tree_sum "$R")" ]
  done
}

@test "blocks --rebuild is byte-identical for the <?, <!LETTER and <![CDATA[ kinds" {
  printf 'a\n<?php\n\nx\n\n?>\nb\n\n<!DOCTYPE html>\n\n<![CDATA[\ny\n]]>\nz\n\n  <!ELEMENT q\n\n>\n- i\n  <?pi\n\n  ?>\n\n<?never closed\n\ntail' > "$T/raw3.md"
  printf '<?>\n\n<!>\n\n<!-x\n\n<![CDATA\n\n<!--\nc\n-->\n' > "$T/raw4.md"
  for f in raw3 raw4; do
    blk "$T/$f.md" --rebuild > "$T/$f.out"
    cmp "$T/$f.md" "$T/$f.out"
  done
  run blk "$T/raw3.md"
  [[ "$output" == *"html"* ]] || false
}

@test "finalize: a keep block hidden inside a raw HTML block of the replacement is refused" {
  plain_plan
  rf apply "$T/plan.txt" --repo "$R" --yes >/dev/null
  git_repo
  rf keep "$T/plan.txt" --repo "$R" > "$T/keep.md"
  for open in '<?php|?>' '<![CDATA[|]]>' '<!DOCTYPE x|>' '<pre>|</pre>'; do
    { echo "# Slim"; echo; echo "${open%|*}"; echo; cat "$T/keep.md"; echo "${open##*|}"; } > "$T/slim.md"
    before=$(tree_sum "$R")
    run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --yes
    [ "$status" -eq 1 ] || { echo "$open: status $status"; false; }
    [[ "$output" == *"KEEP BLOCK NOT IN REPLACEMENT"* ]] || false
    [ "$before" = "$(tree_sum "$R")" ]
  done
}

@test "apply refuses a run whose last block is unclosed (fence, comment, raw HTML), in a dry run too" {
  for tail in '```\ncode never closed' '<!-- never closed' '<style>\nbody{}' '<?php\nx'; do
    printf '# S\n\nIntro.\n\n%b\n' "$tail" > "$R/CLAUDE.md"
    printf '# D\n\n## A\n\nx\n' > "$R/D.md"
    { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1) -> keep"; blk "$R/CLAUDE.md" | awk '/^B[0-9]/ { c++; if (c > 1) print $1 " -> D.md#A" }'; } > "$T/plan.txt"
    before=$(tree_sum "$R")
    run rf apply "$T/plan.txt" --repo "$R"
    [ "$status" -eq 2 ] || { echo "$tail: dry status $status"; false; }
    [[ "$output" == *"unclosed"* ]] || false
    [[ "$output" == *"route it keep"* ]] || false
    run rf apply "$T/plan.txt" --repo "$R" --yes
    [ "$status" -eq 2 ]
    [ "$before" = "$(tree_sum "$R")" ]
    # routing the unclosed block keep is accepted
    { hdr CLAUDE.md; echo "$(bid "$R/CLAUDE.md" 1)..$(bid "$R/CLAUDE.md" 2) -> D.md#A"; echo "$(bid "$R/CLAUDE.md" 3) -> keep"; } > "$T/plan.txt"
    run rf apply "$T/plan.txt" --repo "$R" --yes
    [ "$status" -eq 0 ] || { echo "$tail: keep status $status"; false; }
  done
}

@test "plan: a leading BOM is ignored" {
  plain_plan
  { printf '\xef\xbb\xbf'; cat "$T/plan.txt"; } > "$T/bom.txt"
  run rf check "$T/bom.txt" --repo "$R"
  [ "$status" -eq 1 ]        # nothing applied yet: coverage failure, not "cannot parse line"
  [[ "$output" != *"cannot parse"* ]] || false
  run rf apply "$T/bom.txt" --repo "$R"
  [ "$status" -eq 0 ]
}

@test "finalize: a negative --max-lines is bad input (exit 2)" {
  plain_plan
  printf '# Slim\n' > "$T/slim.md"
  run rf finalize "$T/plan.txt" --repo "$R" --replace-with "$T/slim.md" --max-lines -3
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be >= 0"* ]] || false
}

@test "plan: LEARNINGS.md and MEMORY.md are standard docs: refused until scaffolded, accepted after" {
  plain_plan
  plan_all "$R/CLAUDE.md" CLAUDE.md LEARNINGS.md
  plan_fails "scaffold it first"
  plan_all "$R/CLAUDE.md" CLAUDE.md MEMORY.md
  plan_fails "scaffold it first"
  printf '# LEARNINGS.md: What Burned Us\n' > "$R/LEARNINGS.md"
  printf '# MEMORY.md: What to Remember\n' > "$R/MEMORY.md"
  plan_all "$R/CLAUDE.md" CLAUDE.md LEARNINGS.md
  run rf apply "$T/plan.txt" --repo "$R" --yes
  [ "$status" -eq 0 ]
  grep -qF -- '<!-- moved from CLAUDE.md' "$R/LEARNINGS.md"
}

@test "mapping guide: sends lessons to LEARNINGS.md and remember-pointers to MEMORY.md" {
  g="$REPO_ROOT/skills/project-retrofit/sections/mapping-guide.md"
  grep -q '`LEARNINGS.md`' "$g"
  grep -q '`MEMORY.md`' "$g"
}
