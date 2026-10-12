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
  ! grep -q -- '- \*\*gstack-root\*\*' "$OUT"
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
  ! grep -q '^## repos/refindex' "$OUT" || false            # no skill section
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
  printf '.slate/\n' > "$r/.gitignore"
  git -C "$r" init -q
  git -C "$r" add -A
  make_skill "$r/.slate/skills/stray-generated" "stray-generated"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$OUT"
  grep -q -- '- \*\*real-skill\*\*' "$OUT"
  ! grep -q 'stray-generated' "$OUT"
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
