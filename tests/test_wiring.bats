#!/usr/bin/env bats
# Tests for wire.sh — the script that creates ~/.claude/skills/ symlinks

load helpers/setup

setup() {
  common_setup
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  make_skill "$MOCK_GRID/skills/skill-beta"  "skill-beta"
}

teardown() {
  # A test may leave a dir read-only; rm -rf in common_teardown needs it writable again.
  chmod -R u+w "$MOCK_AGENTS" "$MOCK_SKILLS" 2>/dev/null || true
  common_teardown
}

@test "creates a symlink per skill in the target dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
}

@test "symlinks resolve to directories (not dangling)" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -d "$MOCK_SKILLS/skill-alpha" ]
  [ -d "$MOCK_SKILLS/skill-beta" ]
}

@test "running wire.sh twice is idempotent" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
}

@test "removes stale symlink when skill is deleted from the-grid" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  rm -rf "$MOCK_GRID/skills/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -e "$MOCK_SKILLS/skill-alpha" ]
  [ ! -L "$MOCK_SKILLS/skill-alpha" ]
}

@test "does not remove symlinks owned by other sources" {
  mkdir -p "$OTHER_DIR/external-skill"
  ln -s "$OTHER_DIR/external-skill" "$MOCK_SKILLS/external-skill"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/external-skill" ]
}

@test "wires skills found inside repos/ submodules (flat)" {
  make_skill "$MOCK_GRID/repos/gstack/skill-gstack" "skill-gstack"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-gstack" ]
  [ -d "$MOCK_SKILLS/skill-gstack" ]
}

@test "wires skills nested under skills/ subdir (mattpocock/superpowers style)" {
  make_skill "$MOCK_GRID/repos/mattpocock/skills/engineering/skill-deep" "skill-deep"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-deep" ]
  [ -d "$MOCK_SKILLS/skill-deep" ]
}

@test "skips repo-root SKILL.md (gstack style)" {
  mkdir -p "$MOCK_GRID/repos/gstack"
  printf -- "---\nname: gstack\ndescription: repo root\n---\n" > "$MOCK_GRID/repos/gstack/SKILL.md"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -L "$MOCK_SKILLS/gstack" ]
}

@test "does not create symlinks for repos/ dir itself or tests/ dir" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -L "$MOCK_SKILLS/repos" ]
  [ ! -L "$MOCK_SKILLS/tests" ]
}

@test "baseline-submodules.txt allowlist: only listed repos are wired" {
  make_skill "$MOCK_GRID/repos/wiredrepo/skill-w" "skill-w"
  make_skill "$MOCK_GRID/repos/libraryrepo/skill-l" "skill-l"
  printf 'wiredrepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-w" ]      # allowlisted repo → wired
  [ ! -e "$MOCK_SKILLS/skill-l" ]    # library repo → not wired
  [ -L "$MOCK_SKILLS/skill-alpha" ]  # root skills always wired
}

@test "moving a repo to library un-wires its skills on re-run" {
  make_skill "$MOCK_GRID/repos/r1/skill-x" "skill-x"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-x" ]
  printf 'otherrepo\n' > "$MOCK_GRID/baseline-submodules.txt"   # r1 now library
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ ! -e "$MOCK_SKILLS/skill-x" ]    # teardown-rebuild drops the now-library link
}

@test "per-skill entry wires only the named skill, not others in the same repo" {
  make_skill "$MOCK_GRID/repos/myrepo/skill-one" "skill-one"
  make_skill "$MOCK_GRID/repos/myrepo/skill-two" "skill-two"
  printf 'myrepo/skill-one\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-one" ]     # listed → wired
  [ ! -e "$MOCK_SKILLS/skill-two" ]   # not listed → not wired
}

@test "per-skill entry coexists with whole-repo entry" {
  make_skill "$MOCK_GRID/repos/fullrepo/skill-a" "skill-a"
  make_skill "$MOCK_GRID/repos/partialrepo/skill-b" "skill-b"
  make_skill "$MOCK_GRID/repos/partialrepo/skill-c" "skill-c"
  printf 'fullrepo\npartialrepo/skill-b\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-a" ]       # whole-repo → wired
  [ -L "$MOCK_SKILLS/skill-b" ]       # listed per-skill → wired
  [ ! -e "$MOCK_SKILLS/skill-c" ]     # unlisted per-skill → not wired
}

