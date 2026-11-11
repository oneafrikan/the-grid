#!/usr/bin/env bats
# scripts/bootstrap-user.sh: exercised with stubs only. HOME, TMPDIR and PATH are all inside
# $BATS_TEST_TMPDIR, so no real install, network call or rc edit can happen. Every tool the
# script probes is faked as "already installed", which makes a REAL (non --dry-run) run safe.

bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  S="$BATS_TEST_DIRNAME/../scripts/bootstrap-user.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME/.local/bin" "$HOME/.claude" "$HOME/.venvs/ds/bin" "$TMPDIR" "$BIN" \
    "$HOME/.nvm/versions/node/v22.3.0"
  unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME; export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  # Stub every probed command; dpkg reports every package installed.
  for c in uv claude herdr gh openspec; do printf '#!/bin/sh\necho %s 1.0\n' "$c" > "$HOME/.local/bin/$c"; done
  printf '#!/bin/sh\necho v22.3.0\n' > "$BIN/node"
  printf '#!/bin/sh\necho "Status: install ok installed"\n' > "$BIN/dpkg"
  chmod +x "$HOME/.local/bin/"* "$BIN/"*
  printf '#!/bin/sh\n' > "$HOME/.venvs/ds/bin/python"; chmod +x "$HOME/.venvs/ds/bin/python"
  printf 'nvm() { :; }\n' > "$HOME/.nvm/nvm.sh"
  echo '@~/.claude-rules/rules.md' > "$HOME/.claude/CLAUDE.md"
  # Local origin + clone for each repo the script clones/pulls, so fetch/pull --ff-only work offline.
  for r in claude-rules the-grid; do
    git init -q --bare "$BATS_TEST_TMPDIR/$r.git"
    git clone -q "$BATS_TEST_TMPDIR/$r.git" "$HOME/.$r" 2>/dev/null
  done
  mkdir -p "$HOME/.the-grid/scripts"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.the-grid/scripts/bootstrap.sh"
  git -C "$HOME/.the-grid" add -A; git -C "$HOME/.the-grid" commit -q -m stub
  git -C "$HOME/.the-grid" push -q origin HEAD 2>/dev/null
  git -C "$HOME/.claude-rules" commit -q --allow-empty -m stub
  git -C "$HOME/.claude-rules" push -q origin HEAD 2>/dev/null
  for r in claude-rules the-grid; do git -C "$HOME/.$r" branch -q --set-upstream-to=origin/HEAD 2>/dev/null || true; done
  RUN_PATH="$HOME/.local/bin:$BIN:/usr/bin:/bin"
}

# Regression: the EXIT trap used to reference a main()-local TMP -> "TMP: unbound variable"
# on stderr after an otherwise successful run.
@test "bootstrap-user: a real run exits 0 with no stderr and removes its temp dir" {
  run --separate-stderr env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH="$RUN_PATH" bash "$S"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -z "$(ls -A "$TMPDIR")" ]
  grep -qF '# >>> the-grid bootstrap-user >>>' "$HOME/.bashrc"
}

@test "bootstrap-user: a second real run is a clean no-op" {
  env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH="$RUN_PATH" bash "$S" >/dev/null
  before="$(md5sum "$HOME/.bashrc")"
  run --separate-stderr env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH="$RUN_PATH" bash "$S"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(md5sum "$HOME/.bashrc")" = "$before" ]
}

@test "bootstrap-user: --dry-run creates nothing" {
  empty="$BATS_TEST_TMPDIR/empty"; mkdir -p "$empty"
  run env -i HOME="$empty" PATH="$RUN_PATH" bash "$S" --dry-run
  [ -z "$(ls -A "$empty")" ]
}

@test "bootstrap-user: refuses an unknown argument" {
  run env -i HOME="$HOME" PATH="$RUN_PATH" bash "$S" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}
