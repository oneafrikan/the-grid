#!/usr/bin/env bats
# Tests for `grid doctor`, `grid repair` and `grid uninstall`, group 4 of change
# `manifest-lock-install`.
#
# Built like test_grid_install.bats: everything inside the test from throwaway
# repos (helpers/grid_fixture.bash), fetched over file:// from a local upstream, so
# no test touches the network, the real ~/.grid or the real ~/.claude. The install
# grid is reached through a SYMLINKED path ($G -> real dir $GREAL) throughout, so
# the realpath handling in doctor/repair/uninstall is exercised by the whole file.
# These tests verify my own implementation (a self-check); independent
# verification is for qa-engineer / sdet.

load helpers/setup
load helpers/grid_fixture

setup() {
  common_setup
  T=$(mktemp -d)
  grid_env_isolate "$T/env"
  export GRID_HOST=testhost
  export GRID_TRACE_FETCH="$T/trace"
  U="$T/upstream"
  M="$T/maint"
  GREAL="$T/real/grid"
  G="$T/grid-link"
  make_upstream "$U"
}

teardown() {
  rm -rf "$T"
  common_teardown
}

# build_grids: maintainer copy writes grid.lock; the install grid gets that lock and
# an empty repos/up (still a gitlink). Same recipe as test_grid_install.bats.
build_grids() {
  make_grid_fixture "$M" "$U"
  python3 -B "$M/scripts/grid" --grid-dir "$M" lock >/dev/null
  mkdir -p "$T/real"
  make_grid_fixture "$GREAL" "$U"
  cp "$REPO_ROOT/scripts/catalog.sh" "$GREAL/scripts/catalog.sh"
  rm -rf "$GREAL/repos/up"
  mkdir "$GREAL/repos/up"
  ln -s "$GREAL" "$G"
  cp "$M/grid.lock" "$GREAL/grid.lock"
  git -C "$GREAL" add -A
  git -C "$GREAL" commit -q -m fixture
}

# installed: build the grids and run a completed install (the starting point of most tests).
installed() {
  build_grids
  run grid install
  [ "$status" -eq 0 ]
}

# grid ARGS...: run the install grid's own scripts/grid through the symlinked path.
grid() { python3 -B "$G/scripts/grid" --grid-dir "$G" "$@"; }

# bump_lock: a second upstream commit changing alpha, and a re-locked grid.lock for it.
bump_lock() {
  printf 'Second version.\n' >> "$U/skills/alpha/SKILL.md"
  git -C "$U" add -A
  git -C "$U" commit -q -m "alpha v2"
  fixture_advance "$M" "$U"
  python3 -B "$M/scripts/grid" --grid-dir "$M" lock >/dev/null
  cp "$M/grid.lock" "$GREAL/grid.lock"
}

# lines FILE: number of lines (0 when the file does not exist).
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

LEDGER() { echo "$GRID_STATE_DIR/installed.manifest"; }

# snapshot: one digest of everything uninstall/doctor/repair --dry-run must leave alone.
snapshot() { tree_digest "$GREAL"; echo "--"; tree_digest "$SKILLS_DIR"; echo "--"; tree_digest "$GRID_STATE_DIR"; }

# --- doctor ---------------------------------------------------------------------------------

@test "doctor on a clean install exits 0 and prints nothing" {
  installed
  run grid doctor
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an edited placed file is reported as: disk skill alpha modified" {
  installed
  printf 'edit\n' >> "$G/repos/up/skills/alpha/SKILL.md"
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"disk skill alpha modified"* ]]
  [[ "$output" != *"beta"* ]]
}

