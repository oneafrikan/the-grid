#!/usr/bin/env bats
# Tests for the `rules:<pack>` manifest tier in wire.sh (change `rule-packs`, group 2).
#
# Scenarios come from openspec/changes/rule-packs/specs/rule-wiring/spec.md and
# tasks.md 2.5. Every test runs the REAL scripts/wire.sh against a MOCK grid
# (GRID_DIR=$MOCK_GRID) holding a throwaway pack `rules/foo`. RULES_DIR is a temp
# dir from common_setup, so nothing here can reach the real ~/.claude/rules
# (assert_sandboxed is the tripwire). These are the author's own checks;
# independent verification belongs to qa-engineer.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`

load helpers/setup

setup() {
  common_setup
  export GRID_HOST=testbox
  mkdir -p "$MOCK_GRID/machines"
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  # A throwaway pack: two rule files plus the two non-rule files that must NEVER be wired
  # (a README.md in the rules dir would load on every session).
  make_pack foo a b
  # A baseline file; individual tests append manifest lines to it.
  BASE="$MOCK_GRID/baseline-submodules.txt"
  : > "$BASE"
  OVERLAY="$MOCK_GRID/machines/testbox.txt"
  ERRFILE="$BATS_TEST_TMPDIR/stderr"
}

teardown() {
  unset GRID_HOST GRID_BASELINE
  common_teardown
}

# make_pack NAME TOPIC... : rules/<NAME>/ with pack.yaml, README.md and one .md per topic.
make_pack() {
  local name="$1" t; shift
  mkdir -p "$MOCK_GRID/rules/$name"
  # emit refuses to deliver without the denylist (it fails closed), so the mock grid carries
  # the real one, as a real tree does.
  cp "$REPO_ROOT/rules/denylist.txt" "$MOCK_GRID/rules/"
  printf 'name: %s\n' "$name" > "$MOCK_GRID/rules/$name/pack.yaml"
  printf '# %s\n' "$name" > "$MOCK_GRID/rules/$name/README.md"
  for t in "$@"; do
    printf -- '---\npaths:\n  - "**/*.%s"\n---\n# %s\n\n- A rule.\n' "$t" "$t" > "$MOCK_GRID/rules/$name/$t.md"
  done
}

# wire [args...]: real wire.sh against the mock grid; stderr is kept apart in $ERRFILE.
wire() {
  GRID_DIR="$MOCK_GRID" run --separate-stderr bash "$REPO_ROOT/scripts/wire.sh" "$@"
  printf '%s\n' "$stderr" > "$ERRFILE"
}

# tree DIR: every entry under DIR with its link target, C-sorted ("path -> target").
tree() {
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf '%s -> %s\n' "$p" "$(readlink "$p")"; else printf '%s\n' "$p"; fi
  done
}

# ---------------------------------------------------------------- opt-in

@test "no rules: entry anywhere: nothing is created under RULES_DIR" {
  printf 'somerepo\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ -z "$(tree "$RULES_DIR")" ]
}

@test "no manifest file at all: still no rules (no legacy wire-all for rules)" {
  rm -f "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ -z "$(tree "$RULES_DIR")" ]
}

# ---------------------------------------------------------------- wiring

@test "rules:foo links each rule file and never README.md or pack.yaml" {
  printf 'rules:foo\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ -L "$RULES_DIR/grid/foo/a.md" ]
  [ -L "$RULES_DIR/grid/foo/b.md" ]
  [ "$(readlink "$RULES_DIR/grid/foo/a.md")" = "$MOCK_GRID/rules/foo/a.md" ]
  # The link resolves to the real source content.
  grep -q '^# a$' "$RULES_DIR/grid/foo/a.md"
  [ ! -e "$RULES_DIR/grid/foo/README.md" ]
  [ ! -e "$RULES_DIR/grid/foo/pack.yaml" ]
  # Packs are real directories, not a directory symlink.
  [ -d "$RULES_DIR/grid/foo" ] && [ ! -L "$RULES_DIR/grid/foo" ]
}

@test "wired rule files are recorded as rule rows in .wired.manifest" {
  printf 'rules:foo\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  grep -qxF "$(printf 'rule\tfoo/a.md\t%s\twired\t' "$MOCK_GRID/rules/foo/a.md")" "$MOCK_GRID/.wired.manifest"
  grep -qxF "$(printf 'rule\tfoo/b.md\t%s\twired\t' "$MOCK_GRID/rules/foo/b.md")" "$MOCK_GRID/.wired.manifest"
  ! grep -q 'README.md' "$MOCK_GRID/.wired.manifest"
}

