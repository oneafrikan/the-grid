#!/usr/bin/env bats
# Tests for scripts/lib/find-skill-mds.sh — the exclusion rules that keep
# translations, per-harness copies and listed prefixes out of wiring/catalogue.
# Fixtures are built twice: a plain dir (the `find` branch) and a git checkout
# (the `git ls-files` branch), so both code paths are exercised.

load helpers/setup

setup() {
  FIX_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$FIX_ROOT"
}

# Write a SKILL.md at <repo>/<rel>.
mk() { # $1 = repo dir, $2 = relative dir holding the SKILL.md
  mkdir -p "$1/$2"
  printf -- '---\nname: x\ndescription: d\n---\n' > "$1/$2/SKILL.md"
}

# Populate a fixture repo with every shape the rules must keep or drop.
populate() { # $1 = repo dir
  mk "$1" skills/a
  mk "$1" skills/engineering/b
  mk "$1" docs/ja-JP/skills/a
  mk "$1" docs/tr/skills/a
  mk "$1" i18n/zh-CN/a
  mk "$1" docs/guides/a
  mk "$1" .kiro/skills/a
  mk "$1" .agents/skills/a
  mk "$1" pi/core/a
}

# Turn a fixture dir into its own committed git checkout.
gitify() { # $1 = repo dir
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

# Print the relative paths find_skill_mds reports for a repo, sorted.
rels() { # $1 = repo dir
  # shellcheck source=../scripts/lib/find-skill-mds.sh
  . "$REPO_ROOT/scripts/lib/find-skill-mds.sh"
  find_skill_mds "$1" | sed "s|^$1/||" | LC_ALL=C sort
}

# Assert the kept/dropped sets for one fixture repo named <name>.
check_fixture() { # $1 = repo dir
  local out
  out="$(rels "$1")"
  # kept
  printf '%s\n' "$out" | grep -qx 'skills/a/SKILL.md'
  printf '%s\n' "$out" | grep -qx 'skills/engineering/b/SKILL.md'
  printf '%s\n' "$out" | grep -qx 'docs/guides/a/SKILL.md'
  # dropped: translations
  ! printf '%s\n' "$out" | grep -q 'docs/ja-JP'
  ! printf '%s\n' "$out" | grep -q 'docs/tr/'
  ! printf '%s\n' "$out" | grep -q 'i18n/zh-CN'
  # dropped: harness copies
  ! printf '%s\n' "$out" | grep -q '^\.kiro'
  ! printf '%s\n' "$out" | grep -q '^\.agents'
}

@test "plain-dir branch: keeps real skills, drops translations and dot-dirs" {
  local d="$FIX_ROOT/other"
  populate "$d"
  check_fixture "$d"
  # pi/ is only excluded for a repo named ecc: here it is kept.
  rels "$d" | grep -qx 'pi/core/a/SKILL.md'
}

@test "git branch: keeps real skills, drops translations and dot-dirs" {
  local d="$FIX_ROOT/other"
  populate "$d"
  gitify "$d"
  check_fixture "$d"
  rels "$d" | grep -qx 'pi/core/a/SKILL.md'
}

@test "listed prefix: pi/ dropped only when the repo dir is named ecc (plain)" {
  local d="$FIX_ROOT/ecc"
  populate "$d"
  check_fixture "$d"
  ! rels "$d" | grep -q '^pi/'
}

@test "listed prefix: pi/ dropped only when the repo dir is named ecc (git)" {
  local d="$FIX_ROOT/ecc"
  populate "$d"
  gitify "$d"
  check_fixture "$d"
  ! rels "$d" | grep -q '^pi/'
}

@test "a repo-root SKILL.md is still reported (callers skip it themselves)" {
  local d="$FIX_ROOT/other"
  mkdir -p "$d"
  printf -- '---\nname: root\ndescription: d\n---\n' > "$d/SKILL.md"
  rels "$d" | grep -qx 'SKILL.md'
}

@test "real repos/ecc: only skills/ paths, count equals tracked skills/ SKILL.md" {
  [ -e "$REPO_ROOT/repos/ecc/.git" ] || skip "repos/ecc not initialised"
  # shellcheck source=../scripts/lib/find-skill-mds.sh
  . "$REPO_ROOT/scripts/lib/find-skill-mds.sh"
  local out n want
  out="$(find_skill_mds "$REPO_ROOT/repos/ecc")"
  n="$(printf '%s\n' "$out" | grep -c '')"
  want="$(git -C "$REPO_ROOT/repos/ecc" ls-files -- 'skills/*SKILL.md' | wc -l | tr -d ' ')"
  # No literal count: it moves with every ECC bump. Must be non-empty though.
  [ "$want" -gt 0 ]
  [ "$n" -eq "$want" ]
  ! printf '%s\n' "$out" | grep -q '/docs/'
  ! printf '%s\n' "$out" | grep -q '/\.'
  # Every path sits under repos/ecc/skills/.
  [ "$(printf '%s\n' "$out" | grep -vc "^$REPO_ROOT/repos/ecc/skills/")" -eq 0 ]
}

@test "catalog: .kiro copy is not counted, skills/ skill is (count 1)" {
  common_setup
  make_skill "$MOCK_GRID/repos/dup/skills/real" "real"
  make_skill "$MOCK_GRID/repos/dup/.kiro/skills/real" "real"
  printf 'dup\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$MOCK_SKILLS/SKILLS.md"
  grep -q '^## repos/dup (wired) — 1$' "$MOCK_SKILLS/SKILLS.md"
  common_teardown
}
