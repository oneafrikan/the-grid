#!/usr/bin/env bats
# Tests for the runtime map: wire.sh's runtime check (scripts/lib/runtimes.txt)
# and the human-run wrapper scripts/runtime-setup.sh.
#
# Everything runs in a mock grid with a STUB setup script that logs its argv
# and imitates what upstream setup does to the skills dir / settings file. No
# real setup, bun, network, or ~/.claude is ever touched: SKILLS_DIR, AGENTS_DIR
# and CLAUDE_CONFIG_DIR all point into temp dirs.

load helpers/setup

setup() {
  common_setup
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  mkdir -p "$MOCK_GRID/scripts/lib" "$MOCK_GRID/repos/gstack"
  make_skill "$MOCK_GRID/repos/gstack/stubskill" "stubskill"
  printf 'gstack\n' > "$MOCK_GRID/baseline-submodules.txt"
  # The map: marker is bin/marker (created by the stub); `bash` is the "needs".
  printf '%s\n' '# repo | link | marker | needs | setup' \
    'gstack | gstack | bin/marker | bash | ./setup --host claude -q' \
    > "$MOCK_GRID/scripts/lib/runtimes.txt"
  # The stub: logs argv, creates the marker, then does what upstream setup does
  # to global state, driven by STUB_* env vars set per test.
  cat > "$MOCK_GRID/repos/gstack/setup" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_LOG"
mkdir -p bin && printf '#!/bin/sh\n' > bin/marker && chmod +x bin/marker
# Flat per-skill dir: converts a wired symlink into a real dir (upstream does).
[ -L "$SKILLS_DIR/stubskill" ] && rm "$SKILLS_DIR/stubskill"
mkdir -p "$SKILLS_DIR/stubskill"
# A SKILL.md that points OUTSIDE the submodule (1.91 render dirs do this).
[ -n "${STUB_REPLACE:-}" ] && ln -sf /nonexistent-elsewhere/SKILL.md "$SKILLS_DIR/stubskill/SKILL.md"
# Alias copies upstream creates that are not skill dir names.
mkdir -p "$SKILLS_DIR/_gstack-command"
[ -n "${STUB_TOUCH_SETTINGS:-}" ] && echo '{"hooks":1}' >> "$CLAUDE_CONFIG_DIR/settings.json"
[ -n "${STUB_DIRTY:-}" ] && echo dirty >> stubskill/SKILL.md
exit 0
STUB
  chmod +x "$MOCK_GRID/repos/gstack/setup"
}

teardown() {
  common_teardown
  unset CLAUDE_CONFIG_DIR STUB_LOG
}