# --- machine overlay (machines/<host>.txt) -----------------------------------

@test "machine overlay adds skills on top of the baseline" {
  make_skill "$MOCK_GRID/repos/baserepo/skill-base" "skill-base"
  make_skill "$MOCK_GRID/repos/extrarepo/skill-extra" "skill-extra"
  printf 'baserepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf 'extrarepo\n' > "$MOCK_GRID/machines/testbox.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-base" ]    # baseline → wired everywhere
  [ -L "$MOCK_SKILLS/skill-extra" ]   # overlay add → wired on this host
}

@test "unknown host wires the baseline only (no matching overlay)" {
  make_skill "$MOCK_GRID/repos/baserepo/skill-base" "skill-base"
  make_skill "$MOCK_GRID/repos/extrarepo/skill-extra" "skill-extra"
  printf 'baserepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf 'extrarepo\n' > "$MOCK_GRID/machines/otherbox.txt"   # overlay for a DIFFERENT host
  GRID_HOST=nosuchbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-base" ]    # baseline still wired
  [ ! -e "$MOCK_SKILLS/skill-extra" ] # other host's overlay → not applied here
}

@test "overlay subtraction (-repo) removes a baseline whole-repo entry" {
  make_skill "$MOCK_GRID/repos/keeprepo/skill-keep" "skill-keep"
  make_skill "$MOCK_GRID/repos/droprepo/skill-drop" "skill-drop"
  printf 'keeprepo\ndroprepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf -- '-droprepo\n' > "$MOCK_GRID/machines/testbox.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-keep" ]
  [ ! -e "$MOCK_SKILLS/skill-drop" ] # subtracted on this host
}

@test "overlay subtraction (-repo/skill) excludes one skill of a whole-repo entry" {
  make_skill "$MOCK_GRID/repos/bigrepo/skill-one" "skill-one"
  make_skill "$MOCK_GRID/repos/bigrepo/skill-two" "skill-two"
  printf 'bigrepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  mkdir -p "$MOCK_GRID/machines"
  printf -- '-bigrepo/skill-two\n' > "$MOCK_GRID/machines/testbox.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_SKILLS/skill-one" ]
  [ ! -e "$MOCK_SKILLS/skill-two" ] # one skill subtracted, rest of repo kept
}

# --- composed-project gating (project:<name>) --------------------------------

@test "project gating wires only the listed composed projects" {
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents"
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents"
  printf -- '---\nname: agent-a\n---\n' > "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents/agent-a.md"
  printf -- '---\nname: agent-b\n---\n' > "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents/agent-b.md"
  printf 'project:team-a\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_AGENTS/agent-a.md" ]    # listed project → wired
  [ ! -e "$MOCK_AGENTS/agent-b.md" ]  # unlisted project → not wired
}

@test "no project: entries wires every composed project (legacy fallback)" {
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents"
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents"
  printf -- '---\nname: agent-a\n---\n' > "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents/agent-a.md"
  printf -- '---\nname: agent-b\n---\n' > "$MOCK_GRID/agent-factory/projects/team-b/_claude-code/agents/agent-b.md"
  printf 'somerepo\n' > "$MOCK_GRID/baseline-submodules.txt"   # no project: entries
  GRID_HOST=testbox GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_AGENTS/agent-a.md" ]
  [ -L "$MOCK_AGENTS/agent-b.md" ]
}

# --- root-owned agents/ (hand-authored subagents, not agent-factory-composed) -

@test "root-owned agents/*.md are wired into AGENTS_DIR" {
  mkdir -p "$MOCK_GRID/agents"
  printf -- '---\nname: grid-ponytail\n---\n' > "$MOCK_GRID/agents/grid-ponytail.md"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_AGENTS/grid-ponytail.md" ]
}

@test "root-owned agent overrides a same-named composed agent" {
  mkdir -p "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents"
  printf -- '---\nname: grid-ponytail\nfrom: composed\n---\n' > "$MOCK_GRID/agent-factory/projects/team-a/_claude-code/agents/grid-ponytail.md"
  mkdir -p "$MOCK_GRID/agents"
  printf -- '---\nname: grid-ponytail\nfrom: root\n---\n' > "$MOCK_GRID/agents/grid-ponytail.md"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  [ -L "$MOCK_AGENTS/grid-ponytail.md" ]
  grep -q "from: root" "$MOCK_AGENTS/grid-ponytail.md"
}

