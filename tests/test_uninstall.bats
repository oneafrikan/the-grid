#!/usr/bin/env bats
# Tests for scripts/uninstall.sh: the kill switch that removes what the-grid put on a machine.
#
# Every test runs the REAL scripts/uninstall.sh from inside a MOCK grid (a copy of scripts/,
# hooks/ and the hook emitter) against temp dirs only: HOME, SKILLS_DIR, AGENTS_DIR, RULES_DIR,
# CLAUDE_CONFIG_DIR, GRID_STATE_DIR and GRID_HARNESS_HOME all come from common_setup /
# below, and assert_sandboxed is the tripwire. The state to remove is created by the REAL
# wire.sh, so a test also proves uninstall removes what wire.sh creates.
#
# These are the author's own checks; independent verification belongs to qa-engineer.

load helpers/setup

setup() {
  common_setup
  # A temp HOME (set AFTER common_setup, which captured REAL_HOME for the sandbox check).
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  export GRID_HOST=testhost
  # Nothing here may read the machine's real crontab or scheduler dirs.
  export LAUNCH_AGENTS_DIR="$HOME/LaunchAgents" SYSTEMD_USER_DIR="$HOME/systemd-user"
  assert_sandboxed

  # The mock grid IS a git clone with a remote, so --purge has something to check.
  # Everything the grid wires is made here: one skill, one agent, a rule pack, a gstack
  # repo (for the runtime-root link) and a codex harness (links outside ~/.claude).
  mkdir -p "$MOCK_GRID/agent-factory" "$MOCK_GRID/agents" "$MOCK_GRID/rules/mypack" \
           "$MOCK_GRID/repos/gstack/skill-g" "$MOCK_GRID/machines"
  cp -R "$REPO_ROOT/scripts" "$MOCK_GRID/scripts"
  cp -R "$REPO_ROOT/hooks" "$MOCK_GRID/hooks"
  cp "$REPO_ROOT/agent-factory/deploy_hooks.py" "$MOCK_GRID/agent-factory/deploy_hooks.py"
  make_skill "$MOCK_GRID/skills/skill-alpha" "skill-alpha"
  make_skill "$MOCK_GRID/repos/gstack/skill-g" "skill-g"
  printf -- '---\nname: agent-alpha\ndescription: test agent\n---\n' > "$MOCK_GRID/agents/agent-alpha.md"
  printf -- '---\npaths:\n  - "**/*.sh"\n---\n# topic\n- a rule\n' > "$MOCK_GRID/rules/mypack/topic.md"
  cp "$REPO_ROOT/rules/denylist.txt" "$MOCK_GRID/rules/denylist.txt"   # rules.py refuses a grid without one
  printf 'gstack\nrules:mypack\nharness:codex\n' > "$MOCK_GRID/baseline-submodules.txt"
  printf '.wired.manifest\n' > "$MOCK_GRID/.gitignore"

  SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
  FIXTURE="$REPO_ROOT/tests/fixtures/hooks/settings-handwritten.json"
  CODEX_AGENTS_MD="$GRID_HARNESS_HOME/.codex/AGENTS.md"
  PRIVATE_SIB="${MOCK_GRID}-private"       # a sibling whose NAME starts with the grid's
  UNINSTALL="$MOCK_GRID/scripts/uninstall.sh"
  ELSEWHERE="$MOCK_HOOK_ROOT/elsewhere"
  mkdir -p "$ELSEWHERE"
}

teardown() {
  rm -rf "${PRIVATE_SIB:-}"
  unset GRID_HOST LAUNCH_AGENTS_DIR SYSTEMD_USER_DIR
  common_teardown
}

# wire_machine: the real wire.sh wires the mock grid into the temp dirs, including the hook
# (starting from the hand-written settings fixture) and a rules block in a codex AGENTS.md.
wire_machine() {
  mkdir -p "$CLAUDE_CONFIG_DIR" "$(dirname "$CODEX_AGENTS_MD")"
  cp "$FIXTURE" "$SETTINGS"
  printf '# my own codex notes\n' > "$CODEX_AGENTS_MD"
  GRID_DIR="$MOCK_GRID" GRID_NO_CATALOG=1 run bash "$MOCK_GRID/scripts/wire.sh"
  [ "$status" -eq 0 ] || { echo "wire.sh failed ($status): $output" >&2; return 1; }
}

