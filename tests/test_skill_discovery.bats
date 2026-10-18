#!/usr/bin/env bats
# Tests for scripts/lib/find-skill-mds.sh — the exclusion rules that keep
# translations, per-harness copies and listed prefixes out of wiring/catalogue.
# Fixtures are built twice: a plain dir (the `find` branch) and a git checkout
# (the `git ls-files` branch), so both code paths are exercised.

load helpers/setup

# common_setup lives in setup() (not in the one test that needs MOCK_GRID): the sandbox
# tripwire then runs for every case, and common_teardown runs even when a case fails.
setup() {
  common_setup
  FIX_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$FIX_ROOT"
  common_teardown
}

# lacks <ERE> — succeeds only if no line on stdin matches. A bare `! cmd` mid-test never fails
# the test (bash exempts negated commands from errexit), so the negation lives in a function
# whose exit status is its last command's (as in test_harness_formats.bats).
lacks() {
  ! grep -qE "$1"
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
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -q -m fixture
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
  printf '%s\n' "$out" | lacks 'docs/ja-JP'
  printf '%s\n' "$out" | lacks 'docs/tr/'
  printf '%s\n' "$out" | lacks 'i18n/zh-CN'
  # dropped: harness copies
  printf '%s\n' "$out" | lacks '^\.kiro'
  printf '%s\n' "$out" | lacks '^\.agents'
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
  rels "$d" | lacks '^pi/'
}

@test "listed prefix: pi/ dropped only when the repo dir is named ecc (git)" {
  local d="$FIX_ROOT/ecc"
  populate "$d"
  gitify "$d"
  check_fixture "$d"
  rels "$d" | lacks '^pi/'
}

@test "a repo-root SKILL.md is still reported (callers skip it themselves)" {
  local d="$FIX_ROOT/other"
  mkdir -p "$d"
  printf -- '---\nname: root\ndescription: d\n---\n' > "$d/SKILL.md"
  rels "$d" | grep -qx 'SKILL.md'
}

@test "real repos/ecc: only skills/ paths, count equals tracked skills/ SKILL.md" {
  [ -e "$REPO_ROOT/repos/ecc/.git" ] || skip "repos/ecc not initialised"
  local out n want
  # H-15: discovery is a pure-bash loop over ~1000 tracked paths. Inside bats' shell every one of
  # its commands pays the DEBUG trap (~0.8 ms), which made this ~8 s on CI; a child bash has no
  # trap. Same function, same inputs, same assertions below.
  out="$(bash -c '. "$1/scripts/lib/find-skill-mds.sh" && find_skill_mds "$2"' _ \
    "$REPO_ROOT" "$REPO_ROOT/repos/ecc")"
  n="$(printf '%s\n' "$out" | grep -c '')"
  want="$(git -C "$REPO_ROOT/repos/ecc" ls-files -- 'skills/*SKILL.md' | wc -l | tr -d ' ')"
  # No literal count: it moves with every ECC bump. Must be non-empty though.
  [ "$want" -gt 0 ]
  [ "$n" -eq "$want" ]
  printf '%s\n' "$out" | lacks '/docs/'
  printf '%s\n' "$out" | lacks '/\.'
  # Every path sits under repos/ecc/skills/.
  [ "$(printf '%s\n' "$out" | grep -vc "^$REPO_ROOT/repos/ecc/skills/")" -eq 0 ]
}

@test "catalog: .kiro copy is not counted, skills/ skill is (count 1)" {
  make_skill "$MOCK_GRID/repos/dup/skills/real" "real"
  make_skill "$MOCK_GRID/repos/dup/.kiro/skills/real" "real"
  printf 'dup\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$MOCK_SKILLS/SKILLS.md"
  grep -q '^## repos/dup (wired) — 1$' "$MOCK_SKILLS/SKILLS.md"
}

# --- WP-009: path safety (newline paths, symlinked SKILL.md, locale list, inherited GIT_*) ----

# Like rels, but stderr goes to $FIX_ROOT/err so a test can read the warning.
rels_err() { # $1 = repo dir
  # shellcheck source=../scripts/lib/find-skill-mds.sh
  . "$REPO_ROOT/scripts/lib/find-skill-mds.sh"
  find_skill_mds "$1" 2>"$FIX_ROOT/err" | sed "s|^$1/||" | LC_ALL=C sort
}

# A skill dir whose NAME holds a line break, next to one real skill.
populate_newline() { # $1 = repo dir
  mk "$1" skills/ok
  mk "$1" "skills/new
line"
}