# --- tracked-only discovery in git-checkout submodules (gstack host dirs) ----

# Build repos/gen as its own git checkout: one tracked skill, one tracked skill
# inside a dot-dir (a per-harness copy / maintainer skill: excluded by
# find-skill-mds.sh's root-level dot-dir rule), and one gitignored generated
# copy (gstack setup writes these per host — they must never be wired or counted).
make_gen_repo() {
  local r="$MOCK_GRID/repos/gen"
  make_skill "$r/real-skill" "real-skill"
  make_skill "$r/.claude/skills/dot-tracked" "dot-tracked"
  printf '.slate/\n' > "$r/.gitignore"
  git -C "$r" init -q
  git -C "$r" add -A
  make_skill "$r/.slate/skills/stray-generated" "stray-generated"
}

@test "git-checkout repo: wires tracked skills, ignores dot-dir and gitignored generated copies" {
  make_gen_repo
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/real-skill" ]
  [ ! -e "$MOCK_SKILLS/dot-tracked" ]
  [ ! -e "$MOCK_SKILLS/stray-generated" ]
}

# --- teardown fixes (foundations#8) -------------------------------------------

@test "teardown leaves a link into a sibling dir that merely shares the GRID_DIR prefix" {
  # ${MOCK_GRID}-private/x starts with "$MOCK_GRID" but is NOT under it: the old
  # bare-prefix match deleted this foreign link.
  mkdir -p "${MOCK_GRID}-private/x"
  ln -s "${MOCK_GRID}-private/x" "$MOCK_SKILLS/foreign"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  local rc="$status"
  rm -rf "${MOCK_GRID}-private"
  [ "$rc" -eq 0 ]
  [ -L "$MOCK_SKILLS/foreign" ]
}

@test "teardown removes a stale grid link when SKILLS_DIR is itself a symlink" {
  mkdir -p "$BATS_TEST_TMPDIR/real"
  ln -s "$MOCK_GRID/repos/gone" "$BATS_TEST_TMPDIR/real/old"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/link"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$BATS_TEST_TMPDIR/link" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ ! -L "$BATS_TEST_TMPDIR/real/old" ]
  # ...and the real wiring landed in the real dir behind the symlink.
  [ -L "$BATS_TEST_TMPDIR/real/skill-alpha" ]
}

@test "wire --check follows a symlinked SKILLS_DIR: clean after a wire, drift on a stale link" {
  mkdir -p "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/link"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$BATS_TEST_TMPDIR/link" bash "$REPO_ROOT/scripts/wire.sh"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$BATS_TEST_TMPDIR/link" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
  ln -s "$MOCK_GRID/repos/gone" "$BATS_TEST_TMPDIR/real/stale"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$BATS_TEST_TMPDIR/link" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 1 ]
}

# --- GRID_DRY_HOME: nothing outside the dry home (or in the repo) is touched ---

# Snapshot of a tree (names, modes, sizes, mtimes, link targets), C-sorted.
snapshot() { find "$1" -exec ls -ld {} + | LC_ALL=C sort; }

# A fake "real" home that must come through a dry run byte-for-byte identical:
# a sentinel in skills, a stale grid link, and a rules dir with its own sentinel.
make_fake_real_home() {
  REALHOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$REALHOME/.claude/skills" "$REALHOME/.claude/agents" "$REALHOME/.claude/rules"
  : > "$REALHOME/.claude/skills/SENTINEL"
  : > "$REALHOME/.claude/rules/SENTINEL"
  ln -s "$MOCK_GRID/repos/gone" "$REALHOME/.claude/skills/old"
}

@test "GRID_DRY_HOME: wire touches nothing in the (inherited) real home or the repo" {
  make_fake_real_home
  local before after
  before="$(snapshot "$REALHOME")"
  HOME="$REALHOME" SKILLS_DIR="$REALHOME/.claude/skills" AGENTS_DIR="$REALHOME/.claude/agents" \
    CLAUDE_CONFIG_DIR="$REALHOME/.claude" RULES_DIR="$REALHOME/.claude/rules" \
    GRID_DIR="$MOCK_GRID" GRID_DRY_HOME="$BATS_TEST_TMPDIR/dry" \
    run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  after="$(snapshot "$REALHOME")"
  [ "$before" = "$after" ]
  [ -L "$REALHOME/.claude/skills/old" ]            # stale link NOT torn down
  [ -L "$BATS_TEST_TMPDIR/dry/.claude/skills/skill-alpha" ]
  [ ! -e "$MOCK_GRID/.wired.manifest" ]
  [ ! -e "$MOCK_GRID/SKILLS.md" ]
}