@test "a .DS_Store added to a placed skill leaves doctor clean" {
  installed
  printf 'junk' > "$G/repos/up/skills/alpha/.DS_Store"
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "a deleted skill dir is reported absent; repair restores it; doctor is then clean" {
  installed
  rm -rf "$G/repos/up/skills/alpha"
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"disk skill alpha absent"* ]]
  run grid repair
  [ "$status" -eq 0 ]
  [ -f "$G/repos/up/skills/alpha/SKILL.md" ]
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "a lock bumped to a second upstream commit is reported stale; repair fixes it" {
  installed
  bump_lock
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"ledger skill alpha stale"* ]]
  run grid repair
  [ "$status" -eq 0 ]
  grep -q "Second version." "$G/repos/up/skills/alpha/SKILL.md"
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "a skill missing from the ledger is reported missing and repair re-adopts it without a fetch" {
  installed
  # Drop beta's ledger row only; its directory is still on disk at the locked content.
  grep -v "beta" "$(LEDGER)" > "$T/ledger.new"
  cp "$T/ledger.new" "$(LEDGER)"
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"ledger skill beta missing"* ]]
  trace_before=$(lines "$GRID_TRACE_FETCH")
  run grid repair
  [ "$status" -eq 0 ]
  [ "$(lines "$GRID_TRACE_FETCH")" -eq "$trace_before" ]
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "a ledger row that the lock no longer selects is reported extra" {
  installed
  mkdir -p "$GREAL/machines"
  printf -- '-up/beta\n' > "$GREAL/machines/testhost.txt"
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"ledger skill beta extra"* ]]
}

@test "a removed link is reported by the links check and repair re-links it" {
  installed
  rm "$SKILLS_DIR/alpha"
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"links link alpha missing"* ]]
  run grid repair
  [ "$status" -eq 0 ]
  [ -L "$SKILLS_DIR/alpha" ]
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "a grid.yaml that does not parse is a manifest finding, not a crash" {
  installed
  printf 'version: 2\n' > "$GREAL/grid.yaml"
  run grid doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest parse grid.yaml"* ]]
}

@test "doctor with no ledger prints maintainer mode and runs only the manifest and link checks" {
  build_grids
  run grid doctor
  [[ "$output" == *"no install ledger: maintainer mode"* ]]
  [[ "$output" != *"ledger skill"* ]]
  [[ "$output" != *"disk skill"* ]]
}

@test "doctor --json output parses with python3 -m json.tool, clean and with findings" {
  installed
  run grid doctor --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  printf 'edit\n' >> "$G/repos/up/skills/alpha/SKILL.md"
  run grid doctor --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  [[ "$output" == *'"check": "disk"'* ]]
  [[ "$output" == *'"name": "alpha"'* ]]
  [[ "$output" == *'"detail": "modified repos/up/skills/alpha"'* ]]
}

@test "doctor writes nothing: the grid, skills dir and state dir are byte-identical" {
  installed
  printf 'edit\n' >> "$G/repos/up/skills/alpha/SKILL.md"
  rm "$SKILLS_DIR/beta"
  before=$(snapshot)
  run grid doctor
  [ "$status" -eq 1 ]
  [ "$(snapshot)" = "$before" ]
}

# --- repair ---------------------------------------------------------------------------------

@test "repair on a healthy install is a no-op: no fetch, ledger byte-identical" {
  installed
  ledger_before=$(file_id "$(LEDGER)")
  trace_before=$(lines "$GRID_TRACE_FETCH")
  run grid repair
  [ "$status" -eq 0 ]
  [ "$(lines "$GRID_TRACE_FETCH")" -eq "$trace_before" ]
  [ "$(file_id "$(LEDGER)")" = "$ledger_before" ]
}

