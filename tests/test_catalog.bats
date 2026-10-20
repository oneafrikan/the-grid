#!/usr/bin/env bats
# Tests for catalog.sh — generates SKILLS.md from each skill's frontmatter.

load helpers/setup

setup() {
  common_setup
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  make_skill "$MOCK_GRID/skills/skill-beta"  "skill-beta"
  # A nested submodule skill (mattpocock/superpowers style)
  make_skill "$MOCK_GRID/repos/gstack/deep-skill" "deep-skill"
  # A repo-root SKILL.md marker (gstack style) — must NOT be catalogued
  printf -- "---\nname: gstack-root\ndescription: repo marker\n---\n" \
    > "$MOCK_GRID/repos/gstack/SKILL.md"
  OUT="$MOCK_SKILLS/SKILLS.md"
}

teardown() {
  common_teardown
}

# lacks <ERE> FILE — succeeds only if no line of FILE matches. A bare `! grep` mid-test never
# fails the test (bash exempts negated commands from errexit), so the negation lives in a
# function whose exit status is its last command's (as in test_harness_formats.bats).
lacks() {
  ! grep -qE "$@"
}

@test "catalog.sh runs and writes the output file" {
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
}

@test "lists every wired skill by name" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q -- '- \*\*skill-alpha\*\*' "$OUT"
  grep -q -- '- \*\*skill-beta\*\*'  "$OUT"
  grep -q -- '- \*\*deep-skill\*\*'  "$OUT"
}

@test "groups submodule skills under a repos/<name> section" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q '^## repos/gstack' "$OUT"
}

@test "skips a repo-root SKILL.md (gstack style)" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  lacks -- '- \*\*gstack-root\*\*' "$OUT"
}

@test "count excludes repo-root markers" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  # 3 real skills (alpha, beta, deep-skill); the repo-root marker is excluded.
  grep -q '\*\*3 skills indexed\*\*' "$OUT"
}

@test "labels wired vs library submodules from the allowlist" {
  make_skill "$MOCK_GRID/repos/wiredrepo/sk-w" "sk-w"
  make_skill "$MOCK_GRID/repos/libraryrepo/sk-l" "sk-l"
  printf 'wiredrepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q '^## repos/wiredrepo (wired)' "$OUT"        # wired → full section
  grep -q '^## Library submodules' "$OUT"             # library → counts section
  grep -q -- '- \*\*repos/libraryrepo\*\* — 1 skills' "$OUT"
}

@test "treats a submodule with no skills as a reference, not an empty section" {
  mkdir -p "$MOCK_GRID/repos/refindex"
  printf '# just an index\n' > "$MOCK_GRID/repos/refindex/README.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  lacks '^## repos/refindex' "$OUT"                # no skill section
  grep -q 'Reference submodules' "$OUT"            # listed under the footer
  grep -q -- '- \*\*repos/refindex\*\*' "$OUT"
}

@test "generating twice is idempotent (byte-identical)" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  cp "$OUT" "$MOCK_SKILLS/first.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  diff -q "$MOCK_SKILLS/first.md" "$OUT"
}

@test "wire.sh refreshes SKILLS.md (coupled to wiring)" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -f "$MOCK_GRID/SKILLS.md" ]
  grep -q -- '- \*\*skill-alpha\*\*' "$MOCK_GRID/SKILLS.md"
}

@test "git-checkout repo: catalogue counts tracked skills only, not generated copies" {
  local r="$MOCK_GRID/repos/gen"
  make_skill "$r/real-skill" "real-skill"
  # A NON-dot directory: a dot-dir is already dropped by the exclusion rules, so it would
  # pass even with the tracked-only listing broken.
  printf 'generated-copies/\n' > "$r/.gitignore"
  git -C "$r" init -q
  git -C "$r" add -A
  make_skill "$r/generated-copies/skills/stray-generated" "stray-generated"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q -- '- \*\*real-skill\*\*' "$OUT"
  lacks 'stray-generated' "$OUT"
}