@test "a second wire is a no-op: same link set, same manifest, exit 0" {
  printf 'rules:foo\n' > "$BASE"
  wire
  local before manifest_before
  before="$(tree "$RULES_DIR")"; manifest_before="$(cat "$MOCK_GRID/.wired.manifest")"
  wire
  [ "$status" -eq 0 ]
  [ "$(tree "$RULES_DIR")" = "$before" ]
  [ "$(cat "$MOCK_GRID/.wired.manifest")" = "$manifest_before" ]
}

@test "the same pack named in baseline and overlay wires once without error" {
  printf 'rules:foo\n' > "$BASE"
  printf 'rules:foo\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ "$(grep -c "rule	foo/a.md" "$MOCK_GRID/.wired.manifest")" -eq 1 ]
}

@test "removing the entry then re-wiring removes the links and the empty pack dir" {
  printf 'rules:foo\n' > "$BASE"
  wire
  [ -L "$RULES_DIR/grid/foo/a.md" ]
  : > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ ! -e "$RULES_DIR/grid/foo/a.md" ]
  [ ! -L "$RULES_DIR/grid/foo/a.md" ]
  [ ! -e "$RULES_DIR/grid/foo" ]
}

@test "a rule file deleted from the pack is dropped on the next wire" {
  printf 'rules:foo\n' > "$BASE"
  wire
  rm "$MOCK_GRID/rules/foo/b.md"
  wire
  [ "$status" -eq 0 ]
  [ -L "$RULES_DIR/grid/foo/a.md" ]
  [ ! -L "$RULES_DIR/grid/foo/b.md" ]
}

@test "-rules:foo in an overlay subtracts a baseline pack" {
  make_pack bar x
  printf 'rules:foo\nrules:bar\n' > "$BASE"
  printf -- '-rules:foo\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ ! -e "$RULES_DIR/grid/foo" ]
  [ -L "$RULES_DIR/grid/bar/x.md" ]
}

@test "rules: entries do not turn into repos or disable project/skill wiring" {
  make_skill "$MOCK_GRID/repos/wiredrepo/skill-w" "skill-w"
  printf 'wiredrepo\nrules:foo\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-w" ]
  [ -L "$RULES_DIR/grid/foo/a.md" ]
  # `rules:foo` must not have been read as a repo name (no skill dir named after it).
  [ ! -e "$MOCK_SKILLS/rules:foo" ]
}

# ---------------------------------------------------------------- unknown / unsafe names

@test "unknown pack: warns on stderr, exits 0, records a skipped row" {
  printf 'rules:nope\nrules:foo\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  grep -q 'nope' "$ERRFILE"
  grep -q "^rule	nope	.*	skipped	" "$MOCK_GRID/.wired.manifest"
  [ ! -e "$RULES_DIR/grid/nope" ]
  # The valid pack beside it is still wired.
  [ -L "$RULES_DIR/grid/foo/a.md" ]
}

@test "a pack name that could escape rules/ is refused, nothing outside RULES_DIR/grid is written" {
  mkdir -p "$MOCK_GRID/secret"; printf '# x\n' > "$MOCK_GRID/secret/leak.md"
  printf 'rules:../secret\nrules:/abs\nrules:\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ -z "$(tree "$RULES_DIR")" ]
  grep -q '^rule	.*	skipped	' "$MOCK_GRID/.wired.manifest"
}

# ---------------------------------------------------------------- never clobber real files / foreign links

@test "a real file at a target path is left untouched and recorded as skipped" {
  printf 'rules:foo\n' > "$BASE"
  mkdir -p "$RULES_DIR/grid/foo"
  printf 'mine\n' > "$RULES_DIR/grid/foo/a.md"
  wire
  [ "$status" -eq 0 ]
  [ ! -L "$RULES_DIR/grid/foo/a.md" ]
  [ "$(cat "$RULES_DIR/grid/foo/a.md")" = "mine" ]
  [ -L "$RULES_DIR/grid/foo/b.md" ]
  grep -qxF "$(printf 'rule\tfoo/a.md\t%s\tskipped\treal file, not managed' "$MOCK_GRID/rules/foo/a.md")" "$MOCK_GRID/.wired.manifest"
}