@test "an edited file: repair without --force exits 1 and keeps the edit; --force restores it" {
  installed
  printf 'my edit\n' >> "$G/repos/up/skills/alpha/SKILL.md"
  run grid repair
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha"* ]]
  grep -q "my edit" "$G/repos/up/skills/alpha/SKILL.md"
  run grid repair --force
  [ "$status" -eq 0 ]
  ! grep -q "my edit" "$G/repos/up/skills/alpha/SKILL.md"
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "repair --dry-run prints the plan and changes nothing, with no fetch" {
  installed
  rm -rf "$G/repos/up/skills/alpha"
  trace_before=$(lines "$GRID_TRACE_FETCH")
  before=$(snapshot)
  run grid repair --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would fetch alpha"* ]]
  [ "$(lines "$GRID_TRACE_FETCH")" -eq "$trace_before" ]
  [ "$(snapshot)" = "$before" ]
}

@test "repair keeps an extra dir unless --prune is given" {
  installed
  mkdir -p "$GREAL/machines"
  printf -- '-up/beta\n' > "$GREAL/machines/testhost.txt"
  run grid repair
  [ "$status" -eq 0 ]
  [ -f "$G/repos/up/nested/cat/beta/SKILL.md" ]
  grep -q "beta" "$(LEDGER)"
  run grid repair --prune
  [ "$status" -eq 0 ]
  [ ! -e "$G/repos/up/nested" ]
  ! grep -q "beta" "$(LEDGER)"
  grep -q "alpha" "$(LEDGER)"
}

@test "repair with no ledger says maintainer mode and changes nothing" {
  build_grids
  before=$(tree_digest "$GREAL")
  run grid repair
  [ "$status" -eq 0 ]
  [[ "$output" == *"no install ledger: maintainer mode"* ]]
  [ "$(tree_digest "$GREAL")" = "$before" ]
  [ ! -e "$GRID_TRACE_FETCH" ]
}

# --- uninstall ------------------------------------------------------------------------------

@test "uninstall without --yes prints the plan and changes nothing" {
  installed
  before=$(snapshot)
  run grid uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove dir repos/up/skills/alpha"* ]]
  [[ "$output" == *"would remove link "* ]]
  [[ "$output" == *"would remove ledger"* ]]
  [ "$(snapshot)" = "$before" ]
  [ -d "$G/repos/up/skills/alpha" ]
  [ -L "$SKILLS_DIR/alpha" ]
  [ -f "$(LEDGER)" ]
}

@test "uninstall --yes removes only owned dirs and links; foreign link, real dir and repos/up stay" {
  installed
  mkdir -p "$T/elsewhere" "$SKILLS_DIR/realdir"
  printf 'keep' > "$SKILLS_DIR/realdir/file"
  ln -s "$T/elsewhere" "$SKILLS_DIR/foreign"
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -e "$G/repos/up/skills" ]
  [ ! -e "$G/repos/up/nested" ]
  [ ! -L "$SKILLS_DIR/alpha" ]
  [ ! -L "$SKILLS_DIR/beta" ]
  [ ! -e "$(LEDGER)" ]
  # What is not ours is untouched.
  [ -d "$G/repos/up" ]
  [ -L "$SKILLS_DIR/foreign" ]
  [ "$(readlink "$SKILLS_DIR/foreign")" = "$T/elsewhere" ]
  [ -f "$SKILLS_DIR/realdir/file" ]
  [ -f "$GREAL/baseline-submodules.txt" ]
  [ -d "$T/elsewhere" ]
}

@test "a second uninstall exits 0 with 'nothing to remove' and changes nothing" {
  installed
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  before=$(snapshot)
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
  [ "$(snapshot)" = "$before" ]
}

@test "a modified skill is skipped and listed; --force removes it" {
  installed
  printf 'my edit\n' >> "$G/repos/up/skills/alpha/SKILL.md"
  run grid uninstall --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"skip repos/up/skills/alpha"* ]]
  [ -f "$G/repos/up/skills/alpha/SKILL.md" ]
  [ ! -e "$G/repos/up/nested/cat/beta" ]
  # Its link stays with it; the ledger keeps only its row.
  [ -L "$SKILLS_DIR/alpha" ]
  [ "$(lines "$(LEDGER)")" -eq 1 ]
  grep -q "alpha" "$(LEDGER)"
  run grid uninstall --yes --force
  [ "$status" -eq 0 ]
  [ ! -e "$G/repos/up/skills" ]
  [ ! -L "$SKILLS_DIR/alpha" ]
  [ ! -e "$(LEDGER)" ]
}

