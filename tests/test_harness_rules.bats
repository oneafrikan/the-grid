#!/usr/bin/env bats
# Tests for rules delivery to non-Claude harnesses in wire.sh (change `multi-harness`, group 7).
#
# Scenarios come from openspec/changes/multi-harness/specs/harness-rules-delivery/spec.md
# and tasks.md 7.2. Every test runs the REAL scripts/wire.sh (and so the real
# scripts/rules.py) against a MOCK grid (GRID_DIR=$MOCK_GRID) holding a throwaway pack
# `rules/fx`. Every instruction file lives under GRID_HARNESS_HOME, a temp dir whose leaf
# contains a SPACE on purpose; assert_sandboxed (in common_setup) is the tripwire, so no
# test can reach a real ~/.codex, ~/.gemini or project file. These are the author's own
# checks; independent verification belongs to qa-engineer.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`

load helpers/setup

setup() {
  common_setup
  export GRID_HOST=testbox
  mkdir -p "$MOCK_GRID/machines"
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  # A throwaway rule pack with one rule file (format per rule-packs: paths: frontmatter,
  # an H1, then bullets).
  mkdir -p "$MOCK_GRID/rules/fx"
  printf 'name: fx\n' > "$MOCK_GRID/rules/fx/pack.yaml"
  printf -- '---\npaths:\n  - "**/*.sh"\n---\n# Shell\n\n- Quote every expansion.\n' \
    > "$MOCK_GRID/rules/fx/shell.md"
  OVERLAY="$MOCK_GRID/machines/testbox.txt"
  MANIFEST="$MOCK_GRID/.wired.manifest"
  # The instruction files the registry names (harness base + registry path).
  CODEX_MD="$GRID_HARNESS_HOME/.codex/AGENTS.md"
  GEMINI_MD="$GRID_HARNESS_HOME/.gemini/GEMINI.md"
  MARK='BEGIN the-grid rules'
}

teardown() {
  unset GRID_HOST GRID_BASELINE
  common_teardown
}

# wire [args...]: real wire.sh against the mock grid; stderr is kept apart in $stderr.
wire() {
  GRID_DIR="$MOCK_GRID" run --separate-stderr bash "$REPO_ROOT/scripts/wire.sh" "$@"
}

# make_user_file PATH: an instruction file holding only operator text (the opt-in).
make_user_file() {
  mkdir -p "$(dirname "$1")"
  printf '# My notes\n\nKeep replies short.\n' > "$1"
}

# assert_user_text FILE ORIG: FILE is byte-identical to ORIG (the operator's text). Removing
# a block takes back the separator newline the append added, so nothing is left over.
assert_user_text() {
  cmp "$1" "$2"
}

# ---------------------------------------------------------------- creation rules

@test "active harness, rules wired, file absent: nothing is created, manifest says rules-file-absent" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_MD" ]
  [ ! -e "$GRID_HARNESS_HOME/.codex/AGENTS.md" ]
  grep -qP '^rules@~/\.codex/AGENTS\.md\tcodex\t-\tskipped\trules-file-absent$' "$MANIFEST"
}

@test "no rules: entry and a missing file: no row, nothing created" {
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_MD" ]
  ! grep -q '^rules@' "$MANIFEST"
}

@test "no harness active: no instruction file is created or read" {
  printf 'rules:fx\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ ! -e "$GRID_HARNESS_HOME/.codex" ]
  [ ! -e "$GRID_HARNESS_HOME/.gemini" ]
  ! grep -q '^rules@' "$MANIFEST"
}

# ---------------------------------------------------------------- delivery

@test "existing file gets the block, user text stays byte-identical, second run is a no-op" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/user.orig"
  wire
  [ "$status" -eq 0 ]
  grep -qF "$MARK" "$CODEX_MD"
  grep -qF 'Quote every expansion.' "$CODEX_MD"
  # The user text is the exact prefix of the new file.
  head -c "$(wc -c < "$BATS_TEST_TMPDIR/user.orig")" "$CODEX_MD" | cmp - "$BATS_TEST_TMPDIR/user.orig"
  sum1="$(cksum < "$CODEX_MD")"
  wire
  [ "$status" -eq 0 ]
  [ "$(cksum < "$CODEX_MD")" = "$sum1" ]
}

