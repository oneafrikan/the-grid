#!/usr/bin/env bats
# bootstrap.sh warns (never fails on its own) when the global git email is not a noreply address.
# HOME is a temp dir and GRID_DIR an empty temp repo, so nothing real is read or written. The run
# stops later (no example baseline in the temp repo); only the WARN output is asserted.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/grid"
  unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME
  export GIT_CONFIG_NOSYSTEM=1
  git -C "$BATS_TEST_TMPDIR/grid" init -q
  export GRID_DIR="$BATS_TEST_TMPDIR/grid"
  BOOTSTRAP="$BATS_TEST_DIRNAME/../scripts/bootstrap.sh"
}

@test "bootstrap: warns and prints the fix command when global email is unset" {
  run bash "$BOOTSTRAP"
  [[ "$output" == *"WARN: global git user.email is unset"* ]]
  [[ "$output" == *'git config --global user.email "<id>+<login>@users.noreply.github.com"'* ]]
}

@test "bootstrap: warns when global email is a personal address" {
  git config --global user.email "me@example.com"
  run bash "$BOOTSTRAP"
  [[ "$output" == *"WARN: global git user.email is me@example.com"* ]]
}

@test "bootstrap: no warning when global email is a noreply address" {
  git config --global user.email "1+x@users.noreply.github.com"
  run bash "$BOOTSTRAP"
  [[ "$output" != *"WARN:"* ]]
}

# Reminder for a missing agent-factory/user.yaml. A stub grid lets --with-agents run end to end:
# fake wire.sh, a no-op fake venv python, and the example seed files bootstrap copies.
stub_grid() {
  local g="$BATS_TEST_TMPDIR/grid"
  mkdir -p "$g/scripts" "$g/machines" "$g/agent-factory/.venv/bin"
  : > "$g/baseline-submodules.example.txt"; : > "$g/machines/example.txt"
  printf '#!/bin/sh\n' > "$g/scripts/wire.sh"
  printf '#!/bin/sh\nexit 0\n' > "$g/agent-factory/.venv/bin/python"
  chmod +x "$g/agent-factory/.venv/bin/python"
}

@test "bootstrap: --with-agents reminds about user.yaml when it is missing" {
  stub_grid
  git config --global user.email "1+x@users.noreply.github.com"
  run bash "$BOOTSTRAP" --with-agents
  [ "$status" -eq 0 ]
  [[ "$output" == *"cp \"$GRID_DIR/agent-factory/user.yaml.example\" \"$GRID_DIR/agent-factory/user.yaml\""* ]]
  [[ "$output" == *"bash \"$GRID_DIR/scripts/bootstrap.sh\" --with-agents"* ]]
}

@test "bootstrap: no user.yaml reminder when it exists or without --with-agents" {
  stub_grid
  git config --global user.email "1+x@users.noreply.github.com"
  run bash "$BOOTSTRAP"
  [[ "$output" != *"user.yaml"* ]]
  : > "$GRID_DIR/agent-factory/user.yaml"
  run bash "$BOOTSTRAP" --with-agents
  [ "$status" -eq 0 ]
  [[ "$output" != *"user.yaml"* ]]
}
