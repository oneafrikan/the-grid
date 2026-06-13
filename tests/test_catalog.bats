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

@test "catalog.sh runs and writes the output file" {
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/catalog.sh" "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
}

@test "lists every wired skill by name" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  grep -q -- '- \*\*skill-alpha\*\*' "$OUT"
  grep -q -- '- \*\*skill-beta\*\*'  "$OUT"
  grep -q -- '- \*\*deep-skill\*\*'  "$OUT"
}

@test "groups submodule skills under a repos/<name> section" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  grep -q '^## repos/gstack' "$OUT"
}

@test "skips a repo-root SKILL.md (gstack style)" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  ! grep -q -- '- \*\*gstack-root\*\*' "$OUT"
}

@test "count excludes repo-root markers" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  # 3 real skills (alpha, beta, deep-skill); the repo-root marker is excluded.
  grep -q '\*\*3 skills indexed\*\*' "$OUT"
}

@test "labels wired vs library submodules from the allowlist" {
  make_skill "$MOCK_GRID/repos/wiredrepo/sk-w" "sk-w"
  make_skill "$MOCK_GRID/repos/libraryrepo/sk-l" "sk-l"
  printf 'wiredrepo\n' > "$MOCK_GRID/wired-submodules.txt"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  grep -q '^## repos/wiredrepo (wired)' "$OUT"        # wired → full section
  grep -q '^## Library submodules' "$OUT"             # library → counts section
  grep -q -- '- \*\*repos/libraryrepo\*\* — 1 skills' "$OUT"
}

@test "treats a submodule with no skills as a reference, not an empty section" {
  mkdir -p "$MOCK_GRID/repos/refindex"
  printf '# just an index\n' > "$MOCK_GRID/repos/refindex/README.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  ! grep -q '^## repos/refindex' "$OUT"            # no skill section
  grep -q 'Reference submodules' "$OUT"            # listed under the footer
  grep -q -- '- \*\*repos/refindex\*\*' "$OUT"
}

@test "generating twice is idempotent (byte-identical)" {
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  cp "$OUT" "$MOCK_SKILLS/first.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/catalog.sh" "$OUT"
  diff -q "$MOCK_SKILLS/first.md" "$OUT"
}

@test "wire.sh refreshes SKILLS.md (coupled to wiring)" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/wire.sh"
  [ -f "$MOCK_GRID/SKILLS.md" ]
  grep -q -- '- \*\*skill-alpha\*\*' "$MOCK_GRID/SKILLS.md"
}
