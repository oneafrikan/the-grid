#!/usr/bin/env bats
# Golden-output conformance for compose.py (#23): scripts/compose-goldens.sh composes the
# fixture project under every target and byte-compares it with tests/fixtures/compose/golden/.
# Needs the agent-factory venv (PyYAML); skipped where it isn't built. Every test that
# mutates goldens works on a temp copy (GOLDEN_DIR), never the committed tree.

load helpers/setup

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  [ -x "$PY" ] || skip "agent-factory venv not built"
  GOLDENS="$REPO_ROOT/tests/fixtures/compose/golden"
  SCRIPT="$REPO_ROOT/scripts/compose-goldens.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
  common_teardown
}

# copy_goldens <dest> — a mutable copy of the committed golden trees
copy_goldens() {
  mkdir -p "$1"
  cp -R "$GOLDENS/." "$1/"
}

@test "--check passes on the committed goldens" {
  run bash "$SCRIPT" --check
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "--update is deterministic across hash seeds and matches the committed goldens" {
  # Two different PYTHONHASHSEEDs: two runs under one random seed could agree by luck.
  PYTHONHASHSEED=1 GOLDEN_DIR="$TMP/a" run bash "$SCRIPT" --update
  [ "$status" -eq 0 ]
  PYTHONHASHSEED=2 GOLDEN_DIR="$TMP/b" run bash "$SCRIPT" --update
  [ "$status" -eq 0 ]
  diff -r "$TMP/a" "$TMP/b"
  diff -r "$TMP/a" "$GOLDENS"
}

@test "a modified golden file fails --check and is named" {
  copy_goldens "$TMP/g"
  f=$(cd "$TMP/g" && find claude-code -type f | LC_ALL=C sort | head -1)
  [ -n "$f" ]
  echo "# drift" >> "$TMP/g/$f"
  GOLDEN_DIR="$TMP/g" run bash "$SCRIPT" --check
  echo "$output"
  [ "$status" -eq 1 ]
  # compose.py names the file relative to <target>/<project>/, so match the basename
  [[ "$output" == *"$(basename "$f")"* ]]
  [[ "$output" == *"fix: bash scripts/compose-goldens.sh --update"* ]]
}

@test "a deleted golden file fails --check and is named" {
  copy_goldens "$TMP/g"
  f=$(cd "$TMP/g" && find claude-code -type f | LC_ALL=C sort | head -1)
  [ -n "$f" ]
  rm "$TMP/g/$f"
  GOLDEN_DIR="$TMP/g" run bash "$SCRIPT" --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(basename "$f")"* ]]
}

@test "an extra file in the goldens fails --check and is named" {
  copy_goldens "$TMP/g"
  # Inside the emitter's own dir: compose.py --check only compares what the emitter owns.
  echo "stray" > "$TMP/g/claude-code/fx/_claude-code/stray-extra-file.txt"
  GOLDEN_DIR="$TMP/g" run bash "$SCRIPT" --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stray-extra-file.txt"* ]]
}

@test "goldens contain no host paths and carry the neutral machine name in every target" {
  # No hostname grep: short hostnames match ordinary prose. Instead `your-machine` must appear
  # in each target tree, which proves the hostname fallback did not run.
  run grep -rIl -e /Users/ -e /home/ -e "$REPO_ROOT" -e "$HOME" "$GOLDENS"
  echo "$output"
  [ "$status" -eq 1 ]
  for t in claude-code openclaw paperclip openclaw-native; do
    run grep -rl your-machine "$GOLDENS/$t"
    echo "$t: $output"
    [ "$status" -eq 0 ]
  done
}

@test "ambient env cannot change the --check result" {
  # A decoy private roles tree under a fake HOME, plus bogus overrides of the three pinned vars.
  decoy="$TMP/home"
  mkdir -p "$decoy/.the-grid-private/roles/ceo-orchestrator"
  echo "name: ceo-orchestrator" > "$decoy/.the-grid-private/roles/ceo-orchestrator/role.yaml"
  HOME="$decoy" \
  GRID_PRIVATE_ROLES_DIR="$decoy/.the-grid-private/roles" \
  GRID_USER_CONFIG=/nonexistent \
  GRID_MODELS_FILE=/nonexistent \
    run bash "$SCRIPT" --check
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "GRID_USER_CONFIG overrides the identity in a direct compose" {
  printf 'operator: ""\nmachine: "sentinel-xyz"\nchannels: ""\n' > "$TMP/id.yaml"
  GRID_PRIVATE_ROLES_DIR="$REPO_ROOT/tests/fixtures/compose/roles" \
  GRID_USER_CONFIG="$TMP/id.yaml" \
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
      --target claude-code --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -rq sentinel-xyz "$TMP/out"
  run grep -rq your-machine "$TMP/out"
  [ "$status" -ne 0 ]
}

@test "a missing GRID_USER_CONFIG is a hard error, not a fallback" {
  GRID_PRIVATE_ROLES_DIR="$REPO_ROOT/tests/fixtures/compose/roles" \
  GRID_USER_CONFIG=/nonexistent \
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
      --target claude-code --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GRID_USER_CONFIG not found"* ]]
}