wire()  { GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/wire.sh" "$@"; }
rsetup() { GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" bash "$REPO_ROOT/scripts/runtime-setup.sh" "$@"; }

# --- wire.sh runtime check -----------------------------------------------------

@test "wire.sh: marker missing warns, exits 0 and keeps the runtime link" {
  run wire
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime MISSING: gstack"* ]]
  [ -L "$MOCK_SKILLS/gstack" ]
  [ "$(readlink "$MOCK_SKILLS/gstack")" = "$MOCK_GRID/repos/gstack" ]
}

@test "wire.sh: marker present means no warning" {
  mkdir -p "$MOCK_GRID/repos/gstack/bin"
  printf '#!/bin/sh\n' > "$MOCK_GRID/repos/gstack/bin/marker"
  chmod +x "$MOCK_GRID/repos/gstack/bin/marker"
  run wire
  [ "$status" -eq 0 ]
  [[ "$output" != *"runtime MISSING"* ]]
  [ -L "$MOCK_SKILLS/gstack" ]
}

@test "wire.sh: a repo not in the baseline gets no link and no warning" {
  printf 'someotherrepo\n' > "$MOCK_GRID/baseline-submodules.txt"
  run wire
  [ "$status" -eq 0 ]
  [[ "$output" != *"runtime"* ]]
  [ ! -e "$MOCK_SKILLS/gstack" ]
}

@test "wire.sh: a second run is byte-identical and --check is clean" {
  local out1 out2 ls1 ls2
  out1="$(wire)"; ls1="$(ls -1 "$MOCK_SKILLS")"
  out2="$(wire)"; ls2="$(ls -1 "$MOCK_SKILLS")"
  [ "$out1" = "$out2" ]
  [ "$ls1" = "$ls2" ]
  [ "$(readlink "$MOCK_SKILLS/gstack")" = "$MOCK_GRID/repos/gstack" ]
  run wire --check
  [ "$status" -eq 0 ]
}

@test "wire.sh: a runtime-root path occupied by another symlink is skipped and left alone" {
  mkdir -p "$OTHER_DIR/standalone"
  ln -s "$OTHER_DIR/standalone" "$MOCK_SKILLS/gstack"
  run wire
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime root occupied"* ]]
  [ "$(readlink "$MOCK_SKILLS/gstack")" = "$OTHER_DIR/standalone" ]
}

# --- runtime-setup.sh ----------------------------------------------------------

@test "runtime-setup: runs the map's flags, removes the flat dir, re-wires, second run is a no-op" {
  run rsetup gstack
  [ "$status" -eq 0 ]
  # The stub received exactly the flags in the map.
  [ "$(cat "$STUB_LOG")" = "$(printf -- '--host\nclaude\n-q')" ]
  # The flat real dir is gone and wire.sh restored the symlink.
  [ -L "$MOCK_SKILLS/stubskill" ]
  [ "$(readlink "$MOCK_SKILLS/stubskill")" = "$MOCK_GRID/repos/gstack/stubskill" ]
  [ -L "$MOCK_SKILLS/gstack" ]
  [[ "$output" != *"runtime MISSING"* ]]
  local ls1; ls1="$(ls -1 "$MOCK_SKILLS")"
  # Second run: succeeds and leaves the same names behind.
  run rsetup gstack
  [ "$status" -eq 0 ]
  [ "$(ls -1 "$MOCK_SKILLS")" = "$ls1" ]
  [ -L "$MOCK_SKILLS/stubskill" ]
}

@test "runtime-setup: a changed settings file exits 3 and is not reverted" {
  printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  STUB_TOUCH_SETTINGS=1 run rsetup gstack
  [ "$status" -eq 3 ]
  [[ "$output" == *"SETTINGS CHANGED"* ]]
  # Never reverted: the stub's line is still there.
  grep -q '"hooks":1' "$CLAUDE_CONFIG_DIR/settings.json"
  # The cleanup still ran, so a retry starts clean.
  [ -L "$MOCK_SKILLS/stubskill" ]
}

@test "runtime-setup: an absent settings file that appears counts as a change" {
  [ ! -e "$CLAUDE_CONFIG_DIR/settings.json" ]
  STUB_TOUCH_SETTINGS=1 run rsetup gstack
  [ "$status" -eq 3 ]
}

@test "runtime-setup: a missing needs command exits 2 and never runs setup" {
  printf '%s\n' 'gstack | gstack | bin/marker | no-such-binary-xyz | ./setup -q' \
    > "$MOCK_GRID/scripts/lib/runtimes.txt"
  run rsetup gstack
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_LOG" ]
}

@test "runtime-setup: an unknown repo exits 2" {
  run rsetup nosuchrepo
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_LOG" ]
}

@test "runtime-setup: alias copies survive and are listed" {
  run rsetup gstack
  [ "$status" -eq 0 ]
  [ -d "$MOCK_SKILLS/_gstack-command" ]
  [[ "$output" == *"alias copies"*"_gstack-command"* ]]
}

@test "runtime-setup: a converted real dir whose SKILL.md links outside the repo is removed and re-wired" {
  wire >/dev/null
  [ -L "$MOCK_SKILLS/stubskill" ]
  STUB_REPLACE=1 run rsetup gstack
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/stubskill" ]
  [ "$(readlink "$MOCK_SKILLS/stubskill")" = "$MOCK_GRID/repos/gstack/stubskill" ]
}

@test "runtime-setup: a real dir that existed before the run is left untouched" {
  mkdir -p "$MOCK_SKILLS/stubskill"
  printf 'mine\n' > "$MOCK_SKILLS/stubskill/keep.txt"
  run rsetup gstack
  [ "$status" -eq 0 ]
  [ -d "$MOCK_SKILLS/stubskill" ] && [ ! -L "$MOCK_SKILLS/stubskill" ]
  [ "$(cat "$MOCK_SKILLS/stubskill/keep.txt")" = "mine" ]
}

@test "runtime-setup: an occupied runtime-root link exits 2 and the stub never runs" {
  mkdir -p "$OTHER_DIR/standalone"
  ln -s "$OTHER_DIR/standalone" "$MOCK_SKILLS/gstack"
  run rsetup gstack
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_LOG" ]
  [ "$(readlink "$MOCK_SKILLS/gstack")" = "$OTHER_DIR/standalone" ]
}

@test "runtime-setup: tracked-file dirt inside the submodule is warned about, exit stays 0" {
  git -C "$MOCK_GRID/repos/gstack" init -q
  git -C "$MOCK_GRID/repos/gstack" add -A
  git -C "$MOCK_GRID/repos/gstack" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
  STUB_DIRTY=1 run rsetup gstack
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: setup modified tracked files in the submodule"* ]]
  [[ "$output" == *"stubskill/SKILL.md"* ]]
}

@test "runtime-setup --dry-run prints the command, writes nothing, runs nothing" {
  run rsetup gstack --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"./setup --host claude -q"* ]]
  [ ! -e "$STUB_LOG" ]
  [ -z "$(ls -A "$MOCK_SKILLS")" ]
}

# --- real repo guard -----------------------------------------------------------

@test "real runtimes.txt: every gstack setup flag exists in repos/gstack/setup" {
  [ -f "$REPO_ROOT/repos/gstack/setup" ] || skip "repos/gstack/setup not present"
  local field tok failed=0
  # 5th pipe-separated field of the gstack row (skip comment lines).
  field="$(awk -F'|' '!/^[[:space:]]*#/ && $1 ~ /^[[:space:]]*gstack[[:space:]]*$/ { print $5 }' \
    "$REPO_ROOT/scripts/lib/runtimes.txt")"
  [ -n "$field" ]
  for tok in $field; do
    case "$tok" in
      --*|-q) ;;
      *) continue ;;
    esac
    if ! grep -qF -e "$tok" "$REPO_ROOT/repos/gstack/setup"; then
      echo "flag missing from repos/gstack/setup: $tok" >&3
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}