# --- WP-046: SKILLS.md is rendered from a PINNED baseline -----------------------------------
# The committed SKILLS.md must be a function of tracked inputs only, so CI and every machine
# agree. catalog.sh therefore reads ${GRID_BASELINE:-<personal baseline>}; the gate and wire.sh
# pin it to the tracked example baseline.

# two_baselines — repos pers-repo and ex-repo; the personal file wires one, the example the other
two_baselines() {
  make_skill "$MOCK_GRID/repos/pers-repo/sk-p" "sk-p"
  make_skill "$MOCK_GRID/repos/ex-repo/sk-e" "sk-e"
  printf 'pers-repo\n' > "$MOCK_GRID/baseline-submodules.txt"
  printf 'ex-repo\n' > "$MOCK_GRID/baseline-submodules.example.txt"
}

@test "GRID_BASELINE selects the baseline catalog.sh renders from" {
  two_baselines
  GRID_DIR="$MOCK_GRID" GRID_BASELINE="$MOCK_GRID/baseline-submodules.example.txt" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q '^## repos/ex-repo (wired)' "$OUT"
  grep -q -- '- \*\*repos/pers-repo\*\* — 1 skills' "$OUT"
  # without the pin the personal baseline still wins (a developer's own run is unchanged)
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q '^## repos/pers-repo (wired)' "$OUT"
}

@test "GRID_BASELINE naming a missing file exits 2 and writes nothing" {
  two_baselines
  GRID_DIR="$MOCK_GRID" GRID_BASELINE="$MOCK_GRID/no-such-baseline.txt" run bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no-such-baseline.txt"* ]] || false
  [ ! -e "$OUT" ]
}

@test "catalog.sh --check honours the pinned baseline too" {
  two_baselines
  GRID_DIR="$MOCK_GRID" GRID_BASELINE="$MOCK_GRID/baseline-submodules.example.txt" bash "$REPO_ROOT/scripts/catalog.sh"
  GRID_DIR="$MOCK_GRID" GRID_BASELINE="$MOCK_GRID/baseline-submodules.example.txt" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 0 ]
  # the same file is stale against the personal baseline: the pin is what makes the check portable
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 1 ]
}

@test "wire.sh with a personal baseline leaves the tracked SKILLS.md equal to the example render" {
  two_baselines
  GRID_DIR="$MOCK_GRID" GRID_BASELINE="$MOCK_GRID/baseline-submodules.example.txt" bash "$REPO_ROOT/scripts/catalog.sh" "$MOCK_SKILLS/expected.md"
  # the reference render really is the example's (not the personal one)
  grep -q '^## repos/ex-repo (wired)' "$MOCK_SKILLS/expected.md"
  # wire as a machine whose personal baseline differs from the example
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -f "$MOCK_GRID/SKILLS.md" ]
  diff -q "$MOCK_SKILLS/expected.md" "$MOCK_GRID/SKILLS.md"
}

@test "real repo: the committed SKILLS.md is current against the example baseline" {
  if git -C "$REPO_ROOT" submodule status 2>/dev/null | grep -q '^-'; then
    skip "uninitialised submodules (git submodule update --init)"
  fi
  GRID_BASELINE="$REPO_ROOT/baseline-submodules.example.txt" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  echo "$output"
  [ "$status" -eq 0 ]
}

# --- WP-047: the catalogue awk reads frontmatter like scripts/lib/skill_frontmatter.py -------
# Two frontmatter readers must not disagree on one file. agree FILE-CONTENT renders a one-skill
# catalogue from the printf-format content and compares its bullet with what the Python reader
# says: a skill the Python reader finds no frontmatter in falls back to its directory name and
# "_(no description)_". (The quoted-escape and multi-line `name: |` differences are documented in
# the catalog.sh header and deliberately not pinned here.)