# add_foreign: things that are NOT the grid's and must survive: a foreign link, a real dir,
# a dangling foreign link, a link into a sibling dir whose name merely starts with the grid's,
# and (under rules/grid) a real file.
add_foreign() {
  mkdir -p "$SKILLS_DIR/real-dir" "$PRIVATE_SIB/skills/priv" "$ELSEWHERE/skill-x"
  printf 'mine\n' > "$SKILLS_DIR/real-dir/SKILL.md"
  ln -s "$ELSEWHERE/skill-x" "$SKILLS_DIR/foreign-link"
  ln -s "$ELSEWHERE/gone" "$SKILLS_DIR/foreign-dangling"
  ln -s "$PRIVATE_SIB/skills/priv" "$SKILLS_DIR/private-sibling"
  ln -s "$PRIVATE_SIB/skills/priv" "$AGENTS_DIR/private-sibling"
  ln -s "$ELSEWHERE/agent.md" "$AGENTS_DIR/foreign-agent.md"
  printf 'mine\n' > "$RULES_DIR/grid/mypack/my-own-rule.md"
}

# make_clone: turn the mock grid into a clean git clone: committed, with a bare remote that
# has everything pushed.
make_clone() {
  local remote="$MOCK_HOOK_ROOT/remote.git"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  git init -q --bare "$remote"
  git -C "$MOCK_GRID" init -q -b main
  git -C "$MOCK_GRID" add -A
  git -C "$MOCK_GRID" commit -q -m mock
  git -C "$MOCK_GRID" remote add origin "$remote"
  git -C "$MOCK_GRID" push -q origin main
}

# snap DIR...: a listing of every path with its content checksum or link target, so any
# change (a removed link, an edited file, a new file) shows up as a diff.
snap() {
  local d p
  for d in "$@"; do
    [ -e "$d" ] || [ -L "$d" ] || { echo "ABSENT $d"; continue; }
    find "$d" | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then echo "L $p -> $(readlink "$p")"
      elif [ -f "$p" ]; then echo "F $p $(cksum < "$p")"
      else echo "D $p"; fi
    done
  done
}
snap_all() {
  snap "$SKILLS_DIR" "$AGENTS_DIR" "$RULES_DIR" "$CLAUDE_CONFIG_DIR" "$GRID_HARNESS_HOME" \
       "$GRID_STATE_DIR" "$MOCK_GRID" "$PRIVATE_SIB" "$ELSEWHERE"
}

uninstall() { # [args...]: from an unrelated cwd, as the contract says
  cd "$OTHER_DIR"
  GRID_DIR="$MOCK_GRID" run bash "$UNINSTALL" "$@"
}

# ----------------------------------------------------------------- the fixture itself

@test "fixture: wire.sh really wired links, hook and rules block (else the tests below prove nothing)" {
  wire_machine
  [ -L "$SKILLS_DIR/skill-alpha" ]
  [ -L "$SKILLS_DIR/gstack" ]                       # the runtime-root link
  [ -L "$AGENTS_DIR/agent-alpha.md" ]
  [ -L "$RULES_DIR/grid/mypack/topic.md" ]
  [ -n "$(find "$GRID_HARNESS_HOME/.agents/skills" -type l)" ]
  grep -qF 'GENERATED by the-grid' "$SETTINGS"
  grep -qF 'BEGIN the-grid rules' "$CODEX_AGENTS_MD"
}

# ----------------------------------------------------------------- 1. dry run

@test "dry run (the default) changes nothing and says so" {
  wire_machine; add_foreign
  mkdir -p "$GRID_STATE_DIR"; printf 'learned\n' > "$GRID_STATE_DIR/instincts.json"
  before="$(snap_all)"
  uninstall
  [ "$status" -eq 0 ]
  after="$(snap_all)"
  [ "$before" = "$after" ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"would remove  skill $SKILLS_DIR/skill-alpha"* ]]
  [[ "$output" == *"would remove  runtime-link $SKILLS_DIR/gstack"* ]]
  [[ "$output" == *"would remove  agent $AGENTS_DIR/agent-alpha.md"* ]]
  [[ "$output" == *"would remove  rule $RULES_DIR/grid/mypack/topic.md"* ]]
  [[ "$output" == *"would remove  hook auto-handoff entry in $SETTINGS"* ]]
  [[ "$output" == *"would remove  rules block in $CODEX_AGENTS_MD"* ]]
  [[ "$output" == *"dry run: would remove"* ]]
}