@test "foreign symlinks and real files under RULES_DIR/grid survive wiring and teardown" {
  printf 'rules:foo\n' > "$BASE"
  mkdir -p "$OTHER_DIR/ext" "$RULES_DIR/grid/foo" "$RULES_DIR/grid/mine"
  printf '# ext\n' > "$OTHER_DIR/ext/ext.md"
  ln -s "$OTHER_DIR/ext/ext.md" "$RULES_DIR/grid/foo/ext.md"
  ln -s "$OTHER_DIR/ext/ext.md" "$RULES_DIR/grid/mine/ext.md"
  printf 'keep\n' > "$RULES_DIR/grid/mine/own.md"
  wire; [ "$status" -eq 0 ]
  : > "$BASE"     # un-wire everything: teardown runs with nothing to rebuild
  wire; [ "$status" -eq 0 ]
  [ -L "$RULES_DIR/grid/foo/ext.md" ]       # foreign link kept, so its dir is not "empty"
  [ -L "$RULES_DIR/grid/mine/ext.md" ]
  [ "$(cat "$RULES_DIR/grid/mine/own.md")" = "keep" ]
  [ ! -e "$RULES_DIR/grid/foo/a.md" ]       # the grid-owned link is gone
}

@test "a sibling dir that merely shares the GRID_DIR prefix is not treated as ours" {
  printf 'rules:foo\n' > "$BASE"
  mkdir -p "$RULES_DIR/grid/foo" "${MOCK_GRID}-private"
  printf '# p\n' > "${MOCK_GRID}-private/p.md"
  ln -s "${MOCK_GRID}-private/p.md" "$RULES_DIR/grid/foo/p.md"
  wire
  [ "$status" -eq 0 ]
  [ -L "$RULES_DIR/grid/foo/p.md" ]
  rm -rf "${MOCK_GRID}-private"
}

@test "anything outside RULES_DIR/grid is never touched (RULES_DIR/* siblings survive)" {
  printf 'rules:foo\n' > "$BASE"
  printf 'x\n' > "$RULES_DIR/sibling.md"
  ln -s "$MOCK_GRID/rules/foo/a.md" "$RULES_DIR/grid-looking-but-not-under-grid.md"
  wire
  [ "$status" -eq 0 ]
  : > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [ -f "$RULES_DIR/sibling.md" ]
  [ -L "$RULES_DIR/grid-looking-but-not-under-grid.md" ]
}

# ---------------------------------------------------------------- --check

@test "wire --check: exit 0 after wiring, 1 after a link is deleted, and it writes nothing" {
  printf 'rules:foo\n' > "$BASE"
  wire
  wire --check
  [ "$status" -eq 0 ]
  rm "$RULES_DIR/grid/foo/a.md"
  local before; before="$(tree "$RULES_DIR")"
  wire --check
  [ "$status" -eq 1 ]
  grep -q 'rules drift' "$ERRFILE"
  grep -q 'a.md' "$ERRFILE"
  # Read-only: the missing link was NOT recreated and nothing else changed.
  [ ! -e "$RULES_DIR/grid/foo/a.md" ]
  [ "$(tree "$RULES_DIR")" = "$before" ]
}

@test "wire --check: a stale link for an un-wired pack is drift" {
  printf 'rules:foo\n' > "$BASE"
  wire
  : > "$BASE"
  wire --check
  [ "$status" -eq 1 ]
  grep -q 'foo/a.md' "$ERRFILE"
}

@test "wire --check: a real file shadowing a rule target is not drift" {
  printf 'rules:foo\n' > "$BASE"
  mkdir -p "$RULES_DIR/grid/foo"
  printf 'mine\n' > "$RULES_DIR/grid/foo/a.md"
  wire
  wire --check
  [ "$status" -eq 0 ]
}

@test "wire --check with no rules: entries is clean and creates nothing in RULES_DIR" {
  printf 'somerepo\n' > "$BASE"
  wire
  wire --check
  [ "$status" -eq 0 ]
  [ -z "$(tree "$RULES_DIR")" ]
}

# ---------------------------------------------------------------- GRID_DRY_HOME

