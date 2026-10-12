#!/usr/bin/env bats
# Portable personas (#36): scripts/build-personas.sh renders dist/personas/<role>.md from every
# public compose config. Needs the agent-factory venv (PyYAML); skipped where it isn't built.
# Every test that builds or mutates works on a temp COPY of the repo, never the committed tree.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
  common_teardown
}

# repo_copy <dest> — the minimum a build needs: the script, agent-factory (without its venv
# and composed output) and the committed personas. The venv is symlinked, not copied.
repo_copy() {
  mkdir -p "$1/scripts"
  cp "$REPO_ROOT/scripts/build-personas.sh" "$1/scripts/"
  cp -R "$REPO_ROOT/agent-factory" "$1/agent-factory"
  rm -rf "$1/agent-factory/.venv" "$1/agent-factory/projects"
  ln -s "$REPO_ROOT/agent-factory/.venv" "$1/agent-factory/.venv"
  mkdir -p "$1/dist"
  cp -R "$REPO_ROOT/dist/personas" "$1/dist/personas"
}

@test "committed personas are current" {
  run bash "$REPO_ROOT/scripts/build-personas.sh" --check
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "no persona starts with YAML frontmatter, and each starts with a title" {
  n=0
  for f in "$REPO_ROOT"/dist/personas/*.md; do
    first="$(head -n 1 "$f")"
    [[ "$first" != "---"* ]] || { echo "frontmatter in $f"; false; }
    [[ "$first" == "# "* ]] || { echo "no title in $f"; false; }
    n=$((n + 1))
  done
  # orchestrators are included, so the set is larger than the specialist count alone
  [ "$n" -gt 30 ]
  [ -f "$REPO_ROOT/dist/personas/tech-lead.md" ]
}

@test "a second build is byte-identical" {
  repo_copy "$TMP/r"
  run bash "$TMP/r/scripts/build-personas.sh"
  [ "$status" -eq 0 ]
  cp -R "$TMP/r/dist/personas" "$TMP/first"
  run bash "$TMP/r/scripts/build-personas.sh"
  [ "$status" -eq 0 ]
  diff -r "$TMP/first" "$TMP/r/dist/personas"
}

@test "editing a role's SKILL.md makes --check exit 1" {
  repo_copy "$TMP/r"
  echo "An extra line that the committed persona does not have." >> "$TMP/r/agent-factory/roles/backend-dev/SKILL.md"
  run bash "$TMP/r/scripts/build-personas.sh" --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE"* ]] || false
}

@test "a private role never reaches the export" {
  repo_copy "$TMP/r"
  # A complete private role, as a real private desk would have one.
  mkdir -p "$TMP/private/zz-private"
  cp "$REPO_ROOT"/tests/fixtures/compose/roles/fx-eng/* "$TMP/private/zz-private/"
  # A private role of the same name as a public one WINS if the private dir is honoured, so
  # this also proves the pin is real (zz-private alone is in no config and would pass anyway).
  mkdir -p "$TMP/private/backend-dev"
  cp "$REPO_ROOT"/tests/fixtures/compose/roles/fx-eng/* "$TMP/private/backend-dev/"
  GRID_PRIVATE_ROLES_DIR="$TMP/private" run bash "$TMP/r/scripts/build-personas.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/r/dist/personas/zz-private.md" ]
  cmp "$TMP/r/dist/personas/backend-dev.md" "$REPO_ROOT/dist/personas/backend-dev.md"
}

@test "no persona names the private learning store path" {
  # The role sources keep the real path (agents need it); the portable export must not.
  run grep -rn 'the-grid-private' "$REPO_ROOT/dist/personas"
  [ "$status" -eq 1 ]
  grep -rqF '<private-dir>/' "$REPO_ROOT/dist/personas"
}

@test "build-personas.sh pins GRID_USER_CONFIG to the public config, and a poisoned value changes nothing" {
  # the pin exists in the script ...
  grep -q '^export GRID_USER_CONFIG=agent-factory/user.public.yaml$' "$REPO_ROOT/scripts/build-personas.sh"
  # ... and an operator-specific config in the environment cannot reach the output
  repo_copy "$TMP/r"
  printf 'operator: SENTINEL-OPERATOR-NAME\nmachine: sentinel-machine\nchannels: sentinel-channel\n' > "$TMP/poison.yaml"
  GRID_USER_CONFIG="$TMP/poison.yaml" run bash "$TMP/r/scripts/build-personas.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  diff -r "$REPO_ROOT/dist/personas" "$TMP/r/dist/personas"
  run grep -rl "SENTINEL-OPERATOR-NAME\|sentinel-machine" "$TMP/r/dist/personas"
  [ -z "$output" ]
}
