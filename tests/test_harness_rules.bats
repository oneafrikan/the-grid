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
load helpers/portable
TAB=$'\t'

setup() {
  common_setup
  export GRID_HOST=testbox
  mkdir -p "$MOCK_GRID/machines"
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  # A throwaway rule pack with one rule file (format per rule-packs: paths: frontmatter,
  # an H1, then bullets).
  mkdir -p "$MOCK_GRID/rules/fx"
  # emit fails closed without the denylist, so the mock grid carries the real one.
  cp "$REPO_ROOT/rules/denylist.txt" "$MOCK_GRID/rules/"
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
  grep -qE '^rules@~/\.codex/AGENTS\.md'"$TAB"'codex'"$TAB"'-'"$TAB"'skipped'"$TAB"'rules-file-absent$' "$MANIFEST"
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
  grep -qE '^rules@~/\.codex/AGENTS\.md'"$TAB"'codex'"$TAB"'-'"$TAB"'skipped'"$TAB"'rules-file-symlink$' "$MANIFEST"
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
  grep -qE '^rules@~/\.codex/AGENTS\.md'"$TAB"'codex'"$TAB"'-'"$TAB"'skipped'"$TAB"'rules-file-not-regular$' "$MANIFEST"
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
  sed_i 's/Quote every expansion\./Do whatever./' "$CODEX_MD"
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
  # An oversize rule file fails the re-lint, so rules.py refuses (exit 2) for both files.
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
  export GRID_ALLOW_REGISTRY=1   # HARNESS_REGISTRY is ignored without it (WP-012)
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
  grep -qE '^rules@~/\.codex/AGENTS\.md'"$TAB"'codex'"$TAB"'-'"$TAB"'skipped'"$TAB"'markers-unbalanced$' "$MANIFEST"
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
  grep -qE '^rules@~/\.codex/AGENTS\.md'"$TAB"'codex'"$TAB"'-'"$TAB"'failed'"$TAB"'' "$MANIFEST"
}

@test "two harnesses sharing one rules_file make wire exit 2 and name both" {
  registry_copy
  # Point gemini's rules_file at codex's.
  sed_i 's#~/.gemini/GEMINI.md#~/.codex/AGENTS.md#' "$HARNESS_REGISTRY"
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"rules_file ~/.codex/AGENTS.md is used by harnesses codex and gemini"* ]]
}

@test "a rules_file that is not an instruction file or not ~/-relative is skipped as rules-file-not-allowed" {
  registry_copy
  sed_i 's#~/.codex/AGENTS.md#~/.bashrc#; s#~/.gemini/GEMINI.md#'"$BATS_TEST_TMPDIR"'/AGENTS.md#' "$HARNESS_REGISTRY"
  printf 'rules:fx\nharness:codex\nharness:gemini\n' > "$OVERLAY"
  printf 'export X=1\n' > "$GRID_HARNESS_HOME/.bashrc"
  printf 'notes\n' > "$BATS_TEST_TMPDIR/AGENTS.md"
  cp "$GRID_HARNESS_HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
  cp "$BATS_TEST_TMPDIR/AGENTS.md" "$BATS_TEST_TMPDIR/agents.orig"
  wire
  [ "$status" -eq 0 ]
  cmp "$GRID_HARNESS_HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
  cmp "$BATS_TEST_TMPDIR/AGENTS.md" "$BATS_TEST_TMPDIR/agents.orig"
  grep -qE '^rules@~/\.bashrc'"$TAB"'codex'"$TAB"'-'"$TAB"'skipped'"$TAB"'rules-file-not-allowed$' "$MANIFEST"
  grep -qE "^rules@.*AGENTS\.md${TAB}gemini${TAB}-${TAB}skipped${TAB}rules-file-not-allowed\$" "$MANIFEST"
}

# ---------------------------------------------------------------- visibility and cap (WP-054)

# pad_packs N: N lint-clean packs (pad1..padN), one ~3.6 KB rule file each, so a few of them
# together push the managed block past the 12288-byte cap.
pad_packs() {
  local n i j
  for i in $(seq 1 "$1"); do
    mkdir -p "$MOCK_GRID/rules/pad$i"
    printf 'name: pad%s\n' "$i" > "$MOCK_GRID/rules/pad$i/pack.yaml"
    { printf -- '---\npaths:\n  - "**/*.p%s"\n---\n# Pad\n\n' "$i"
      for j in $(seq 1 17); do printf -- '- %s\n' "$(printf '%*s' 200 '' | tr ' ' x)"; done; } > "$MOCK_GRID/rules/pad$i/pad.md"
  done
}

@test "over the cap: wire exits 0, warns on stderr, records a skipped over-cap row, leaves the file unchanged" {
  pad_packs 5
  printf 'rules:pad1\nrules:pad2\nrules:pad3\nrules:pad4\nrules:pad5\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  cp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"over the 12288-byte cap"* ]]
  cmp "$CODEX_MD" "$BATS_TEST_TMPDIR/codex.orig"
  grep -qE '^rules@~/\.codex/AGENTS\.md'"$TAB"'codex'"$TAB"'-'"$TAB"'skipped'"$TAB"'over-cap$' "$MANIFEST"
  # --check agrees: an over-cap selection is not drift.
  wire --check
  [ "$status" -eq 0 ]
}

