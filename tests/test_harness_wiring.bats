#!/usr/bin/env bats
# Tests for non-Claude harness wiring in wire.sh (change `multi-harness`, group 1).
#
# Scenarios come from openspec/changes/multi-harness/specs/harness-wiring/spec.md and
# tasks.md 1.7. Every test runs the REAL scripts/wire.sh against a MOCK grid
# (GRID_DIR=$MOCK_GRID). Every harness dir resolves under GRID_HARNESS_HOME, a temp dir
# whose leaf contains a SPACE on purpose (any unquoted expansion in the new code then
# fails here); assert_sandboxed is the tripwire. These are the author's own checks;
# independent verification belongs to qa-engineer.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`

load helpers/setup

setup() {
  common_setup
  export GRID_HOST=testbox
  mkdir -p "$MOCK_GRID/machines"
  # Two portable skills.
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  make_skill "$MOCK_GRID/skills/skill-beta"  "skill-beta"
  # Three that must NOT reach a non-Claude dir: a hard-coded Claude path, a frontmatter
  # name that differs from the dir, and a 1100-char description.
  make_skill "$MOCK_GRID/skills/claude-skill" "claude-skill"
  printf 'Read ~/.claude/settings.json first.\n' >> "$MOCK_GRID/skills/claude-skill/SKILL.md"
  make_skill "$MOCK_GRID/skills/template" "template-skill"
  mkdir -p "$MOCK_GRID/skills/long-desc"
  printf -- '---\nname: long-desc\ndescription: %s\n---\n' "$(printf 'x%.0s' $(seq 1 1100))" \
    > "$MOCK_GRID/skills/long-desc/SKILL.md"
  OVERLAY="$MOCK_GRID/machines/testbox.txt"
  HS="$GRID_HARNESS_HOME/.agents/skills"        # the shared dir (codex/opencode/pi/...)
  MANIFEST="$MOCK_GRID/.wired.manifest"
}

teardown() {
  unset GRID_HOST GRID_BASELINE
  rm -rf "${MOCK_GRID}-private"
  common_teardown
}

# wire [args...]: real wire.sh against the mock grid; stderr is kept apart in $stderr.
wire() {
  GRID_DIR="$MOCK_GRID" run --separate-stderr bash "$REPO_ROOT/scripts/wire.sh" "$@"
}

# tree DIR: every entry under DIR with its link target, C-sorted ("path -> target").
tree() {
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf '%s -> %s\n' "$p" "$(readlink "$p")"; else printf '%s\n' "$p"; fi
  done
}

# stub_agent TARGET NAME.EXT: a fake composed agent file for projects/p (no composer needed).
stub_agent() {
  mkdir -p "$MOCK_GRID/agent-factory/projects/p/_$1/agents"
  printf 'x\n' > "$MOCK_GRID/agent-factory/projects/p/_$1/agents/$2"
}

# ---------------------------------------------------------------- activation

@test "no harness: entry: nothing is created under the harness home" {
  wire
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ -z "$(tree "$GRID_HARNESS_HOME")" ]
}

@test "harness:claude is accepted and does nothing" {
  printf 'harness:claude\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ -z "$(tree "$GRID_HARNESS_HOME")" ]
}

@test "harness:codex + harness:opencode: each portable skill once in the shared dir" {
  printf 'harness:codex\nharness:opencode\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ -L "$HS/skill-alpha" ]
  [ -L "$HS/skill-beta" ]
  # One link per name: the shared dir holds exactly the two portable skills.
  [ "$(find "$HS" -mindepth 1 | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(readlink "$HS/skill-alpha")" = "$MOCK_GRID/skills/skill-alpha/" ]
  # The non-portable ones are absent there but still wired for Claude.
  [ ! -e "$HS/claude-skill" ]
  [ ! -e "$HS/template" ]
  [ ! -e "$HS/long-desc" ]
  [ -L "$MOCK_SKILLS/claude-skill" ]
  [ -L "$MOCK_SKILLS/template" ]
  [ -L "$MOCK_SKILLS/long-desc" ]
  # Claude dirs are still populated; no other harness dir exists (no agents composed).
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  [ ! -e "$GRID_HARNESS_HOME/.codex" ] && [ ! -e "$GRID_HARNESS_HOME/.config" ]
}

@test "skip reasons are recorded in .wired.manifest" {
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  grep -qF "skill@~/.agents/skills	claude-skill	$MOCK_GRID/skills/claude-skill/	skipped	claude-specific" "$MANIFEST"
  grep -qF "skill@~/.agents/skills	template	$MOCK_GRID/skills/template/	skipped	name-mismatch" "$MANIFEST"
  grep -qF "skill@~/.agents/skills	long-desc	$MOCK_GRID/skills/long-desc/	skipped	description-long" "$MANIFEST"
  grep -qF "skill@~/.agents/skills	skill-alpha	$MOCK_GRID/skills/skill-alpha/	wired	" "$MANIFEST"
  # Claude rows are unchanged in shape.
  grep -qF "skill	skill-alpha	$MOCK_GRID/skills/skill-alpha/	wired	" "$MANIFEST"
}

@test "GRID_HARNESS replaces the manifest set for the run" {
  printf 'harness:antigravity\n' > "$OVERLAY"
  GRID_HARNESS=pi wire
  [ "$status" -eq 0 ]
  [ -L "$HS/skill-alpha" ]                                          # pi: shared dir
  [ ! -e "$GRID_HARNESS_HOME/.gemini" ]                             # antigravity: not active
}

@test "GRID_HARNESS=nonesuch exits 2, names the valid harnesses and changes nothing" {
  GRID_HARNESS=nonesuch wire
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nonesuch"* ]]
  [[ "$stderr" == *"codex"* ]]
  [[ "$stderr" == *"opencode"* ]]
  [ -z "$(tree "$GRID_HARNESS_HOME")" ]
  [ -z "$(tree "$MOCK_SKILLS")" ]
  [ ! -e "$MANIFEST" ]
}

@test "an unknown name in the manifest is rejected the same way" {
  printf 'harness:nonesuch\n' > "$OVERLAY"
  wire
  [ "$status" -eq 2 ]
  [ -z "$(tree "$MOCK_SKILLS")" ]
}

