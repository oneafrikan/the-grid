#!/usr/bin/env bats
# Tests for compose.py role lint + --check. Needs the agent-factory venv
# (PyYAML); skipped where it isn't built. Bad roles are injected through
# GRID_PRIVATE_ROLES_DIR so the real roles/ tree is never touched.

load helpers/setup

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  [ -x "$PY" ] || skip "agent-factory venv not built"
  COMPOSE="$REPO_ROOT/agent-factory/compose.py"
  PRIV=$(mktemp -d)
  export GRID_PRIVATE_ROLES_DIR="$PRIV"
}

teardown() {
  rm -rf "$PRIV"
  unset GRID_PRIVATE_ROLES_DIR
  common_teardown
}

# make_role <name> — a minimal valid role in the private tree
make_role() {
  mkdir -p "$PRIV/$1"
  printf 'name: %s\ntitle: T\nsummary: S.\ndefault_model: sonnet\norchestrator: false\n' "$1" > "$PRIV/$1/role.yaml"
  printf '# soul\n' > "$PRIV/$1/SOUL.md"
  printf '# skill\n' > "$PRIV/$1/SKILL.md"
}

@test "lint-roles passes on the real roles plus a valid injected role" {
  make_role good
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "lint-roles: name that differs from the directory is E_NAME_MISMATCH" {
  make_role bad
  sed -i.bak 's/^name: bad/name: other/' "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_NAME_MISMATCH: bad/role.yaml"* ]]
}

@test "lint-roles: invalid model is E_MODEL_INVALID" {
  make_role bad
  sed -i.bak 's/sonnet/gpt9/' "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_MODEL_INVALID: bad/role.yaml"* ]]
}

@test "lint-roles: typo'd key is E_FIELD_UNKNOWN" {
  make_role bad
  echo 'sumary: oops' >> "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FIELD_UNKNOWN"* ]]
}

@test "lint-roles: missing and empty required files are named" {
  make_role bad
  rm "$PRIV/bad/SOUL.md"
  : > "$PRIV/bad/SKILL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FILE_MISSING: bad/SOUL.md"* ]]
  [[ "$output" == *"E_FILE_EMPTY: bad/SKILL.md"* ]]
}

@test "lint-roles: unresolved placeholder is E_TOKEN_UNRESOLVED" {
  make_role bad
  echo 'Hello {{NAME}}' >> "$PRIV/bad/SOUL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_TOKEN_UNRESOLVED: bad/SOUL.md"* ]]
}

@test "compose aborts naming the broken role when a config uses it" {
  make_role bad
  : > "$PRIV/bad/SKILL.md"
  printf 'project: t\nagents:\n  - role: bad\n' > "$OTHER_DIR/c.yaml"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"E_FILE_EMPTY"* ]]
  [ ! -e "$OTHER_DIR/out" ]    # fail-closed: nothing half-written
}

@test "compose --check fails on a stale file and does not repair it" {
  make_role r1
  printf 'project: t\nagents:\n  - role: r1\n' > "$OTHER_DIR/c.yaml"
  "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out" --check
  [ "$status" -eq 0 ]
  echo "tampered" >> "$OTHER_DIR/out/t/_claude-code/agents/t-r1.md"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
  grep -q tampered "$OTHER_DIR/out/t/_claude-code/agents/t-r1.md"   # still tampered
}

@test "lint-roles ignores an archive dir (_retired) so retired roles can't break the gate" {
  mkdir -p "$PRIV/_retired/old-role"          # deliberately malformed: empty dir
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}