agree() {
  local dir="$MOCK_GRID/skills/agree-dir" want name desc
  mkdir -p "$dir"
  printf -- "$1" > "$dir/SKILL.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  if IFS=$'\t' read -r name desc < <(python3 -I "$REPO_ROOT/scripts/lib/skill_frontmatter.py" "$dir/SKILL.md"); then
    [ -n "$name" ] || name=agree-dir
    [ -n "$desc" ] || desc='_(no description)_'
  else
    name=agree-dir; desc='_(no description)_'
  fi
  want="- **$name** — $desc"
  grep -qxF -- "$want" "$OUT" || { echo "want: $want"; grep -- 'agree-dir\|\*\*[a-z-]*\*\* — ' "$OUT" | head -5; return 1; }
}

@test "agrees with skill_frontmatter.py: a plain skill" {
  agree '---\nname: plain\ndescription: Just a description.\n---\nbody\n'
}

@test "agrees with skill_frontmatter.py: a duplicate description, the first one wins" {
  agree '---\nname: dupd\ndescription: First wins.\ndescription: Second loses.\n---\n'
}

@test "agrees with skill_frontmatter.py: a duplicate name, the first one wins" {
  agree '---\nname: first-name\ndescription: D.\nname: second-name\n---\n'
}

@test "agrees with skill_frontmatter.py: a leading BOM is ignored" {
  agree '\xef\xbb\xbf---\nname: bommed\ndescription: With a BOM.\n---\n'
}

@test "agrees with skill_frontmatter.py: an unclosed fence is no frontmatter" {
  agree '---\nname: unclosed\ndescription: Never closed.\nbody text\n'
}

@test "agrees with skill_frontmatter.py: an opening fence that is not on line 1 is no frontmatter" {
  agree '\n---\nname: late\ndescription: Fence on line 2.\n---\n'
}

@test "agrees with skill_frontmatter.py: a folded description with continuation lines" {
  agree '---\nname: folded\ndescription: >\n  First line\n  second line.\n---\n'
}

@test "agrees with skill_frontmatter.py: a plain scalar ends at ' #' (a YAML comment)" {
  agree '---\nname: hashy\ndescription: Real text # not this\n---\n'
}

@test "agrees with skill_frontmatter.py: a quoted description keeps its '#'" {
  agree '---\nname: hashq\ndescription: "Real # kept"\n---\n'
}

@test "agrees with skill_frontmatter.py: CRLF line endings" {
  agree '---\r\nname: crlf\r\ndescription: Windows ending.\r\n---\r\n'
}

@test "agrees with skill_frontmatter.py: an indented --- also closes the block" {
  # No full stop in the description: the summary stops at ". ", which would hide the stray "---".
  agree '---\nname: indented\ndescription: Closes early\n  ---\nmore: x\n---\n'
}

# Table-driven: each fixture was once read differently by the two readers (NF-064). One
# fixture per line, printf format; a fixture that disagrees prints itself and fails the test.
@test "agrees with skill_frontmatter.py: the shapes the two readers once disagreed on" {
  local fx fixtures=(
    '---\nname: b\ndescription: |\n  one\n\n  two\n---\n'          # blank line inside a block scalar
    '---\nname: x\n  cont\ndescription: D.\n---\n'                # indented line under name:
    "---\nname: 'it''s'\ndescription: D.\n---\n"                  # doubled quote in a single-quoted name
    "---\nname: n\ndescription: 'it''s'\n---\n"                   # ... and in a description
    '---\nname: >\n  folded\ndescription: D.\n---\n'              # name as a folded block
    '---\nname: |\n  piped\ndescription: D.\n---\n'               # name as a literal block
    '---\nname: foo # c\ndescription: D.\n---\n'                  # plain name with a comment
  )
  for fx in "${fixtures[@]}"; do
    agree "$fx" || { echo "differs on: $fx"; return 1; }
  done
}