@test "newline path is skipped, with a warning, in the plain fixture" {
  local d="$FIX_ROOT/other" out
  populate_newline "$d"
  out="$(rels_err "$d")"
  [ "$out" = "skills/ok/SKILL.md" ]
  [ -s "$FIX_ROOT/err" ]
}

@test "newline path is skipped, with a warning, in the git fixture" {
  local d="$FIX_ROOT/other" out
  populate_newline "$d"
  gitify "$d"
  out="$(rels_err "$d")"
  [ "$out" = "skills/ok/SKILL.md" ]
  [ -s "$FIX_ROOT/err" ]
}

# One tree with every shape the two branches used to disagree on.
populate_hostile() { # $1 = repo dir
  mk "$1" skills/real
  mkdir -p "$1/skills/dirskill/SKILL.md"                  # a DIRECTORY named SKILL.md
  : > "$1/skills/dirskill/SKILL.md/note.txt"
  mkdir -p "$1/skills/dangling"
  ln -s "$FIX_ROOT/nowhere" "$1/skills/dangling/SKILL.md" # dangling symlink
  mk "$1" node_modules/dep                                # vendored copies
  mk "$1" skills/real/node_modules/inner
}

@test "git and plain branches return the same set for one hostile tree" {
  local p="$FIX_ROOT/plain" g="$FIX_ROOT/git" outp outg shape
  populate_hostile "$p"
  populate_hostile "$g"
  gitify "$g"
  # An untracked file: only the git branch can know it is untracked.
  mk "$g" skills/untracked
  outp="$(rels "$p")"
  outg="$(rels "$g")"
  [ "$outp" = "skills/real/SKILL.md" ]
  [ "$outg" = "$outp" ]
  # Negative checks that cannot pass vacuously: the real skill IS there (above), and
  # each hostile shape is searched for by name and must NOT be.
  for shape in dirskill dangling node_modules untracked; do
    run grep "$shape" <<< "$outp"
    [ "$status" -ne 0 ]
    run grep "$shape" <<< "$outg"
    [ "$status" -ne 0 ]
  done
}

@test "git branch: a tracked SKILL.md deleted from disk is not reported" {
  local d="$FIX_ROOT/other"
  mk "$d" skills/kept
  mk "$d" skills/gone
  gitify "$d"
  rm "$d/skills/gone/SKILL.md"       # still in the index, no longer on disk
  [ "$(rels "$d")" = "skills/kept/SKILL.md" ]
}

@test "docs/qa and docs/go are skills; docs/ja-JP, zh-CN, pt-BR, zh-Hans and tr are translations" {
  local branch d out
  for branch in plain git; do
    d="$FIX_ROOT/$branch"
    mk "$d" docs/qa
    mk "$d" docs/go
    mk "$d" docs/ja-JP/a
    mk "$d" docs/zh-CN/a
    mk "$d" docs/pt-BR/a
    mk "$d" docs/zh-Hans/a
    mk "$d" docs/tr/a
    if [ "$branch" = git ]; then gitify "$d"; fi
    out="$(rels "$d")"
    [ "$out" = "$(printf 'docs/go/SKILL.md\ndocs/qa/SKILL.md')" ]
  done
}

@test "a SKILL.md symlink to a file outside the root is skipped (git and plain)" {
  local branch d out
  printf -- '---\nname: x\ndescription: d\n---\n' > "$FIX_ROOT/outside.md"
  for branch in plain git; do
    d="$FIX_ROOT/$branch"
    mk "$d" skills/real
    mkdir -p "$d/skills/linked"
    ln -s "$FIX_ROOT/outside.md" "$d/skills/linked/SKILL.md"
    if [ "$branch" = git ]; then gitify "$d"; fi
    out="$(rels "$d")"
    [ "$out" = "skills/real/SKILL.md" ]
  done
}

@test "GIT_DIR and GIT_INDEX_FILE pointing at another repo give the clean-env result" {
  local d="$FIX_ROOT/mine" other="$FIX_ROOT/theirs" clean dirty
  mk "$d" skills/a
  mk "$d" skills/b
  gitify "$d"
  mk "$other" skills/zzz
  gitify "$other"
  clean="$(rels "$d")"
  [ "$clean" = "$(printf 'skills/a/SKILL.md\nskills/b/SKILL.md')" ]
  dirty="$(GIT_DIR="$other/.git" GIT_INDEX_FILE="$other/.git/index" rels "$d")"
  [ "$dirty" = "$clean" ]
}