@test "each active harness gets the block in its own file, through its rules_harness" {
  printf 'rules:fx\nharness:codex\nharness:gemini\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  make_user_file "$GEMINI_MD"
  wire
  [ "$status" -eq 0 ]
  grep -qF "$MARK" "$CODEX_MD"
  grep -qF "$MARK" "$GEMINI_MD"
}

@test "an active harness with no rules_file (openclaw) is skipped without a row" {
  printf 'rules:fx\nharness:openclaw\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  ! grep -q '^rules@' "$MANIFEST"
}

@test "removing rules:fx removes the block and keeps the user text" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/user.orig"
  wire
  grep -qF "$MARK" "$CODEX_MD"
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  ! grep -qF "$MARK" "$CODEX_MD" || false
  assert_user_text "$CODEX_MD" "$BATS_TEST_TMPDIR/user.orig"
}

@test "-rules:fx (subtraction) removes the block too" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  wire
  grep -qF "$MARK" "$CODEX_MD"
  printf 'rules:fx\n-rules:fx\nharness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  ! grep -qF "$MARK" "$CODEX_MD"
}

@test "deactivating the harness removes the block and keeps the user text" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/user.orig"
  wire
  grep -qF "$MARK" "$CODEX_MD"
  printf 'rules:fx\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  ! grep -qF "$MARK" "$CODEX_MD" || false
  assert_user_text "$CODEX_MD" "$BATS_TEST_TMPDIR/user.orig"
}

@test "GRID_HARNESS=gemini replaces the set: a codex block from an earlier run is removed" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  make_user_file "$GEMINI_MD"
  wire
  grep -qF "$MARK" "$CODEX_MD"
  GRID_HARNESS=gemini wire
  [ "$status" -eq 0 ]
  ! grep -qF "$MARK" "$CODEX_MD" || false
  grep -qF "$MARK" "$GEMINI_MD"
}

# ---------------------------------------------------------------- never touch

@test "GRID_HARNESS=antigravity never touches .gemini/GEMINI.md" {
  printf 'rules:fx\n' > "$OVERLAY"
  make_user_file "$GEMINI_MD"
  cp "$GEMINI_MD" "$BATS_TEST_TMPDIR/gemini.orig"
  touch -d '2001-01-01 00:00:00' "$GEMINI_MD"
  GRID_HARNESS=antigravity wire
  [ "$status" -eq 0 ]
  cmp "$GEMINI_MD" "$BATS_TEST_TMPDIR/gemini.orig"
  # Not even rewritten with identical bytes: the mtime is the old one.
  [ "$(date -r "$GEMINI_MD" +%Y)" = 2001 ]
  ! grep -q '^rules@' "$MANIFEST"
}

@test "a symlinked instruction file is not written through; manifest says rules-file-symlink" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$BATS_TEST_TMPDIR/real-agents.md"
  cp "$BATS_TEST_TMPDIR/real-agents.md" "$BATS_TEST_TMPDIR/real-agents.orig"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  ln -s "$BATS_TEST_TMPDIR/real-agents.md" "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/real-agents.md" "$BATS_TEST_TMPDIR/real-agents.orig"
  [ -L "$CODEX_MD" ]
  grep -qP '^rules@~/\.codex/AGENTS\.md\tcodex\t-\tskipped\trules-file-symlink$' "$MANIFEST"
}

@test "a symlinked instruction file holding an old block is not edited on removal either" {
  printf 'harness:codex\n' > "$OVERLAY"
  printf 'x\n<!-- BEGIN the-grid rules (old) -->\nfoo\n<!-- END the-grid rules -->\n' > "$BATS_TEST_TMPDIR/real-agents.md"
  cp "$BATS_TEST_TMPDIR/real-agents.md" "$BATS_TEST_TMPDIR/real-agents.orig"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  ln -s "$BATS_TEST_TMPDIR/real-agents.md" "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/real-agents.md" "$BATS_TEST_TMPDIR/real-agents.orig"
}