@test "precedence matches Claude: a root skill beats a same-named repo skill in the shared dir" {
  make_skill "$MOCK_GRID/repos/r/skills/dup" "dup"
  make_skill "$MOCK_GRID/skills/dup" "dup"
  printf 'r\n' > "$MOCK_GRID/baseline-submodules.txt"
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ "$(readlink "$HS/dup")" = "$MOCK_GRID/skills/dup/" ]
  [ "$(find "$HS" -name dup | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------- Pi / OpenClaw (group 6)
# Both are skills-only rows: they read the shared dir and nothing else. Agents are
# stubbed for EVERY compose target so that a registry row that wrongly gained an
# agents_dir/compose_target would link something and fail these tests.

stub_all_agents() {
  stub_agent claude-code a.md
  stub_agent codex a.toml
  stub_agent opencode a.md
  stub_agent gemini-cli a.md
  stub_agent openclaw-native a.md
}

# only_shared_dir: the harness home holds exactly .agents/skills, nothing else.
only_shared_dir() {
  [ "$(find "$GRID_HARNESS_HOME" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$GRID_HARNESS_HOME/.agents" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}

@test "Pi: skills land in the shared dir, no Pi agents dir is created, --check exits 0" {
  stub_all_agents
  GRID_HARNESS=pi wire
  [ "$status" -eq 0 ]
  [ -L "$HS/skill-alpha" ]
  [ -L "$HS/skill-beta" ]
  # Pi documents no sub-agents: neither its agents dir nor any agent link may appear.
  [ ! -e "$GRID_HARNESS_HOME/.pi/agent/agents" ]
  # The ONLY thing under the harness home is the shared skills dir (no .codex, .config, ...).
  only_shared_dir
  # Re-running with the same GRID_HARNESS: the wired state has no drift.
  GRID_HARNESS=pi wire --check
  [ "$status" -eq 0 ]
}

@test "OpenClaw: skills land in the shared dir and nothing is created under .openclaw" {
  stub_all_agents
  GRID_HARNESS=openclaw wire
  [ "$status" -eq 0 ]
  [ -L "$HS/skill-alpha" ]
  [ -L "$HS/skill-beta" ]
  [ ! -e "$GRID_HARNESS_HOME/.openclaw" ]
  # Agents for OpenClaw come from deploy_openclaw.sh, never from wire.sh.
  only_shared_dir
  GRID_HARNESS=openclaw wire --check
  [ "$status" -eq 0 ]
}

@test "Pi + OpenClaw together share one link per skill; a root/repo name clash links the root copy once" {
  # Pi keeps the first skill it discovers on a name clash, so a duplicate must never
  # be linked: the shared dir must hold exactly one link and it must be the root copy.
  make_skill "$MOCK_GRID/repos/r/skills/dup" "dup"
  make_skill "$MOCK_GRID/skills/dup" "dup"
  printf 'r\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_HARNESS=pi,openclaw wire
  [ "$status" -eq 0 ]
  [ "$(readlink "$HS/dup")" = "$MOCK_GRID/skills/dup/" ]
  [ "$(find "$HS" -name dup | wc -l | tr -d ' ')" -eq 1 ]
  # Two harnesses, one dir: still just the portable skills, each exactly once.
  [ "$(find "$HS" -mindepth 1 | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(grep -c "^skill@~/.agents/skills	dup	" "$MANIFEST")" -eq 1 ]
}

# ---------------------------------------------------------------- codex agents (group 3)

@test "GRID_HARNESS=codex links a composed _codex agent into .codex/agents; a second run changes nothing" {
  stub_agent codex x.toml
  GRID_HARNESS=codex wire
  [ "$status" -eq 0 ]
  [ -L "$GRID_HARNESS_HOME/.codex/agents/x.toml" ]
  # The link resolves to the composed file inside the (mock) grid.
  [ "$(readlink "$GRID_HARNESS_HOME/.codex/agents/x.toml")" = "$MOCK_GRID/agent-factory/projects/p/_codex/agents/x.toml" ]
  local t1 m1
  t1="$(tree "$GRID_HARNESS_HOME")"; m1="$(cat "$MANIFEST")"
  GRID_HARNESS=codex wire
  [ "$status" -eq 0 ]
  [ "$(tree "$GRID_HARNESS_HOME")" = "$t1" ]
  [ "$(cat "$MANIFEST")" = "$m1" ]
}

# ---------------------------------------------------------------- space / XDG

@test "paths with a space: OpenCode agents land under GRID_HARNESS_HOME, XDG_CONFIG_HOME ignored" {
  assert_sandboxed
  stub_agent opencode x.md
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" GRID_HARNESS=opencode wire
  [ "$status" -eq 0 ]
  [ -L "$GRID_HARNESS_HOME/.config/opencode/agents/x.md" ]
  [ ! -e "$BATS_TEST_TMPDIR/xdg" ]
}

@test "XDG_CONFIG_HOME relocates OpenCode agents when GRID_HARNESS_HOME is unset" {
  assert_sandboxed          # BEFORE the var is dropped: the sandbox must hold first
  stub_agent opencode x.md
  local fakehome="$BATS_TEST_TMPDIR/fakehome"; mkdir -p "$fakehome"
  GRID_DIR="$MOCK_GRID" GRID_HARNESS=opencode XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" HOME="$fakehome" \
    run env -u GRID_HARNESS_HOME bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/xdg/opencode/agents/x.md" ]
  [ ! -e "$fakehome/.config" ]
  [ -L "$fakehome/.agents/skills/skill-alpha" ]     # the shared dir follows HOME, not XDG
}

@test "GRID_DRY_HOME wins over GRID_HARNESS_HOME and XDG for every harness path" {
  stub_agent opencode x.md
  GRID_DRY_HOME="$BATS_TEST_TMPDIR/dry" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" GRID_HARNESS=opencode wire
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/dry/.config/opencode/agents/x.md" ]
  [ -z "$(tree "$GRID_HARNESS_HOME")" ]
  [ ! -e "$BATS_TEST_TMPDIR/xdg" ]
}

@test "G1 sentinel: a dry run never writes under the real home" {
  assert_sandboxed          # BEFORE GRID_HARNESS_HOME is dropped
  local rh="$BATS_TEST_TMPDIR/realhome" dry="$BATS_TEST_TMPDIR/dry"
  mkdir -p "$rh/.agents/skills" "$rh/.codex/agents"
  printf 'keep\n' > "$rh/.agents/skills/sentinel"
  printf 'keep\n' > "$rh/.codex/agents/sentinel.toml"
  cp "$rh/.agents/skills/sentinel" "$BATS_TEST_TMPDIR/s1"
  cp "$rh/.codex/agents/sentinel.toml" "$BATS_TEST_TMPDIR/s2"
  stub_agent codex x.toml
  local before; before="$(tree "$rh")"
  GRID_DIR="$MOCK_GRID" GRID_DRY_HOME="$dry" GRID_HARNESS=codex HOME="$rh" \
    run env -u GRID_HARNESS_HOME bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$dry/.agents/skills/skill-alpha" ]
  [ -L "$dry/.codex/agents/x.toml" ]
  [ "$(tree "$rh")" = "$before" ]                       # nothing new under the real home
  cmp "$rh/.agents/skills/sentinel" "$BATS_TEST_TMPDIR/s1"
  cmp "$rh/.codex/agents/sentinel.toml" "$BATS_TEST_TMPDIR/s2"
}

# ---------------------------------------------------------------- idempotency / teardown

@test "a second run leaves every link and the wiring manifest byte-identical" {
  printf 'harness:codex\nharness:opencode\n' > "$OVERLAY"
  stub_agent codex x.toml
  wire
  [ "$status" -eq 0 ]
  local t1 m1
  t1="$(tree "$GRID_HARNESS_HOME")"; m1="$(cat "$MANIFEST")"
  wire
  [ "$status" -eq 0 ]
  [ "$(tree "$GRID_HARNESS_HOME")" = "$t1" ]
  [ "$(cat "$MANIFEST")" = "$m1" ]
  [ -L "$GRID_HARNESS_HOME/.codex/agents/x.toml" ]
}

@test "-harness: removes the grid links and keeps a foreign link" {
  printf 'harness:codex\nharness:opencode\n' > "$OVERLAY"
  stub_agent codex x.toml
  wire
  [ -L "$HS/skill-alpha" ]
  [ -L "$GRID_HARNESS_HOME/.codex/agents/x.toml" ]
  mkdir -p "$OTHER_DIR/ext"
  ln -s "$OTHER_DIR/ext" "$HS/external"
  printf 'harness:codex\nharness:opencode\n-harness:codex\n-harness:opencode\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ ! -e "$HS/skill-alpha" ]
  [ ! -L "$HS/skill-alpha" ]
  [ ! -L "$GRID_HARNESS_HOME/.codex/agents/x.toml" ]
  [ "$(readlink "$HS/external")" = "$OTHER_DIR/ext" ]
}

@test "deactivation without any harness: entry still tears down stale grid links" {
  mkdir -p "$HS"
  ln -s "$MOCK_GRID/skills/gone" "$HS/stale"
  wire
  [ "$status" -eq 0 ]
  [ ! -L "$HS/stale" ]
}

@test "a real directory in the shared dir is skipped with 'exists, not managed'" {
  printf 'harness:codex\nharness:opencode\n' > "$OVERLAY"
  mkdir -p "$HS/skill-alpha"
  printf 'mine\n' > "$HS/skill-alpha/note"
  wire
  [ "$status" -eq 0 ]
  [ ! -L "$HS/skill-alpha" ]
  [ -f "$HS/skill-alpha/note" ]
  [[ "$output" == *"skip (~/.agents/skills: exists, not managed): skill-alpha"* ]]
  # The reconcile.sh prefix must never appear (it would rm -rf the Claude-dir twin).
  ! printf '%s\n' "$output" | grep -q '^  skip (real dir, not managed)' || false
  grep -qF "skill@~/.agents/skills	skill-alpha	$MOCK_GRID/skills/skill-alpha/	skipped	exists, not managed" "$MANIFEST"
  # And reconcile.sh, run against the same dirs, finds nothing to reconcile. It calls
  # $GRID_DIR/scripts/wire.sh itself, so the mock grid borrows the real scripts dir.
  ln -s "$REPO_ROOT/scripts" "$MOCK_GRID/scripts"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/reconcile.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to reconcile"* ]]
  [ -f "$HS/skill-alpha/note" ]
}

@test "a foreign and a dangling symlink are never replaced, and --check stays clean" {
  printf 'harness:codex\n' > "$OVERLAY"
  mkdir -p "$HS" "$OTHER_DIR/foo"
  ln -s "$OTHER_DIR/foo" "$HS/skill-alpha"            # foreign, resolves
  ln -s "$OTHER_DIR/nowhere" "$HS/skill-beta"         # dangling
  wire
  [ "$status" -eq 0 ]
  [ "$(readlink "$HS/skill-alpha")" = "$OTHER_DIR/foo" ]
  [ "$(readlink "$HS/skill-beta")" = "$OTHER_DIR/nowhere" ]
  grep -qF "skill-alpha	$MOCK_GRID/skills/skill-alpha/	skipped	exists, not managed" "$MANIFEST"
  grep -qF "skill-beta	$MOCK_GRID/skills/skill-beta/	skipped	exists, not managed" "$MANIFEST"
  wire --check
  [ "$status" -eq 0 ]
}

@test "a symlink into a sibling of the grid dir survives, in the Claude dir and the shared dir" {
  printf 'harness:codex\n' > "$OVERLAY"
  mkdir -p "${MOCK_GRID}-private/x" "$HS"
  ln -s "${MOCK_GRID}-private/x" "$MOCK_SKILLS/x"
  ln -s "${MOCK_GRID}-private/x" "$HS/x"
  wire
  [ "$status" -eq 0 ]
  [ "$(readlink "$MOCK_SKILLS/x")" = "${MOCK_GRID}-private/x" ]
  [ "$(readlink "$HS/x")" = "${MOCK_GRID}-private/x" ]
}

@test "a symlinked shared dir: its stale grid link is listed by --check, then removed by a run" {
  printf 'harness:codex\n' > "$OVERLAY"
  mkdir -p "$GRID_HARNESS_HOME/.agents" "$OTHER_DIR/real-skills"
  ln -s "$OTHER_DIR/real-skills" "$HS"
  ln -s "$MOCK_GRID/skills/gone" "$OTHER_DIR/real-skills/stale"
  wire --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"stale"* ]]
  wire
  [ "$status" -eq 0 ]
  [ ! -L "$OTHER_DIR/real-skills/stale" ]
  [ -L "$OTHER_DIR/real-skills/skill-alpha" ]            # linked THROUGH the symlinked dir
}