# The documented differences (catalog.sh header): awk splits lines on LF only, python also on a
# lone CR, U+0085 and U+2028, so such a file is "no frontmatter" here. Pinned so a change to
# either reader shows up as a failure here instead of as a silent drift.
@test "catalog.sh reads a lone CR, U+0085 or U+2028 line break as no frontmatter (documented difference)" {
  local dir="$MOCK_GRID/skills/brk-dir" fx
  mkdir -p "$dir"
  for fx in '---\rname: cr\rdescription: D.\r---\r' \
            '---\xc2\x85name: nel\xc2\x85description: D.\xc2\x85---\xc2\x85' \
            '---\xe2\x80\xa8name: ls\xe2\x80\xa8description: D.\xe2\x80\xa8---\xe2\x80\xa8'; do
    printf -- "$fx" > "$dir/SKILL.md"
    GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
    grep -qxF -- '- **brk-dir** — _(no description)_' "$OUT" || { echo "not a fallback: $fx"; return 1; }
  done
}

# --- WP-047: ordering and cap -------------------------------------------------------------

# A locale whose collation differs from C, if this machine has one (else the test cannot bite).
other_locale() {
  locale -a 2>/dev/null | grep -iE '^(en_[A-Z]{2}|de_DE)\.utf-?8$' | head -1
}

@test "sorts by byte order whatever the caller's locale: web-x before webapp-y" {
  local loc wx wy
  loc="$(other_locale)"
  [ -n "$loc" ] || skip "no non-C UTF-8 locale installed"
  make_skill "$MOCK_GRID/skills/webapp-y" "webapp-y"
  make_skill "$MOCK_GRID/skills/web-x" "web-x"
  LC_ALL="$loc" GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  wx="$(grep -n -- '- \*\*web-x\*\*' "$OUT" | cut -d: -f1)"
  wy="$(grep -n -- '- \*\*webapp-y\*\*' "$OUT" | cut -d: -f1)"
  [ "$wx" -lt "$wy" ]
}

@test "names sort case-insensitively: alpha before Zeta" {
  make_skill "$MOCK_GRID/skills/Zeta" "Zeta"
  make_skill "$MOCK_GRID/skills/alpha-first" "alpha-first"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  local a z
  a="$(grep -n -- '- \*\*alpha-first\*\*' "$OUT" | cut -d: -f1)"
  z="$(grep -n -- '- \*\*Zeta\*\*' "$OUT" | cut -d: -f1)"
  [ "$a" -lt "$z" ]
}

@test "a long summary is cut to 200 characters ending in an ellipsis" {
  local long; long="$(head -c 300 < /dev/zero | tr '\0' 'x')"
  mkdir -p "$MOCK_GRID/skills/longy"
  printf -- '---\nname: longy\ndescription: %s\n---\n' "$long" > "$MOCK_GRID/skills/longy/SKILL.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  local line; line="$(grep -- '- \*\*longy\*\*' "$OUT")"
  [ "${line#- **longy** — }" = "$(head -c 199 < /dev/zero | tr '\0' 'x')…" ]
}

@test "the cut never splits a multi-byte character" {
  local long; long="$(python3 -c "print('—' * 250)")"
  mkdir -p "$MOCK_GRID/skills/wide"
  printf -- '---\nname: wide\ndescription: %s\n---\n' "$long" > "$MOCK_GRID/skills/wide/SKILL.md"
  # Run in a UTF-8 locale where one exists: gawk counts characters there, mawk never does, and
  # the script pins LC_ALL=C so both cut at the same byte.
  LC_ALL="$(other_locale)" GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  # Valid UTF-8 end to end, and the cut text is whole em dashes plus the ellipsis.
  python3 -c '
import sys
text = open(sys.argv[1], encoding="utf-8").read()   # raises on a split character
line = [l for l in text.splitlines() if l.startswith("- **wide**")][0]
body = line[len("- **wide** — "):]
assert body.endswith("…") and set(body[:-1]) == {"—"} and 60 < len(body) < 70, body
' "$OUT"
}