@test "dry run: the state dir is kept and --purge is named as the way to delete it" {
  wire_machine
  mkdir -p "$GRID_STATE_DIR"; printf 'learned\n' > "$GRID_STATE_DIR/instincts.json"
  uninstall --yes
  [ "$status" -eq 0 ]
  [ -f "$GRID_STATE_DIR/instincts.json" ]
  [[ "$output" == *"kept"*"$GRID_STATE_DIR"*"--purge deletes it"* ]]
}

@test "an unknown argument, and --force without --purge, are refused with exit 2" {
  uninstall --nope
  [ "$status" -eq 2 ]
  uninstall --yes --force
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------- 2. --yes removes ours only

@test "--yes removes the grid's links, hook and rules block, keeps everything that is not ours" {
  wire_machine; add_foreign
  uninstall --yes
  [ "$status" -eq 0 ]
  # Ours: gone, everywhere wire.sh put it.
  [ ! -e "$SKILLS_DIR/skill-alpha" ]
  [ ! -L "$SKILLS_DIR/skill-alpha" ]
  [ ! -L "$SKILLS_DIR/gstack" ]
  [ ! -L "$SKILLS_DIR/skill-g" ]
  [ ! -L "$AGENTS_DIR/agent-alpha.md" ]
  [ ! -L "$RULES_DIR/grid/mypack/topic.md" ]
  [ -z "$(find "$GRID_HARNESS_HOME/.agents/skills" -type l)" ]
  # Not ours: untouched.
  [ -f "$SKILLS_DIR/real-dir/SKILL.md" ]
  [ "$(readlink "$SKILLS_DIR/foreign-link")" = "$ELSEWHERE/skill-x" ]
  [ "$(readlink "$SKILLS_DIR/foreign-dangling")" = "$ELSEWHERE/gone" ]
  [ "$(readlink "$AGENTS_DIR/foreign-agent.md")" = "$ELSEWHERE/agent.md" ]
  # A real file under rules/grid keeps its dirs alive.
  [ -f "$RULES_DIR/grid/mypack/my-own-rule.md" ]
}

@test "--yes leaves hand-written settings.json hooks and keys byte-for-byte (only our entry goes)" {
  wire_machine
  # wire added exactly one thing to the fixture...
  ! cmp -s "$FIXTURE" "$SETTINGS" || false
  uninstall --yes
  [ "$status" -eq 0 ]
  # ...and removing it gives the fixture back exactly.
  cmp "$FIXTURE" "$SETTINGS"
}

@test "--yes removes the rules block from a codex instruction file and keeps the user's own text" {
  wire_machine
  uninstall --yes
  [ "$status" -eq 0 ]
  ! grep -qF 'BEGIN the-grid rules' "$CODEX_AGENTS_MD" || false
  grep -qxF '# my own codex notes' "$CODEX_AGENTS_MD"
}

@test "a rules block in a symlinked instruction file is reported, not edited" {
  wire_machine
  real="$ELSEWHERE/codex-agents.md"
  cp "$CODEX_AGENTS_MD" "$real"; rm "$CODEX_AGENTS_MD"; ln -s "$real" "$CODEX_AGENTS_MD"
  before="$(cksum < "$real")"
  uninstall --yes
  [ "$status" -eq 0 ]
  [ "$(cksum < "$real")" = "$before" ]
  [[ "$output" == *"kept"*"rules block remains in $CODEX_AGENTS_MD"* ]]
}

@test "a symlinked settings.json is not edited; uninstall fails loudly and the rest still goes" {
  wire_machine
  cp "$SETTINGS" "$ELSEWHERE/settings.json"; rm "$SETTINGS"; ln -s "$ELSEWHERE/settings.json" "$SETTINGS"
  before="$(cksum < "$ELSEWHERE/settings.json")"
  uninstall --yes
  [ "$status" -eq 1 ]
  [ "$(cksum < "$ELSEWHERE/settings.json")" = "$before" ]
  [[ "$output" == *"FAILED"*"hook"* ]]
  [ ! -L "$SKILLS_DIR/skill-alpha" ]
}

@test "the ledger: dry run shows the grid-install plan, --yes runs 'grid uninstall' and removes it" {
  wire_machine
  mkdir -p "$GRID_STATE_DIR"
  # An empty-but-present ledger is the smallest valid one: grid uninstall then removes just the file.
  : > "$GRID_STATE_DIR/installed.manifest"
  uninstall
  [ "$status" -eq 0 ]
  [ -f "$GRID_STATE_DIR/installed.manifest" ]
  [[ "$output" == *"would remove ledger $GRID_STATE_DIR/installed.manifest"* ]]
  uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -e "$GRID_STATE_DIR/installed.manifest" ]
}