# ---------------------------------------------------------------- --check

@test "--check: exit 0 after a wire, and it writes nothing" {
  printf 'harness:codex\nharness:opencode\n' > "$OVERLAY"
  stub_agent codex x.toml
  wire
  local t1; t1="$(tree "$GRID_HARNESS_HOME")"
  wire --check
  [ "$status" -eq 0 ]
  [ "$(tree "$GRID_HARNESS_HOME")" = "$t1" ]
}

@test "--check: a stale grid link in the shared dir is drift (exit 1, names the link)" {
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  ln -s "$MOCK_GRID/skills/gone" "$HS/stale-link"
  wire --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"stale-link"* ]]
}

@test "--check: a stale grid link in the Codex agents dir of an INACTIVE harness is drift" {
  wire
  mkdir -p "$GRID_HARNESS_HOME/.codex/agents"
  ln -s "$MOCK_GRID/agent-factory/projects/p/_codex/agents/stale.toml" "$GRID_HARNESS_HOME/.codex/agents/stale.toml"
  wire --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"stale.toml"* ]]
  # A real wire clears it, after which --check is clean again.
  wire
  [ ! -L "$GRID_HARNESS_HOME/.codex/agents/stale.toml" ]
  wire --check
  [ "$status" -eq 0 ]
}