@test "GRID_DRY_HOME forces RULES_DIR: an inherited real rules dir is never touched" {
  local realhome="$BATS_TEST_TMPDIR/realhome" dry="$BATS_TEST_TMPDIR/dry" sum
  mkdir -p "$realhome/.claude/rules"
  printf 'sentinel\n' > "$realhome/.claude/rules/sentinel.md"
  sum="$(cksum < "$realhome/.claude/rules/sentinel.md")"
  printf 'rules:foo\n' > "$BASE"
  # HOME and RULES_DIR both point into the fake real home; GRID_DRY_HOME must win.
  HOME="$realhome" RULES_DIR="$realhome/.claude/rules" GRID_DIR="$MOCK_GRID" GRID_DRY_HOME="$dry" \
    run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ "$(cksum < "$realhome/.claude/rules/sentinel.md")" = "$sum" ]
  # Nothing new in the fake real rules dir; the links landed under the dry home.
  [ "$(ls -A "$realhome/.claude/rules")" = "sentinel.md" ]
  [ -L "$dry/.claude/rules/grid/foo/a.md" ]
  # A dry run writes no manifest into the repo.
  [ ! -e "$MOCK_GRID/.wired.manifest" ]
}

# ---------------------------------------------------------------- catalog.sh / sources.sh

# A fixture grid for the generators: one submodule entry so sources.sh has a row.
make_generator_fixture() {
  printf '[submodule "repos/alpha"]\n\tpath = repos/alpha\n\turl = https://example.com/o/alpha.git\n' > "$MOCK_GRID/.gitmodules"
  make_skill "$MOCK_GRID/repos/alpha/skill-a" "skill-a"
  printf 'alpha\nproject:grid\n' > "$MOCK_GRID/baseline-submodules.txt"
}

@test "catalog.sh and sources.sh output is unchanged by rules:/-rules:/harness:/-hook: lines" {
  make_generator_fixture
  local line n=0
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$BATS_TEST_TMPDIR/cat.ref"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/sources.sh" "$BATS_TEST_TMPDIR/src.ref" >/dev/null
  for line in 'rules:sql' '-rules:sql' 'harness:codex' '-hook:auto-handoff' 'rules:sql/extra'; do
    n=$((n + 1))
    printf 'alpha\nproject:grid\n%s\n' "$line" > "$MOCK_GRID/baseline-submodules.txt"
    GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$BATS_TEST_TMPDIR/cat.$n"
    GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/sources.sh" "$BATS_TEST_TMPDIR/src.$n" >/dev/null
    cmp "$BATS_TEST_TMPDIR/cat.ref" "$BATS_TEST_TMPDIR/cat.$n"
    cmp "$BATS_TEST_TMPDIR/src.ref" "$BATS_TEST_TMPDIR/src.$n"
  done
}

@test "catalog.sh --check is unaffected by a rules: line in the baseline" {
  make_generator_fixture
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$MOCK_GRID/SKILLS.md"
  printf 'alpha\nproject:grid\nrules:sql\n-rules:wordpress\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- emit re-validation (WP-053)

@test "a lint-failing pack is not delivered to a harness file while a clean pack is (wire exits 1)" {
  make_pack bad x
  # A marker line in a fence: lint-clean to the old emit, poison to the block.
  printf -- '---\npaths:\n  - "**/*.x"\n---\n# x\n\n```\n<!-- BEGIN the-grid rules -->\n```\n' > "$MOCK_GRID/rules/bad/x.md"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  printf 'notes\n' > "$GRID_HARNESS_HOME/.codex/AGENTS.md"
  printf 'rules:foo\nrules:bad\nharness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 1 ]
  grep -q '^### foo / a' "$GRID_HARNESS_HOME/.codex/AGENTS.md"
  ! grep -q '^### bad / ' "$GRID_HARNESS_HOME/.codex/AGENTS.md" || false
  [[ "$stderr" == *"bad"* ]]
}

# ---------------------------------------------------------------- WP-011: the empty-rules warning

@test "a wire with no rules: entry prints no 'empty rules' warning" {
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"empty rules"* ]]
  # --check too (it runs a child wire whose output is discarded, but its own stderr counts).
  wire --check
  [[ "$stderr" != *"empty rules"* ]]
}

@test "a bare 'rules:' line still warns" {
  printf 'rules:\n' > "$BASE"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"empty rules: entry ignored"* ]]
}
