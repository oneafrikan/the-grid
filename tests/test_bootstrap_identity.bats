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

# --- bootstrap.sh --reshallow (opt-in conversion of full submodule checkouts to depth 1) ---
# Fixture: upstream U (3 commits, then a 4th so the pin is BEHIND its tip like most real pins),
# superproject S pinning U's 3rd commit as submodule "sub", and clone C with a FULL checkout of
# it. file:// URLs because git ignores depth for plain paths; protocol.file.allow because git
# blocks file transport inside submodules by default. All of it lives under BATS_TEST_TMPDIR.
mk_reshallow_fixture() {
  git config --global user.email "1+x@users.noreply.github.com"
  git config --global user.name t
  git config --global init.defaultBranch main
  git config --global protocol.file.allow always
  local t="$BATS_TEST_TMPDIR" i
  git init -q "$t/u"
  for i in 1 2 3; do git -C "$t/u" commit -q --allow-empty -m "u$i"; done
  git init -q "$t/s"
  git -C "$t/s" submodule add -q "file://$t/u" sub
  git -C "$t/s" commit -q -m "add sub"
  git -C "$t/u" commit -q --allow-empty -m "u4"
  git clone -q "file://$t/s" "$t/c"
  git -C "$t/c" submodule update --init -q
  export GRID_DIR="$t/c"
  [ "$(git -C "$t/c/sub" rev-list --count HEAD)" = 3 ]
}

@test "reshallow: converts a full submodule to depth 1 at its pin, then a second run is a no-op" {
  mk_reshallow_fixture
  pin="$(git -C "$GRID_DIR" ls-files -s sub | awk '{print $2}')"
  run bash "$BOOTSTRAP" --reshallow
  [ "$status" -eq 0 ]
  [[ "$output" == *"reshallow: sub: shallow at"* ]]
  [[ "$output" == *"1 converted, 0 skipped, 0 failed"* ]]
  [ "$(git -C "$GRID_DIR/sub" rev-list --count HEAD)" = 1 ]
  [ "$(git -C "$GRID_DIR/sub" rev-parse --is-shallow-repository)" = true ]
  [ "$(git -C "$GRID_DIR/sub" rev-parse HEAD)" = "$pin" ]
  # No backup left behind, and git still sees a clean submodule at the pin.
  [ -z "$(find "$BATS_TEST_TMPDIR/c" -name '*.reshallow-bak' | head -n 1)" ]
  [ -z "$(git -C "$GRID_DIR" status --porcelain)" ]
  run bash "$BOOTSTRAP" --reshallow
  [ "$status" -eq 0 ]
  [[ "$output" == *"sub: skipped (already shallow)"* ]]
  [[ "$output" == *"0 converted, 1 skipped, 0 failed"* ]]
}

@test "reshallow: skips a dirty submodule and leaves its history alone" {
  mk_reshallow_fixture
  echo wip > "$GRID_DIR/sub/scratch.txt"
  run bash "$BOOTSTRAP" --reshallow
  [ "$status" -eq 0 ]
  [[ "$output" == *"sub: skipped (dirty working tree)"* ]]
  [ "$(git -C "$GRID_DIR/sub" rev-list --count HEAD)" = 3 ]
  [ -f "$GRID_DIR/sub/scratch.txt" ]
}

@test "reshallow: skips a submodule whose HEAD moved off the recorded pin" {
  mk_reshallow_fixture
  git -C "$GRID_DIR/sub" commit -q --allow-empty -m "local work"
  run bash "$BOOTSTRAP" --reshallow
  [ "$status" -eq 0 ]
  [[ "$output" == *"sub: skipped (HEAD "*"is not the recorded pin"* ]]
  [ "$(git -C "$GRID_DIR/sub" rev-list --count HEAD)" = 4 ]
}

@test "reshallow: a failed re-clone restores the original submodule untouched" {
  mk_reshallow_fixture
  # Break the remote the way a dropped network would: the fresh clone cannot succeed.
  git -C "$GRID_DIR" config submodule.sub.url "file://$BATS_TEST_TMPDIR/does-not-exist"
  run bash "$BOOTSTRAP" --reshallow
  [ "$status" -eq 1 ]
  [[ "$output" == *"sub: FAILED, original restored"* ]]
  [ "$(git -C "$GRID_DIR/sub" rev-list --count HEAD)" = 3 ]
  [ "$(git -C "$GRID_DIR/sub" rev-parse --is-shallow-repository)" = false ]
  [ -z "$(git -C "$GRID_DIR/sub" status --porcelain)" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/c" -name '*.reshallow-bak' | head -n 1)" ]
}

# Step 1 of a normal run: new submodules arrive at depth 1, existing full ones are never truncated.
# The fixture has no wire.sh/example baseline, so the run fails after step 1; only step 1 is asserted.
@test "bootstrap step 1: a not-yet-cloned submodule is fetched at depth 1 even when its pin is behind the tip" {
  mk_reshallow_fixture
  git -C "$GRID_DIR" submodule deinit -q -f sub
  rm -rf "$GRID_DIR/.git/modules/sub"
  run bash "$BOOTSTRAP"
  [ "$(git -C "$GRID_DIR/sub" rev-parse --is-shallow-repository)" = true ]
  [ "$(git -C "$GRID_DIR/sub" rev-list --count HEAD)" = 1 ]
}

@test "bootstrap step 1: an existing full submodule keeps its history" {
  mk_reshallow_fixture
  run bash "$BOOTSTRAP"
  [ "$(git -C "$GRID_DIR/sub" rev-parse --is-shallow-repository)" = false ]
  [ "$(git -C "$GRID_DIR/sub" rev-list --count HEAD)" = 3 ]
}