@test "--check: a missing harness link is drift" {
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  rm "$HS/skill-beta"
  wire --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"skill-beta"* ]]
}

# ---------------------------------------------------------------- runtime root (G6)

@test "G6: the gstack runtime-root link is not fanned out; its manifest row says runtime-root" {
  mkdir -p "$MOCK_GRID/scripts/lib"
  make_skill "$MOCK_GRID/repos/gstack/stubskill" "stubskill"
  printf -- '---\nname: gstack-root\ndescription: repo marker\n---\n' > "$MOCK_GRID/repos/gstack/SKILL.md"
  printf '%s\n' 'gstack | gstack | bin/marker | bash | ./setup' > "$MOCK_GRID/scripts/lib/runtimes.txt"
  printf 'gstack\n' > "$MOCK_GRID/baseline-submodules.txt"
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ "$(readlink "$MOCK_SKILLS/gstack")" = "$MOCK_GRID/repos/gstack" ]   # Claude keeps it
  [ ! -e "$HS/gstack" ]
  [ ! -L "$HS/gstack" ]
  [ -L "$HS/stubskill" ]                                                # real skills still go
  grep -qF "skill@~/.agents/skills	gstack	$MOCK_GRID/repos/gstack	skipped	runtime-root" "$MANIFEST"
  # No stdout skip line for it either.
  [[ "$output" != *"gstack"*"exists, not managed"* ]]
}

# ---------------------------------------------------------------- agents

@test "composed agent files are linked into the harness agents dir; unwired projects are not" {
  printf 'harness:codex\nproject:p\n' > "$OVERLAY"
  stub_agent codex x.toml
  mkdir -p "$MOCK_GRID/agent-factory/projects/q/_codex/agents"
  printf 'y\n' > "$MOCK_GRID/agent-factory/projects/q/_codex/agents/y.toml"
  wire
  [ "$status" -eq 0 ]
  [ -L "$GRID_HARNESS_HOME/.codex/agents/x.toml" ]
  [ ! -e "$GRID_HARNESS_HOME/.codex/agents/y.toml" ]
  grep -qF "agent@~/.codex/agents	x.toml	" "$MANIFEST"
}

@test "an existing agent file is never replaced" {
  printf 'harness:codex\n' > "$OVERLAY"
  stub_agent codex x.toml
  mkdir -p "$GRID_HARNESS_HOME/.codex/agents"
  printf 'mine\n' > "$GRID_HARNESS_HOME/.codex/agents/x.toml"
  wire
  [ "$status" -eq 0 ]
  [ ! -L "$GRID_HARNESS_HOME/.codex/agents/x.toml" ]
  [ "$(cat "$GRID_HARNESS_HOME/.codex/agents/x.toml")" = "mine" ]
  grep -qF "agent@~/.codex/agents	x.toml	" "$MANIFEST"
  grep -F "agent@~/.codex/agents	x.toml	" "$MANIFEST" | grep -q 'exists, not managed'
}

# ---------------------------------------------------------------- python3

@test "an active harness without python3 exits 2 before any write" {
  printf 'harness:codex\n' > "$OVERLAY"
  PATH="$(path_without 'python3*' python)" wire
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"python3"* ]]
  [ -z "$(tree "$MOCK_SKILLS")" ]
  [ -z "$(tree "$GRID_HARNESS_HOME")" ]
}

@test "no active harness needs no python3 for the harness code" {
  PATH="$(path_without 'python3*' python)" wire
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
}

# ---------------------------------------------------------------- catalog.sh / sources.sh

@test "a harness: line leaves catalog.sh --check and sources.sh unchanged (typed-entry skip)" {
  printf '[submodule "repos/alpha"]\n\tpath = repos/alpha\n\turl = https://example.com/o/alpha.git\n' > "$MOCK_GRID/.gitmodules"
  make_skill "$MOCK_GRID/repos/alpha/skill-a" "skill-a"
  printf 'alpha\nproject:grid\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/catalog.sh" "$MOCK_GRID/SKILLS.md"
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/sources.sh" "$BATS_TEST_TMPDIR/src.ref" >/dev/null
  printf 'alpha\nproject:grid\nharness:codex\n-harness:pi\n' > "$MOCK_GRID/baseline-submodules.txt"
  GRID_DIR="$MOCK_GRID" run bash "$REPO_ROOT/scripts/catalog.sh" --check
  [ "$status" -eq 0 ]
  GRID_DIR="$MOCK_GRID" bash "$REPO_ROOT/scripts/sources.sh" "$BATS_TEST_TMPDIR/src.new" >/dev/null
  cmp "$BATS_TEST_TMPDIR/src.ref" "$BATS_TEST_TMPDIR/src.new"
}

# ---------------------------------------------------------------- sandbox helper

@test "assert_sandboxed fails when GRID_HARNESS_HOME is the real home" {
  GRID_HARNESS_HOME="$REAL_HOME" run assert_sandboxed
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING"* ]]
}

@test "assert_sandboxed fails for a GRID_HARNESS_HOME inside the real home, or unset, or empty" {
  GRID_HARNESS_HOME="$REAL_HOME/some/where" run assert_sandboxed
  [ "$status" -ne 0 ]
  GRID_HARNESS_HOME="" run assert_sandboxed
  [ "$status" -ne 0 ]
  unset GRID_HARNESS_HOME
  run assert_sandboxed
  [ "$status" -ne 0 ]
}