# ----------------------------------------------------------------- 3. second run is a no-op

@test "a second --yes run is a clean no-op that says nothing to remove" {
  wire_machine; add_foreign
  uninstall --yes
  [ "$status" -eq 0 ]
  mid="$(snap_all)"
  uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
  [ "$mid" = "$(snap_all)" ]
  # and a dry run after it agrees
  uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

# ----------------------------------------------------------------- 4. --purge

@test "--purge refuses on a dirty clone, changes nothing, and says why" {
  wire_machine; make_clone
  printf 'wip\n' > "$MOCK_GRID/uncommitted.txt"
  before="$(snap_all)"
  uninstall --yes --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to purge"*"uncommitted"* ]]
  [ "$before" = "$(snap_all)" ]
  [ -d "$MOCK_GRID" ]
}

@test "--purge refuses on unpushed commits, then --force goes ahead" {
  wire_machine; make_clone
  printf 'x\n' > "$MOCK_GRID/new.txt"
  git -C "$MOCK_GRID" add new.txt && git -C "$MOCK_GRID" commit -q -m local-only
  uninstall --yes --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"unpushed"* ]]
  [ -d "$MOCK_GRID" ]
  uninstall --yes --purge --force
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_GRID" ]
}

@test "--purge on a clean, pushed clone removes links, the state dir and the clone itself" {
  wire_machine; make_clone
  mkdir -p "$GRID_STATE_DIR"; printf 'learned\n' > "$GRID_STATE_DIR/instincts.json"
  priv="$HOME/.the-grid-private"; mkdir -p "$priv"; printf 'secret\n' > "$priv/denylist.txt"
  uninstall --yes --purge
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_GRID" ]
  [ ! -e "$GRID_STATE_DIR" ]
  [ ! -L "$SKILLS_DIR/skill-alpha" ]
  # Never outside GRID_DIR and the state dir.
  [ "$(cat "$priv/denylist.txt")" = secret ]
  [[ "$output" == *"removed"*"clone $MOCK_GRID"* ]]
}

@test "--purge dry run lists the clone and the state dir but deletes neither" {
  wire_machine; make_clone
  mkdir -p "$GRID_STATE_DIR"
  uninstall --purge
  [ "$status" -eq 0 ]
  [ -d "$MOCK_GRID" ]
  [ -d "$GRID_STATE_DIR" ]
  [[ "$output" == *"would remove  clone $MOCK_GRID"* ]]
  [[ "$output" == *"would remove  state dir $GRID_STATE_DIR"* ]]
}

@test "--purge refuses a state dir that is the home directory (or holds the private repo)" {
  wire_machine; make_clone
  GRID_STATE_DIR="$HOME" uninstall --yes --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to purge the state dir"* ]]
  [ -d "$MOCK_GRID" ]
  mkdir -p "$HOME/.the-grid-private"
  GRID_STATE_DIR="$HOME/.the-grid-private" uninstall --yes --purge
  [ "$status" -eq 1 ]
  [ -d "$HOME/.the-grid-private" ]
}

@test "guard: --purge refuses a state dir inside or equal to the Claude config dir, or inside the clone" {
  wire_machine; make_clone
  mkdir -p "$CLAUDE_CONFIG_DIR/state" "$MOCK_GRID/state"
  printf 'x\n' > "$CLAUDE_CONFIG_DIR/state/f"
  GRID_STATE_DIR="$CLAUDE_CONFIG_DIR/state" uninstall --yes --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside, the Claude config dir"* ]]
  GRID_STATE_DIR="$CLAUDE_CONFIG_DIR" uninstall --yes --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude config dir"* ]]
  GRID_STATE_DIR="$MOCK_GRID/state" uninstall --yes --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside, the clone"* ]]
  [ -f "$CLAUDE_CONFIG_DIR/state/f" ]
  [ -d "$MOCK_GRID" ]
  [ -L "$SKILLS_DIR/skill-alpha" ]
}