@test "GRID_DRY_HOME: wire --check leaves the real home untouched" {
  make_fake_real_home
  local before after
  before="$(snapshot "$REALHOME")"
  HOME="$REALHOME" SKILLS_DIR="$REALHOME/.claude/skills" AGENTS_DIR="$REALHOME/.claude/agents" \
    CLAUDE_CONFIG_DIR="$REALHOME/.claude" RULES_DIR="$REALHOME/.claude/rules" \
    GRID_DIR="$MOCK_GRID" GRID_DRY_HOME="$BATS_TEST_TMPDIR/dry" \
    run bash "$REPO_ROOT/scripts/wire.sh" --check
  # Exit 0 or 1 are both fine here (the dry home is what is compared); what
  # matters is that the real home did not move.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  after="$(snapshot "$REALHOME")"
  [ "$before" = "$after" ]
  [ ! -e "$MOCK_GRID/.wired.manifest" ]
}

@test "wire --check against a correctly wired live dir still exits 0 (dry-home child)" {
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"match a fresh wire"* ]]
}

# --- GRID_BASELINE: point the baseline layer at another file ------------------

@test "GRID_BASELINE wires only the repos named in that file" {
  make_skill "$MOCK_GRID/repos/repo-one/sk-one" "sk-one"
  make_skill "$MOCK_GRID/repos/repo-two/sk-two" "sk-two"
  # No $MOCK_GRID/baseline-submodules.txt exists; the override names one repo.
  printf 'repo-one\n' > "$BATS_TEST_TMPDIR/alt-baseline.txt"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" GRID_BASELINE="$BATS_TEST_TMPDIR/alt-baseline.txt" \
    run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/sk-one" ]
  [ ! -e "$MOCK_SKILLS/sk-two" ]
}

# --- WP-006: never replace a foreign link or a real file that shares a grid name ---

@test "a foreign symlink at a grid skill name survives wire" {
  mkdir -p "$OTHER_DIR/mine"
  ln -s "$OTHER_DIR/mine" "$MOCK_SKILLS/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$MOCK_SKILLS/skill-alpha")" = "$OTHER_DIR/mine" ]   # not re-pointed
  [[ "$output" == *"skip (not managed): skill-alpha"* ]]
  grep -q "^skill	skill-alpha	.*	skipped	not managed$" "$MOCK_GRID/.wired.manifest"
  [ -L "$MOCK_SKILLS/skill-beta" ]                                   # the rest still wires
}

@test "a regular file at a grid skill name survives wire" {
  printf 'keep me\n' > "$MOCK_SKILLS/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ ! -L "$MOCK_SKILLS/skill-alpha" ]
  [ "$(cat "$MOCK_SKILLS/skill-alpha")" = "keep me" ]
  [[ "$output" == *"skip (not managed): skill-alpha"* ]]
  # A file must not be reported with the real-dir wording reconcile.sh parses.
  [[ "$output" != *"skip (real dir, not managed): skill-alpha"* ]]
  grep -q "^skill	skill-alpha	.*	skipped	not managed$" "$MOCK_GRID/.wired.manifest"
}

@test "a dangling foreign symlink at a grid skill name survives wire" {
  ln -s "$OTHER_DIR/does-not-exist" "$MOCK_SKILLS/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$MOCK_SKILLS/skill-alpha")" = "$OTHER_DIR/does-not-exist" ]
  [[ "$output" == *"skip (not managed): skill-alpha"* ]]
}

@test "a foreign symlink at a grid agent name survives wire" {
  mkdir -p "$MOCK_GRID/agents"
  printf -- '---\nname: zz-a\n---\n' > "$MOCK_GRID/agents/zz-a.md"
  printf 'mine\n' > "$OTHER_DIR/zz-a.md"
  ln -s "$OTHER_DIR/zz-a.md" "$MOCK_AGENTS/zz-a.md"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$MOCK_AGENTS/zz-a.md")" = "$OTHER_DIR/zz-a.md" ]
  [[ "$output" == *"skip (not managed): zz-a.md"* ]]
  grep -q "^agent	zz-a.md	.*	skipped	not managed$" "$MOCK_GRID/.wired.manifest"
}