@test "a summary stops at the first sentence" {
  mkdir -p "$MOCK_GRID/skills/sent"
  printf -- '---\nname: sent\ndescription: First sentence. Second sentence.\n---\n' > "$MOCK_GRID/skills/sent/SKILL.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -qxF -- '- **sent** — First sentence.' "$OUT"
}

@test "a -repo/skill baseline subtraction drops that skill from the catalogue and the count" {
  make_skill "$MOCK_GRID/repos/subr/keep-me" "keep-me"
  make_skill "$MOCK_GRID/repos/subr/drop-me" "drop-me"
  printf 'subr\n-subr/drop-me\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q -- '- \*\*keep-me\*\*' "$OUT"
  lacks 'drop-me' "$OUT"
  grep -q '^## repos/subr (wired) — 1$' "$OUT"
}

# --- WP-048: option handling ---------------------------------------------------------------
# Any first argument used to be the output path, so `--chek`, `-h` or `--help` wrote a file of
# that name. A leading dash is now an option (`--check`, `-h`/`--help`); an unknown one is usage
# (exit 2) before any file is touched. A non-dash argument is still the output path (wire.sh).
# $OTHER_DIR is an empty scratch dir the script is run from, so a stray file shows up in it.

in_other_dir() { # ARGS... -> runs catalog.sh from $OTHER_DIR against the mock grid
  run bash -c 'cd "$1" && shift && GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$@"' _ "$OTHER_DIR" "$@"
}

@test "catalog.sh --chek exits 2 with a usage line and creates no file" {
  export MOCK_GRID REPO_ROOT
  in_other_dir --chek
  [ "$status" -eq 2 ]
  [[ "$output" == *"--chek"* ]]
  [ -z "$(ls -A "$OTHER_DIR")" ]
  [ ! -e "$MOCK_GRID/SKILLS.md" ]
}

@test "catalog.sh with an empty output path exits 2 and does not write the default SKILLS.md" {
  export MOCK_GRID REPO_ROOT
  in_other_dir ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty output path"* ]]
  [ ! -e "$MOCK_GRID/SKILLS.md" ]
}

@test "catalog.sh -h and --help print the usage, exit 0 and create no file" {
  export MOCK_GRID REPO_ROOT
  local flag
  for flag in -h --help; do
    in_other_dir "$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
    [ -z "$(ls -A "$OTHER_DIR")" ]
    [ ! -e "$MOCK_GRID/SKILLS.md" ]
  done
}

@test "catalog.sh --check with an output path is a usage error (it writes nothing)" {
  export MOCK_GRID REPO_ROOT
  # A current SKILLS.md, so that ignoring the path would give a clean exit 0, not an error.
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"
  in_other_dir --check "$OTHER_DIR/x.md"
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$OTHER_DIR")" ]
}

@test "catalog.sh --check exits 2, not the 'stale' 1, when it cannot make its temp file" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"        # a current SKILLS.md
  TMPDIR="$MOCK_GRID/no-such-tmpdir" GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"temp"* ]]
}

@test "catalog.sh --check exits 2, not the 'stale' 1, when the render itself fails" {
  [ "$(id -u)" -ne 0 ] || skip "root reads an unreadable file"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"          # a current SKILLS.md
  printf 'skill-alpha\n' > "$MOCK_GRID/baseline-submodules.txt"
  chmod 000 "$MOCK_GRID/baseline-submodules.txt"                       # the render cannot read it
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  chmod 600 "$MOCK_GRID/baseline-submodules.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"failed before it could compare"* ]]
}

@test "catalog.sh --check exits 2 when there is no SKILLS.md to compare against" {
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 2 ]
}

@test "catalog.sh --check: current is 0, stale is 1" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 0 ]
  make_skill "$MOCK_GRID/skills/skill-new" "skill-new"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 1 ]
}