@test "an empty opt-in file survives when the harness is inactive" {
  printf 'rules:fx\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  : > "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  [ -f "$CODEX_MD" ]
  [ ! -s "$CODEX_MD" ]
}

@test "an empty opt-in file survives when the harness is active but no pack is wired" {
  printf 'harness:codex\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  : > "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  [ -f "$CODEX_MD" ]
  [ ! -s "$CODEX_MD" ]
}

@test "a file holding only the block is truncated to 0 bytes and kept when the block is removed" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  : > "$CODEX_MD"
  wire
  grep -qF "$MARK" "$CODEX_MD"
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  # The operator's opt-in file survives, empty.
  [ -f "$CODEX_MD" ]
  [ ! -s "$CODEX_MD" ]
  # Re-enabling delivers the block into the kept file again (no rules-file-absent skip).
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  grep -qF "$MARK" "$CODEX_MD"
  ! grep -q 'rules-file-absent' "$MANIFEST"
}

@test "a directory at the instruction path is left alone and recorded" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  mkdir -p "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  [ -d "$CODEX_MD" ]
  grep -qP '^rules@~/\.codex/AGENTS\.md\tcodex\t-\tskipped\trules-file-not-regular$' "$MANIFEST"
}

# ---------------------------------------------------------------- --check

@test "--check: exit 0 after a wire, and it writes nothing" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  wire
  sum1="$(cksum < "$CODEX_MD")"
  wire --check
  [ "$status" -eq 0 ]
  [ "$(cksum < "$CODEX_MD")" = "$sum1" ]
}

@test "--check: exit 1 after the block is hand-edited, and the edit is not repaired" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  wire
  sed -i 's/Quote every expansion\./Do whatever./' "$CODEX_MD"
  sum1="$(cksum < "$CODEX_MD")"
  wire --check
  [ "$status" -eq 1 ]
  [ "$(cksum < "$CODEX_MD")" = "$sum1" ]
  grep -qF 'Do whatever.' "$CODEX_MD"
}

@test "--check: exit 1 when a block is present but no pack is wired any more" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  wire
  printf 'harness:codex\n' > "$OVERLAY"
  wire --check
  [ "$status" -eq 1 ]
  grep -qF "$MARK" "$CODEX_MD"
}

@test "--check: exit 1 when a rule pack was wired but the block is missing" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  # Wired while the file was absent (so skills match), then the operator opts in.
  wire
  make_user_file "$CODEX_MD"
  wire --check
  [ "$status" -eq 1 ]
  ! grep -qF "$MARK" "$CODEX_MD"
}

@test "--check: an absent or symlinked instruction file is not drift" {
  printf 'rules:fx\nharness:codex\nharness:gemini\n' > "$OVERLAY"
  make_user_file "$BATS_TEST_TMPDIR/real.md"
  mkdir -p "$GRID_HARNESS_HOME/.gemini"
  ln -s "$BATS_TEST_TMPDIR/real.md" "$GEMINI_MD"
  wire
  [ "$status" -eq 0 ]
  wire --check
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_MD" ]
}

# ---------------------------------------------------------------- failures

@test "a rules.py refusal is reported, every other step still runs, then wire exits 1" {
  printf 'rules:fx\nharness:codex\nharness:gemini\n' > "$OVERLAY"
  # An over-cap pack makes rules.py refuse (exit 2) for both files.
  printf -- '---\npaths:\n  - "**/*.py"\n---\n# Big\n\n' > "$MOCK_GRID/rules/fx/big.md"
  for i in $(seq 1 400); do printf -- '- Filler rule number %s that pads the block.\n' "$i" >> "$MOCK_GRID/rules/fx/big.md"; done
  make_user_file "$CODEX_MD"
  make_user_file "$GEMINI_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  wire
  [ "$status" -eq 1 ]
  # Skills and the manifest were still written after the failure.
  [ -L "$GRID_HARNESS_HOME/.agents/skills/skill-alpha" ]
  [ -s "$MANIFEST" ]
  cmp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  # Both files were attempted: two failures are reported.
  [ "$(printf '%s\n' "$stderr" | grep -c 'rules delivery failed')" -ge 2 ]
}