@test "common_setup sandboxes the harness home (space in the path) and drops inherited vars" {
  assert_sandboxed
  [[ "$GRID_HARNESS_HOME" == *" "* ]]
  [ -d "$GRID_HARNESS_HOME" ]
  [ -z "${GRID_HARNESS:-}" ] && [ -z "${XDG_CONFIG_HOME:-}" ] && [ -z "${GRID_DRY_HOME:-}" ]
}

# ---------------------------------------------------------------- unit: harness.sh

@test "harness_path: ~/ expansion, XDG rule, GRID_DRY_HOME precedence, '-' and empty base" {
  . "$REPO_ROOT/scripts/lib/harness.sh"
  # GRID_HARNESS_HOME (with a space) is the base; XDG is ignored when it is set.
  [ "$(XDG_CONFIG_HOME=/x harness_path '~/.agents/skills')" = "$GRID_HARNESS_HOME/.agents/skills" ]
  [ "$(XDG_CONFIG_HOME=/x harness_path '~/.config/opencode/agents')" = "$GRID_HARNESS_HOME/.config/opencode/agents" ]
  # Both unset: XDG applies to ~/.config/... only.
  [ "$(unset GRID_HARNESS_HOME; HOME=/h XDG_CONFIG_HOME=/x harness_path '~/.config/opencode/agents')" = "/x/opencode/agents" ]
  [ "$(unset GRID_HARNESS_HOME; HOME=/h XDG_CONFIG_HOME=/x harness_path '~/.codex/agents')" = "/h/.codex/agents" ]
  [ "$(unset GRID_HARNESS_HOME; HOME=/h harness_path '~/.config/opencode/agents')" = "/h/.config/opencode/agents" ]
  # GRID_DRY_HOME beats GRID_HARNESS_HOME.
  [ "$(GRID_DRY_HOME=/d harness_path '~/.codex/agents')" = "/d/.codex/agents" ]
  [ "$(harness_path '-')" = "-" ]
  run bash -c ". '$REPO_ROOT/scripts/lib/harness.sh'; unset GRID_HARNESS_HOME GRID_DRY_HOME; HOME= harness_path '~/.agents/skills'"
  [ "$status" -ne 0 ]
}

@test "registry: seven rows; fields resolve; names validate" {
  . "$REPO_ROOT/scripts/lib/harness.sh"
  [ "$(harness_names | wc -l | tr -d ' ')" -eq 7 ]
  [ "$(harness_names | head -1)" = "claude" ]
  [ "$(harness_field codex agents_dir)" = "~/.codex/agents" ]
  [ "$(harness_field opencode rules_file)" = "~/.config/opencode/AGENTS.md" ]
  [ "$(harness_field gemini compose_target)" = "gemini-cli" ]
  [ "$(harness_field antigravity agents_dir)" = "-" ]
  [ "$(harness_field pi rules_harness)" = "agents-md" ]
  harness_valid openclaw
  ! harness_valid nonesuch
}

# ---------------------------------------------------------------- unit: portability filter

# fm_skill DIR 'frontmatter body lines' [body]: write DIR/SKILL.md.
fm_skill() {
  mkdir -p "$1"
  printf -- '---\n%s\n---\n%s\n' "$2" "${3:-body}" > "$1/SKILL.md"
}

# portable_fails DIR REASON: skill_portable must exit 1 AND print exactly REASON. The old
# `[ "$(skill_portable DIR || true)" = REASON ]` form discarded the status, so a reason that
# printed correctly but returned 0 (a skill that would still be linked) went unnoticed.
portable_fails() {
  run skill_portable "$1"
  [ "$status" -eq 1 ]
  [ "$output" = "$2" ]
}

@test "skill_portable: the five reasons, in order" {
  . "$REPO_ROOT/scripts/lib/skill-portable.sh"
  local d="$BATS_TEST_TMPDIR/sk"
  mkdir -p "$d/nofm" && printf 'no frontmatter\n' > "$d/nofm/SKILL.md"
  portable_fails "$d/nofm" no-frontmatter
  mkdir -p "$d/nofile"
  portable_fails "$d/nofile" no-frontmatter
  fm_skill "$d/a-b" 'name: other'
  portable_fails "$d/a-b" name-mismatch
  fm_skill "$d/Bad_Name" 'name: Bad_Name'
  portable_fails "$d/Bad_Name" name-invalid
  fm_skill "$d/trail--dash" 'name: trail--dash'
  portable_fails "$d/trail--dash" name-invalid
  fm_skill "$d/ok" 'name: ok'
  run skill_portable "$d/ok"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Each claude-specific marker, including one in a nested file; -I skips a binary.
  fm_skill "$d/c1" 'name: c1' 'see ~/.claude/x'
  fm_skill "$d/c2" 'name: c2' 'see $HOME/.claude'
  fm_skill "$d/c3" 'name: c3' 'run in .claude/hooks'
  fm_skill "$d/c4" 'name: c4' 'echo $CLAUDE_PROJECT_DIR'
  fm_skill "$d/c5" 'name: c5'
  mkdir -p "$d/c5/refs" && printf 'x ~/.claude/y\n' > "$d/c5/refs/n.md"
  local s
  for s in c1 c2 c3 c4 c5; do portable_fails "$d/$s" claude-specific; done
  fm_skill "$d/bin" 'name: bin'
  printf '\000\001.claude/\000' > "$d/bin/blob.bin"
  run skill_portable "$d/bin"
  [ "$status" -eq 0 ]
  # A trailing slash on the dir (how wire.sh links root skills) is the same skill.
  run skill_portable "$d/ok/"
  [ "$status" -eq 0 ]
}

# The documented order is "the first hit wins" (skill-portable.sh): a skill with two
# problems reports only the earlier one, so a later check cannot jump the queue unnoticed.
@test "skill_portable: with two reasons the first in the documented order wins" {
  . "$REPO_ROOT/scripts/lib/skill-portable.sh"
  local d="$BATS_TEST_TMPDIR/sk2"
  # Invalid dir name AND frontmatter naming something else: mismatch is checked first.
  fm_skill "$d/Bad_Name" 'name: other'
  portable_fails "$d/Bad_Name" name-mismatch
  # Invalid dir name AND a Claude-only path in the body: name-invalid is checked first.
  fm_skill "$d/Bad_Two" 'name: Bad_Two' 'see ~/.claude/x'
  portable_fails "$d/Bad_Two" name-invalid
  # Over-long description AND a Claude-only path: description-long is checked first.
  fm_skill "$d/long-and-claude" "name: long-and-claude
description: $(printf 'x%.0s' $(seq 1 1100))" 'see ~/.claude/x'
  portable_fails "$d/long-and-claude" description-long
}