@test "a symlinked, an absent and a directory instruction file each print a skip line and still exit 0" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  # absent
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"rules (~/.codex/AGENTS.md): skipped, file does not exist"* ]]
  # symlink
  mkdir -p "$GRID_HARNESS_HOME/.codex"
  make_user_file "$BATS_TEST_TMPDIR/real.md"
  ln -s "$BATS_TEST_TMPDIR/real.md" "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"rules (~/.codex/AGENTS.md): skipped, file is a symlink"* ]]
  # directory
  rm "$CODEX_MD"
  mkdir "$CODEX_MD"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"rules (~/.codex/AGENTS.md): skipped, path is not a regular file"* ]]
  # --check stays silent about skips (absent or symlinked is documented as not drift).
  wire --check
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"skipped"* ]]
}

@test "AGENTS.override.md beside the codex file prints the override warning (delivery and removal)" {
  printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
  make_user_file "$CODEX_MD"
  : > "$GRID_HARNESS_HOME/.codex/AGENTS.override.md"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"rules (~/.codex/AGENTS.md): AGENTS.override.md exists beside it; Codex reads that first, so the block has no effect"* ]]
  # Removal branch: the block is still in the file, the harness is switched off.
  printf 'rules:fx\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"AGENTS.override.md exists beside it"* ]]
}

@test "the bash block-begin constant equals rules.py BLOCK_BEGIN" {
  py="$(python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/scripts'); import rules; print(rules.BLOCK_BEGIN)")"
  sh="$(bash -c ". '$REPO_ROOT/scripts/lib/harness.sh'; printf '%s' \"\$HARNESS_BLOCK_BEGIN\"")"
  [ -n "$sh" ]
  [ "$py" = "$sh" ]
}

# ---------------------------------------------------------------- H-13: path allowlist and exact grep

# action FILE ACTIVE CSV RAW: harness_rules_action in a fresh shell (the decision wire.sh makes).
action() {
  bash -c ". '$REPO_ROOT/scripts/lib/harness.sh'; harness_rules_action \"\$@\"" _ "$@"
}

@test "VS3 harness_rules_action: dot, dot-dot, empty and absolute rules_file segments are not allowed" {
  local f="$BATS_TEST_TMPDIR/AGENTS.md" raw
  printf 'notes\n' > "$f"
  # The control: a plain ~/ instruction file is delivered.
  [ "$(action "$f" 1 fx '~/.codex/AGENTS.md')" = emit ]
  for raw in '~/../../etc/AGENTS.md' '~/a/../AGENTS.md' '~/..' '~/.codex/./AGENTS.md' \
             '~/./AGENTS.md' '~/.codex//AGENTS.md' '~//AGENTS.md' '/etc/AGENTS.md' 'AGENTS.md' '~/.codex/AGENTS.md/'; do
    [ "$(action "$f" 1 fx "$raw")" = skip:rules-file-not-allowed ] || { echo "not refused: $raw"; return 1; }
  done
  # Removal is refused for such a row as well, even for a file that holds our exact block.
  printf '%s\nx\n<!-- END the-grid rules -->\n' "$BEGIN_LINE" > "$f"
  [ "$(action "$f" 0 "" '~/.codex/AGENTS.md')" = remove ]
  for raw in '~/../../etc/AGENTS.md' '~/.codex/./AGENTS.md' '~/.codex//AGENTS.md'; do
    [ "$(action "$f" 0 "" "$raw")" = none ] || { echo "removal not refused: $raw"; return 1; }
  done
}

@test "VS3 registry: a rules_file with a dot or empty segment exits 2 before any write" {
  local raw
  for raw in '~/.codex/./AGENTS.md' '~/.codex//AGENTS.md' '~/../AGENTS.md'; do
    registry_copy
    # gemini now points at the same file as codex by another spelling: the duplicate check
    # must not be defeatable by it.
    sed_i "s#~/.gemini/GEMINI.md#$raw#" "$HARNESS_REGISTRY"
    printf 'rules:fx\nharness:codex\n' > "$OVERLAY"
    wire
    [ "$status" -eq 2 ] || { echo "not refused: $raw"; return 1; }
    [[ "$stderr" == *"registry"* ]]
    [[ "$stderr" == *"gemini"* ]]
    [ ! -e "$GRID_HARNESS_HOME/.codex/AGENTS.md" ]
  done
}

@test "VS4 harness_rules_action: removal needs the COMPLETE BEGIN line (a prefix, a suffix or an indent is user text)" {
  local f="$BATS_TEST_TMPDIR/AGENTS.md" l
  for l in '<!-- BEGIN the-grid rules -->' '<!-- BEGIN the-grid rules' "$BEGIN_LINE extra" " $BEGIN_LINE" \
           "${BEGIN_LINE%-->}" "${BEGIN_LINE}x"; do
    printf 'notes\n%s\nmore\n' "$l" > "$f"
    [ "$(action "$f" 0 "" '~/.codex/AGENTS.md')" = none ] || { echo "removed for: $l"; return 1; }
  done
  printf 'notes\n%s\nmore\n' "$BEGIN_LINE" > "$f"
  [ "$(action "$f" 0 "" '~/.codex/AGENTS.md')" = remove ]
  printf 'notes\r\n%s\r\nmore\r\n' "$BEGIN_LINE" > "$f"
  [ "$(action "$f" 0 "" '~/.codex/AGENTS.md')" = remove ]
}