# ---------------------------------------------------------------- markers and registry (WP-053)

BEGIN_LINE='<!-- BEGIN the-grid rules (generated by scripts/rules.py; edits inside are overwritten) -->'

# registry_copy: a writable copy of the registry for a test to edit (HARNESS_REGISTRY).
registry_copy() {
  cp "$REPO_ROOT/scripts/lib/harnesses.txt" "$BATS_TEST_TMPDIR/harnesses.txt"
  export HARNESS_REGISTRY="$BATS_TEST_TMPDIR/harnesses.txt"
}

@test "a codex file quoting only a bare BEGIN marker line leaves wire green and the file unchanged (harness inactive)" {
  printf 'rules:fx\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  printf 'notes\n<!-- BEGIN the-grid rules -->\nquoted in the docs\n' > "$CODEX_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  wire
  [ "$status" -eq 0 ]
  cmp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  ! grep -q '^rules@' "$MANIFEST"
}

@test "an exact but unbalanced marker on an inactive harness warns, records a skipped row, exits 0, file unchanged" {
  printf 'rules:fx\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  printf 'notes\n%s\nno end line\n' "$BEGIN_LINE" > "$CODEX_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  wire
  [ "$status" -eq 0 ]
  cmp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  [[ "$stderr" == *"markers"* ]]
  grep -qP '^rules@~/\.codex/AGENTS\.md\tcodex\t-\tskipped\tmarkers-unbalanced$' "$MANIFEST"
  # --check agrees: an inactive harness with a damaged file is not drift.
  wire --check
  [ "$status" -eq 0 ]
}

@test "an unbalanced marker on an ACTIVE harness is a failure with a failed manifest row" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  printf 'notes\n%s\nno end line\n' "$BEGIN_LINE" > "$CODEX_MD"
  wire
  [ "$status" -eq 1 ]
  grep -qP '^rules@~/\.codex/AGENTS\.md\tcodex\t-\tfailed\t' "$MANIFEST"
}

@test "two harnesses sharing one rules_file make wire exit 2 and name both" {
  registry_copy
  # Point gemini's rules_file at codex's.
  sed -i 's#~/.gemini/GEMINI.md#~/.codex/AGENTS.md#' "$HARNESS_REGISTRY"
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"rules_file ~/.codex/AGENTS.md is used by harnesses codex and gemini"* ]]
}

@test "a rules_file that is not an instruction file or not ~/-relative is skipped as rules-file-not-allowed" {
  registry_copy
  sed -i 's#~/.codex/AGENTS.md#~/.bashrc#; s#~/.gemini/GEMINI.md#'"$BATS_TEST_TMPDIR"'/AGENTS.md#' "$HARNESS_REGISTRY"
  printf 'rules:fx\nharness:codex\nharness:gemini\n' > "$OVERLAY"
  printf 'export X=1\n' > "$GRID_HARNESS_HOME/.bashrc"
  printf 'notes\n' > "$BATS_TEST_TMPDIR/AGENTS.md"
  cp "$GRID_HARNESS_HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
  cp "$BATS_TEST_TMPDIR/AGENTS.md" "$BATS_TEST_TMPDIR/agents.orig"
  wire
  [ "$status" -eq 0 ]
  cmp "$GRID_HARNESS_HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
  cmp "$BATS_TEST_TMPDIR/AGENTS.md" "$BATS_TEST_TMPDIR/agents.orig"
  grep -qP '^rules@~/\.bashrc\tcodex\t-\tskipped\trules-file-not-allowed$' "$MANIFEST"
  grep -qP "^rules@.*AGENTS\.md\tgemini\t-\tskipped\trules-file-not-allowed\$" "$MANIFEST"
}

@test "the bash block-begin constant equals rules.py BLOCK_BEGIN" {
  py="$(python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/scripts'); import rules; print(rules.BLOCK_BEGIN)")"
  sh="$(bash -c ". '$REPO_ROOT/scripts/lib/harness.sh'; printf '%s' \"\$HARNESS_BLOCK_BEGIN\"")"
  [ -n "$sh" ]
  [ "$py" = "$sh" ]
}