@test "skill_portable: description limit is 1024 chars after folding a block scalar" {
  . "$REPO_ROOT/scripts/lib/skill-portable.sh"
  local d="$BATS_TEST_TMPDIR/sk" long ok
  long="$(printf 'w%.0s' $(seq 1 1025))"; ok="$(printf 'w%.0s' $(seq 1 1024))"
  fm_skill "$d/edge-ok" "name: edge-ok
description: $ok"
  run skill_portable "$d/edge-ok"; [ "$status" -eq 0 ]
  fm_skill "$d/edge-long" "name: edge-long
description: $long"
  [ "$(skill_portable "$d/edge-long" || true)" = "description-long" ]
  # Folded block: 2 lines of 600 chars + the fold space = 1201 > 1024.
  local half; half="$(printf 'w%.0s' $(seq 1 600))"
  fm_skill "$d/edge-block" "name: edge-block
description: >
  $half
  $half"
  [ "$(skill_portable "$d/edge-block" || true)" = "description-long" ]
}

@test "skill_frontmatter.py: plain, quoted, folded and literal scalars; exit 1 without a block" {
  local py="$REPO_ROOT/scripts/lib/skill_frontmatter.py" d="$BATS_TEST_TMPDIR/fm" out
  mkdir -p "$d"
  printf -- '---\nname: plain-one\ndescription: A plain value\n---\nbody\n' > "$d/1.md"
  [ "$(python3 -I "$py" "$d/1.md")" = "$(printf 'plain-one\tA plain value')" ]
  printf -- "---\nname: 'sq'\ndescription: 'it''s: quoted'\n---\n" > "$d/2.md"
  [ "$(python3 -I "$py" "$d/2.md")" = "$(printf "sq\tit's: quoted")" ]
  printf -- '---\nname: "dq"\ndescription: "say \\"hi\\" there"\n---\n' > "$d/3.md"
  [ "$(python3 -I "$py" "$d/3.md")" = "$(printf 'dq\tsay "hi" there')" ]
  printf -- '---\nname: folded\ndescription: >\n  line one\n  line two\nother: x\n---\n' > "$d/4.md"
  [ "$(python3 -I "$py" "$d/4.md")" = "$(printf 'folded\tline one line two')" ]
  printf -- '---\nname: literal\ndescription: |-\n  alpha\n  beta\n---\n' > "$d/5.md"
  [ "$(python3 -I "$py" "$d/5.md")" = "$(printf 'literal\talpha beta')" ]
  printf -- '---\nname: cont\ndescription: starts here\n  and goes on\n---\n' > "$d/6.md"
  [ "$(python3 -I "$py" "$d/6.md")" = "$(printf 'cont\tstarts here and goes on')" ]
  # --len prints the folded length, in characters (not bytes).
  printf -- '---\nname: uni\ndescription: caf\xc3\xa9\n---\n' > "$d/7.md"
  [ "$(python3 -I "$py" --len "$d/7.md")" = "$(printf 'uni\t4')" ]
  printf 'no block\n' > "$d/8.md"
  run python3 -I "$py" "$d/8.md"; [ "$status" -eq 1 ]
  printf -- '---\nname: unclosed\n' > "$d/9.md"
  run python3 -I "$py" "$d/9.md"; [ "$status" -eq 1 ]
  run python3 -I "$py" "$d/missing.md"; [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------- opencode agents (group 4)

@test "GRID_HARNESS=opencode links composed _opencode agents into .config/opencode/agents; a second run changes nothing" {
  stub_agent opencode x.md
  stub_agent opencode y.md
  GRID_HARNESS=opencode wire
  [ "$status" -eq 0 ]
  [ -L "$GRID_HARNESS_HOME/.config/opencode/agents/x.md" ]
  [ -L "$GRID_HARNESS_HOME/.config/opencode/agents/y.md" ]
  # The link resolves to the composed file inside the (mock) grid.
  [ "$(readlink "$GRID_HARNESS_HOME/.config/opencode/agents/x.md")" = "$MOCK_GRID/agent-factory/projects/p/_opencode/agents/x.md" ]
  local t1 m1
  t1="$(tree "$GRID_HARNESS_HOME")"; m1="$(cat "$MANIFEST")"
  GRID_HARNESS=opencode wire
  [ "$status" -eq 0 ]
  [ "$(tree "$GRID_HARNESS_HOME")" = "$t1" ]
  [ "$(cat "$MANIFEST")" = "$m1" ]
  # Only the OpenCode agents dir was written: no Codex or Gemini agent dir appears.
  [ ! -e "$GRID_HARNESS_HOME/.codex" ]
  [ ! -e "$GRID_HARNESS_HOME/.gemini" ]
}

# ================================================================ Gemini / Antigravity (multi-harness group 5)
# gemini links specialists into .gemini/agents and skills into the shared .agents/skills;
# antigravity is skills-only, into its OWN skills dir (path unverified, see docs/harnesses.md).

@test "GRID_HARNESS=gemini links _gemini-cli agents into .gemini/agents and skills into the shared dir" {
  stub_all_agents
  GRID_HARNESS=gemini wire
  [ "$status" -eq 0 ]
  [ -L "$HS/skill-alpha" ]
  [ -L "$HS/skill-beta" ]
  [ -L "$GRID_HARNESS_HOME/.gemini/agents/a.md" ]
  [ "$(readlink "$GRID_HARNESS_HOME/.gemini/agents/a.md")" = "$MOCK_GRID/agent-factory/projects/p/_gemini-cli/agents/a.md" ]
  # Only the gemini agent target was linked: nothing from the codex/opencode/openclaw stubs,
  # and no Antigravity dir (.gemini holds just agents/ and agents/a.md).
  [ "$(find "$GRID_HARNESS_HOME/.gemini" -mindepth 1 | wc -l | tr -d ' ')" -eq 2 ]
  [ ! -e "$GRID_HARNESS_HOME/.gemini/antigravity-cli" ]
  [ ! -e "$GRID_HARNESS_HOME/.codex" ]
  [ ! -e "$GRID_HARNESS_HOME/.config" ]
  # Idempotent, and no drift afterwards.
  local t1; t1="$(tree "$GRID_HARNESS_HOME")"
  GRID_HARNESS=gemini wire
  [ "$status" -eq 0 ]
  [ "$(tree "$GRID_HARNESS_HOME")" = "$t1" ]
  GRID_HARNESS=gemini wire --check
  [ "$status" -eq 0 ]
}

@test "GRID_HARNESS=antigravity links skills into .gemini/antigravity-cli/skills and creates no agents dir" {
  stub_all_agents
  GRID_HARNESS=antigravity wire
  [ "$status" -eq 0 ]
  [ -L "$GRID_HARNESS_HOME/.gemini/antigravity-cli/skills/skill-alpha" ]
  [ -L "$GRID_HARNESS_HOME/.gemini/antigravity-cli/skills/skill-beta" ]
  # Skills-only: no agents dir, no agent link, and the shared dir is not used.
  [ ! -e "$GRID_HARNESS_HOME/.gemini/agents" ]
  [ ! -e "$GRID_HARNESS_HOME/.agents" ]
  [ "$(find "$GRID_HARNESS_HOME" \( -name 'a.md' -o -name 'a.toml' \) | wc -l | tr -d ' ')" -eq 0 ]
  GRID_HARNESS=antigravity wire --check
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- WP-007: HOME unset

# wire_nohome [args...]: wire.sh with HOME and GRID_HARNESS_HOME unset, so every "~/" registry
# path is unresolvable. SKILLS_DIR / AGENTS_DIR / RULES_DIR / CLAUDE_CONFIG_DIR stay set
# (common_setup exports them), so the Claude side does not need HOME at all.
wire_nohome() {
  GRID_DIR="$MOCK_GRID" run --separate-stderr env -u HOME -u GRID_HARNESS_HOME \
    bash "$REPO_ROOT/scripts/wire.sh" "$@"
}

@test "HOME unset, no harness active: exit 0, Claude links rebuilt, one warning" {
  wire
  [ "$status" -eq 0 ]
  local before; before="$(tree "$MOCK_SKILLS")"
  wire_nohome
  [ "$status" -eq 0 ]
  [ "$(tree "$MOCK_SKILLS")" = "$before" ]
  [ -L "$MOCK_SKILLS/skill-alpha" ]
  # Exactly one HOME warning, not one per registry dir.
  [ "$(printf '%s\n' "$stderr" | grep -c 'HOME is unset')" -eq 1 ]
}

@test "HOME unset, harness active, GRID_HARNESS_HOME unset: exit 2, links unchanged" {
  wire
  local before; before="$(tree "$MOCK_SKILLS")"
  GRID_HARNESS=codex wire_nohome
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nothing was changed"* ]]
  [ "$(tree "$MOCK_SKILLS")" = "$before" ]     # the Claude links were not torn down first
  [ -L "$MOCK_SKILLS/skill-alpha" ]
}

@test "--check with HOME unset and an active harness exits 2" {
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  wire_nohome --check
  [ "$status" -eq 2 ]
}

@test "a hand-made link into the grid in a harness dir is reported when removed" {
  printf 'harness:codex\n' > "$OVERLAY"
  wire
  [ "$status" -eq 0 ]
  [ -L "$HS/skill-alpha" ]
  # The operator's own link into the grid, with a name the grid never wired.
  ln -s "$MOCK_GRID/skills/skill-alpha" "$HS/my-own"
  wire
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"wire: removed link not in the previous manifest: $HS/my-own"* ]]
  # Removal itself is unchanged (D16 default: report, keep removing) ...
  [ ! -e "$HS/my-own" ] && [ ! -L "$HS/my-own" ]
  # ... and a link wire itself made last time is not reported.
  [[ "$stderr" != *"previous manifest: $HS/skill-alpha"* ]]
  [ -L "$HS/skill-alpha" ]
}

@test "--check with HOME unset and no active harness does not report drift" {
  wire
  wire_nohome --check
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- WP-012: fan-out guards

@test "a PATH-stub ln that plants a dir symlink at the destination before the real ln creates nothing inside the victim dir" {
  # Simulates the race between the "does the destination exist" check and the ln: the stub
  # plants a symlink-to-a-directory at the destination, then runs the real ln. Plain `ln -s`
  # follows it and drops the link INSIDE the victim dir; `ln -sn` does not.
  local victim="$BATS_TEST_TMPDIR/victim" stubs="$BATS_TEST_TMPDIR/stubs" real_ln
  real_ln="$(command -v ln)"
  mkdir -p "$victim" "$stubs"
  cat > "$stubs/ln" <<STUB
#!/usr/bin/env bash
dest="\${@: -1}"
case "\$dest" in
  "$HS"/*) if [ ! -e "\$dest" ] && [ ! -L "\$dest" ]; then "$real_ln" -s "$victim" "\$dest"; fi ;;
esac
exec "$real_ln" "\$@"
STUB
  chmod +x "$stubs/ln"
  PATH="$stubs:$PATH" GRID_HARNESS=codex wire
  [ -z "$(ls -A "$victim")" ]
}

@test "a foreign symlink in SKILLS_DIR is not fanned out to the shared dir" {
  # A portable skill the grid does not own, linked into the Claude dir by someone else.
  make_skill "$OTHER_DIR/foreign" "foreign"
  ln -s "$OTHER_DIR/foreign" "$MOCK_SKILLS/foreign"
  GRID_HARNESS=codex wire
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/foreign" ]
  [ -L "$HS/skill-alpha" ]                                  # the grid's own skills do go
  [ ! -e "$HS/foreign" ] && [ ! -L "$HS/foreign" ]
}

@test "-harness:<h> with opencode still active keeps the shared links and removes the per-harness agents (codex, pi, gemini, openclaw)" {
  local h
  stub_all_agents
  for h in codex pi gemini openclaw; do
    printf 'harness:%s\nharness:opencode\n' "$h" > "$OVERLAY"
    wire
    [ "$status" -eq 0 ]
    printf 'harness:%s\nharness:opencode\n-harness:%s\n' "$h" "$h" > "$OVERLAY"
    wire
    [ "$status" -eq 0 ]
    # opencode shares ~/.agents/skills with every one of them: its links survive.
    [ -L "$HS/skill-alpha" ]
    [ -L "$HS/skill-beta" ]
  done
  # codex and gemini own agent dirs of their own: gone with the deactivation. (The last loop
  # pass left openclaw deactivated, so look at the first two harnesses' dirs directly.)
  printf 'harness:codex\nharness:gemini\nharness:opencode\n' > "$OVERLAY"
  wire
  [ -L "$GRID_HARNESS_HOME/.codex/agents/a.toml" ] && [ -L "$GRID_HARNESS_HOME/.gemini/agents/a.md" ]
  printf 'harness:codex\nharness:gemini\nharness:opencode\n-harness:codex\n' > "$OVERLAY"
  wire
  [ ! -L "$GRID_HARNESS_HOME/.codex/agents/a.toml" ]
  [ -L "$GRID_HARNESS_HOME/.gemini/agents/a.md" ]
  [ -L "$HS/skill-alpha" ]
  printf 'harness:codex\nharness:gemini\nharness:opencode\n-harness:gemini\n' > "$OVERLAY"
  wire
  [ ! -L "$GRID_HARNESS_HOME/.gemini/agents/a.md" ]
  [ -L "$HS/skill-alpha" ]
}

# A registry file the tests point wire.sh at (needs GRID_ALLOW_REGISTRY=1).
write_registry() { # $@ = row lines
  REG="$BATS_TEST_TMPDIR/registry.txt"
  printf '%s\n' "claude ~/.claude/skills ~/.claude/agents claude-code - -" "$@" > "$REG"
}

@test "registry rows with 5 columns, a relative path, or .. exit 2 naming the row, with no writes" {
  local row
  for row in \
    "codex ~/.agents/skills ~/.codex/agents codex ~/.codex/AGENTS.md" \
    "codex skills ~/.codex/agents codex - -" \
    "codex ~/.agents/skills ../.codex/agents codex - -" \
    "codex ~/.agents/skills ~/x/../.codex/agents codex - -" \
    "codex ~/.agents/skills ~/.codex/agents codex rules.md agents-md"; do
    write_registry "$row"
    GRID_ALLOW_REGISTRY=1 HARNESS_REGISTRY="$REG" GRID_HARNESS=codex wire
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"registry"* ]] && [[ "$stderr" == *"codex"* ]]
    [ -z "$(tree "$GRID_HARNESS_HOME")" ]
    [ -z "$(tree "$MOCK_SKILLS")" ]            # nothing written, not even the Claude links
  done
}

@test "the shipped registry passes the registry check" {
  . "$REPO_ROOT/scripts/lib/harness.sh"
  harness_registry_check
}

@test "relative XDG_CONFIG_HOME is ignored" {
  . "$REPO_ROOT/scripts/lib/harness.sh"
  [ "$(unset GRID_HARNESS_HOME; HOME=/h XDG_CONFIG_HOME=rel harness_path '~/.config/opencode/agents')" = "/h/.config/opencode/agents" ]
  [ "$(unset GRID_HARNESS_HOME; HOME=/h XDG_CONFIG_HOME=/x harness_path '~/.config/opencode/agents')" = "/x/opencode/agents" ]
}

@test "harness_path refuses a value with a .. component" {
  . "$REPO_ROOT/scripts/lib/harness.sh"
  run harness_path '~/../etc'
  [ "$status" -ne 0 ]
  run harness_path '/a/../b'
  [ "$status" -ne 0 ]
  [ "$(harness_path '~/.a..b/c')" = "$GRID_HARNESS_HOME/.a..b/c" ]   # a dotted NAME is fine
}

@test "HARNESS_REGISTRY without GRID_ALLOW_REGISTRY=1 is ignored" {
  write_registry "evil ~/.agents/skills - - - -"
  HARNESS_REGISTRY="$REG" run bash -c ". '$REPO_ROOT/scripts/lib/harness.sh'; harness_valid evil"
  [ "$status" -ne 0 ]                                  # ignored: evil is not a registry row
  GRID_ALLOW_REGISTRY=1 HARNESS_REGISTRY="$REG" run bash -c ". '$REPO_ROOT/scripts/lib/harness.sh'; harness_valid evil"
  [ "$status" -eq 0 ]                                  # honoured behind the flag
}

@test "two projects shipping the same agent name: the second skip names the clash" {
  mkdir -p "$MOCK_GRID/agent-factory/projects/p/_codex/agents" "$MOCK_GRID/agent-factory/projects/q/_codex/agents"
  printf 'x\n' > "$MOCK_GRID/agent-factory/projects/p/_codex/agents/a.toml"
  printf 'y\n' > "$MOCK_GRID/agent-factory/projects/q/_codex/agents/a.toml"
  GRID_HARNESS=codex wire
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip (~/.codex/agents: name clash with p): a.toml"* ]]
  [[ "$output" != *"skip (~/.codex/agents: exists, not managed): a.toml"* ]]
  [[ "$output" != *"skip (real dir, not managed)"* ]]
  grep -qF "agent@~/.codex/agents	a.toml	$MOCK_GRID/agent-factory/projects/q/_codex/agents/a.toml	skipped	name clash with p" "$MANIFEST"
  # The first project's agent is the one linked.
  [ "$(readlink "$GRID_HARNESS_HOME/.codex/agents/a.toml")" = "$MOCK_GRID/agent-factory/projects/p/_codex/agents/a.toml" ]
}

@test "a truly foreign entry keeps the 'exists, not managed' wording" {
  mkdir -p "$GRID_HARNESS_HOME/.codex/agents"
  printf 'mine\n' > "$GRID_HARNESS_HOME/.codex/agents/a.toml"
  stub_agent codex a.toml
  GRID_HARNESS=codex wire
  [[ "$output" == *"skip (~/.codex/agents: exists, not managed): a.toml"* ]]
}

@test "GRID_HARNESS=, exits 2 before any write and changes nothing" {
  wire
  [ "$status" -eq 0 ]
  local before; before="$(tree "$MOCK_SKILLS")"
  GRID_HARNESS=, wire
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"GRID_HARNESS"* ]]
  [ "$(tree "$MOCK_SKILLS")" = "$before" ]
}

@test "an unknown manifest harness is rejected even while GRID_HARNESS is set" {
  printf 'harness:nonesuch\n' > "$OVERLAY"
  GRID_HARNESS=codex wire
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nonesuch"* ]]
  [ -z "$(tree "$GRID_HARNESS_HOME")" ]
}

@test "docs/harnesses.md documents the three limits" {
  grep -qF 'Two harnesses whose agents dirs are aliased' "$REPO_ROOT/docs/harnesses.md"
  grep -qF 'only after `-harness:<name>` has been wired once' "$REPO_ROOT/docs/harnesses.md"
  grep -qF 'lags the Claude dir' "$REPO_ROOT/docs/harnesses.md"
}