@test "wire --check exits 0 when a foreign link shadows a grid skill name" {
  mkdir -p "$OTHER_DIR/mine"
  ln -s "$OTHER_DIR/mine" "$MOCK_SKILLS/skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}

@test "a symlink into the grid at a skill name is still replaced (override precedence)" {
  # A repo skill and a root skill share a name: the root copy is wired second and must
  # replace the repo link wire just made (a link into the grid is ours).
  make_skill "$MOCK_GRID/repos/r1/skill-alpha" "skill-alpha"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$MOCK_SKILLS/skill-alpha")" = "$MOCK_GRID/skills/skill-alpha/" ]
}

# --- WP-007: ownership is decided by the resolved path, not a string prefix ----

@test "wire via a symlinked clone path then the real path removes a stale link and --check exits 0" {
  ln -s "$MOCK_GRID" "$BATS_TEST_TMPDIR/clone"
  # A stale grid link left in the OTHER spelling of the clone path (an older wire).
  ln -s "$BATS_TEST_TMPDIR/clone/repos/gone" "$MOCK_SKILLS/gone-skill"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ ! -L "$MOCK_SKILLS/gone-skill" ]
  # Wired through the symlinked spelling, checked through the real one: no false drift.
  GRID_DIR="$BATS_TEST_TMPDIR/clone" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}

@test "a link to GRID_DIR/../elsewhere/x survives teardown" {
  # Textually under "$GRID_DIR/", physically outside it: not ours.
  ln -s "$MOCK_GRID/../elsewhere/x" "$MOCK_SKILLS/dotdot"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/dotdot" ]
}

@test "a newline-named foreign symlink does not abort wire and links are fully rebuilt" {
  # The name is split by a line-based read: readlink of the first half failed under set -e
  # and silently aborted teardown on every run.
  local nl=$'\n'
  ln -s "$OTHER_DIR/x" "$MOCK_SKILLS/bad${nl}name"
  ln -s "$MOCK_GRID/repos/gone" "$MOCK_SKILLS/stale${nl}grid"   # an owned one, same oddity
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/bad${nl}name" ]          # foreign: untouched
  [ ! -L "$MOCK_SKILLS/stale${nl}grid" ]      # ours: torn down
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -L "$MOCK_SKILLS/skill-beta" ]
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh" --check
  [ "$status" -eq 0 ]
}

# links_of DIR: "name -> target" for every symlink in DIR, C-sorted (NUL-safe enough for tests).
links_of() {
  find "$1" -maxdepth 1 -type l | LC_ALL=C sort | while IFS= read -r l; do
    printf '%s -> %s\n' "$l" "$(readlink "$l")"
  done
}

@test "read-only agents dir: wire exits 2 and the skill links are unchanged" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  local before; before="$(links_of "$MOCK_SKILLS")"
  [ -n "$before" ]
  chmod a-w "$MOCK_AGENTS"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing was changed"* ]]
  [ "$(links_of "$MOCK_SKILLS")" = "$before" ]
}

@test "an ln shim that fails on its 3rd call leaves the previous links restored and exits non-zero" {
  make_skill "$MOCK_GRID/skills/skill-gamma" "skill-gamma"
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh"
  local before; before="$(links_of "$MOCK_SKILLS")"
  [ "$(printf '%s\n' "$before" | wc -l | tr -d ' ')" -eq 3 ]
  # The shim fails exactly once (3rd call), so the restore step's own ln works.
  local real_ln; real_ln="$(command -v ln)"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '#!/usr/bin/env bash\nc=$(cat "%s/count" 2>/dev/null || echo 0); c=$((c+1)); echo $c > "%s/count"\n[ "$c" -ne 3 ] || exit 1\nexec "%s" "$@"\n' \
    "$BATS_TEST_TMPDIR/shim" "$BATS_TEST_TMPDIR/shim" "$real_ln" > "$BATS_TEST_TMPDIR/shim/ln"
  chmod +x "$BATS_TEST_TMPDIR/shim/ln"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -ne 0 ]
  [ "$(links_of "$MOCK_SKILLS")" = "$before" ]     # all three back, none lost
}
