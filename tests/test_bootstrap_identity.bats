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