@test "guard: a GRID_DIR that is HOME or an ancestor of it is refused (rc 2), even for a dry run" {
  wire_machine
  before="$(snap_all)"
  cd "$OTHER_DIR"
  GRID_DIR="$HOME" run bash "$UNINSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is, or contains, your home directory"* ]]
  GRID_DIR="$(dirname "$HOME")" run bash "$UNINSTALL" --yes
  [ "$status" -eq 2 ]
  [ "$before" = "$(snap_all)" ]
}

@test "guard: a symlinked state dir given with a trailing slash loses only the link, never its target" {
  wire_machine; make_clone
  mkdir -p "$ELSEWHERE/real-state"; printf 'keep\n' > "$ELSEWHERE/real-state/instincts.json"
  ln -s "$ELSEWHERE/real-state" "$HOME/state-link"
  GRID_STATE_DIR="$HOME/state-link/" uninstall --yes --purge
  [ "$status" -eq 0 ]
  [[ "$output" == *"a symlink: only the link goes"* ]]
  [ ! -L "$HOME/state-link" ]
  [ "$(cat "$ELSEWHERE/real-state/instincts.json")" = keep ]
  [ ! -e "$MOCK_GRID" ]
}

@test "guard: a relative GRID_DIR or GRID_STATE_DIR is refused (rc 2), nothing changed" {
  wire_machine; make_clone
  mkdir -p "$OTHER_DIR/rel-state"
  before="$(snap_all)"
  cd "$OTHER_DIR"
  GRID_DIR=../x run bash "$UNINSTALL" --yes --purge
  [ "$status" -eq 2 ]
  [[ "$output" == *"GRID_DIR must be an absolute path"* ]]
  GRID_DIR="$MOCK_GRID" GRID_STATE_DIR=rel-state run bash "$UNINSTALL" --yes --purge
  [ "$status" -eq 2 ]
  [[ "$output" == *"GRID_STATE_DIR must be an absolute path"* ]]
  [ -d "$OTHER_DIR/rel-state" ]
  [ "$before" = "$(snap_all)" ]
}

# ----------------------------------------------------------------- 5. ${GRID_DIR}-private

@test "a link into \${GRID_DIR}-private is never touched, with or without --yes" {
  wire_machine; add_foreign
  uninstall
  [[ "$output" != *"private-sibling"* ]]
  uninstall --yes
  [ "$status" -eq 0 ]
  [ "$(readlink "$SKILLS_DIR/private-sibling")" = "$PRIVATE_SIB/skills/priv" ]
  [ "$(readlink "$AGENTS_DIR/private-sibling")" = "$PRIVATE_SIB/skills/priv" ]
  [ -d "$PRIVATE_SIB/skills/priv" ]
}

@test "a link whose target merely contains .. out of the grid is not ours" {
  wire_machine
  ln -s "$MOCK_GRID/../uninstall-escape-$$" "$SKILLS_DIR/escaper"
  uninstall --yes
  [ -L "$SKILLS_DIR/escaper" ]
}

# ----------------------------------------------------------------- scheduled jobs, env

@test "scheduled jobs found are PRINTED with their deactivation commands, never touched" {
  wire_machine
  mkdir -p "$LAUNCH_AGENTS_DIR" "$SYSTEMD_USER_DIR"
  : > "$LAUNCH_AGENTS_DIR/io.the-grid.usage.plist"
  : > "$SYSTEMD_USER_DIR/grid-drift.timer"
  uninstall --yes
  [ "$status" -eq 0 ]
  [ -f "$LAUNCH_AGENTS_DIR/io.the-grid.usage.plist" ]
  [ -f "$SYSTEMD_USER_DIR/grid-drift.timer" ]
  [[ "$output" == *"NOT touched"* ]]
  [[ "$output" == *"launchctl bootout"*"io.the-grid.usage"* ]]
  [[ "$output" == *"systemctl --user disable --now grid-drift.timer"* ]]
}

@test "it refuses to run with HOME unset unless every target is given, and changes nothing" {
  wire_machine
  before="$(snap_all)"
  cd "$OTHER_DIR"
  run env -u HOME -u RULES_DIR GRID_DIR="$MOCK_GRID" SKILLS_DIR="$SKILLS_DIR" bash "$UNINSTALL" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME is unset"* ]]
  [ "$before" = "$(snap_all)" ]
}