@test "uninstall finds a link that names the grid through the symlinked path" {
  installed
  # A link spelled with the SYMLINKED grid path: a string compare against the
  # ledger's realpath would miss it; the realpath compare must not.
  rm "$SKILLS_DIR/alpha"
  ln -s "$G/repos/up/skills/alpha" "$SKILLS_DIR/alpha"
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -L "$SKILLS_DIR/alpha" ]
  [ ! -e "$G/repos/up/skills/alpha" ]
}

@test "uninstall works with the grid dir given as its real path too" {
  installed
  run python3 -B "$GREAL/scripts/grid" --grid-dir "$GREAL" uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -L "$SKILLS_DIR/alpha" ]
  [ ! -e "$GREAL/repos/up/skills" ]
}

@test "uninstall refuses a dir under a source that is a submodule checkout (.git present)" {
  installed
  mkdir "$G/repos/up/.git"
  run grid uninstall --yes --force
  [ "$status" -eq 1 ]
  [ -f "$G/repos/up/skills/alpha/SKILL.md" ]
  [ -f "$G/repos/up/nested/cat/beta/SKILL.md" ]
  [ -d "$G/repos/up/.git" ]
  [ -L "$SKILLS_DIR/alpha" ]
  [ -f "$(LEDGER)" ]
}

@test "uninstall refuses a skill dir that has become a symlink and never follows it" {
  installed
  mkdir -p "$T/outside"
  printf 'precious' > "$T/outside/SKILL.md"
  rm -rf "$G/repos/up/skills/alpha"
  ln -s "$T/outside" "$G/repos/up/skills/alpha"
  run grid uninstall --yes --force
  [ "$status" -eq 1 ]
  [ -L "$G/repos/up/skills/alpha" ]
  [ "$(cat "$T/outside/SKILL.md")" = "precious" ]
}

@test "uninstall refuses a symlinked repos/<source> so a delete cannot land outside the grid" {
  installed
  mkdir -p "$T/outside"
  mv "$G/repos/up" "$T/outside/up"
  ln -s "$T/outside/up" "$GREAL/repos/up"
  run grid uninstall --yes --force
  [ "$status" -eq 1 ]
  [ -f "$T/outside/up/skills/alpha/SKILL.md" ]
  [ -f "$T/outside/up/nested/cat/beta/SKILL.md" ]
}

@test "a ledger row whose path climbs out of repos/<source> is a hard error and nothing is deleted" {
  installed
  mkdir -p "$T/victim"
  printf 'precious' > "$T/victim/file"
  printf 'skill\tevil\tup\t%s\t../../../victim\trepos/up/../../../victim\tsha256:%s\n' \
    "$(git -C "$U" rev-parse HEAD)" "$(printf '0%.0s' $(seq 1 64))" >> "$(LEDGER)"
  run grid uninstall --yes --force
  [ "$status" -eq 2 ]
  [ "$(cat "$T/victim/file")" = "precious" ]
  [ -f "$G/repos/up/skills/alpha/SKILL.md" ]
}

@test "uninstall keeps rows of an unknown kind in the ledger" {
  installed
  printf 'rule\tsql\tup\t%s\trules/sql\trepos/up/rules/sql\tsha256:%s\n' \
    "$(git -C "$U" rev-parse HEAD)" "$(printf '0%.0s' $(seq 1 64))" >> "$(LEDGER)"
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -e "$G/repos/up/skills" ]
  [ "$(lines "$(LEDGER)")" -eq 1 ]
  grep -q "^rule	sql	up" "$(LEDGER)"
  # With only the foreign row left, a repeat run has nothing to do.
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

@test "uninstall with no ledger and no links says nothing to remove" {
  build_grids
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

@test "after uninstall --yes the grid can be installed again" {
  installed
  run grid uninstall --yes
  [ "$status" -eq 0 ]
  run grid install
  [ "$status" -eq 0 ]
  [ -f "$G/repos/up/skills/alpha/SKILL.md" ]
  run grid doctor
  [ "$status" -eq 0 ]
}

@test "grid --help lists doctor, repair and uninstall" {
  run python3 -B "$REPO_ROOT/scripts/grid" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"repair"* ]]
  [[ "$output" == *"uninstall"* ]]
}
