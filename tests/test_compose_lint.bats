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
  unset GRID_PRIVATE_ROLES_DIR GRID_AUTHORED_ROLES_FILE
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
  [[ "$output" == *"E_NAME_MISMATCH: bad/role.yaml"* ]] || false
}

@test "lint-roles: invalid model is E_MODEL_INVALID" {
  make_role bad
  sed -i.bak 's/sonnet/gpt9/' "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_MODEL_INVALID: bad/role.yaml"* ]] || false
}

@test "lint-roles: typo'd key is E_FIELD_UNKNOWN" {
  make_role bad
  echo 'sumary: oops' >> "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FIELD_UNKNOWN"* ]] || false
}

@test "lint-roles: missing and empty required files are named" {
  make_role bad
  rm "$PRIV/bad/SOUL.md"
  : > "$PRIV/bad/SKILL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FILE_MISSING: bad/SOUL.md"* ]] || false
  [[ "$output" == *"E_FILE_EMPTY: bad/SKILL.md"* ]] || false
}

@test "lint-roles: unresolved placeholder is E_TOKEN_UNRESOLVED" {
  make_role bad
  echo 'Hello {{NAME}}' >> "$PRIV/bad/SOUL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_TOKEN_UNRESOLVED: bad/SOUL.md"* ]] || false
}

@test "compose aborts naming the broken role when a config uses it" {
  make_role bad
  : > "$PRIV/bad/SKILL.md"
  printf 'project: t\nagents:\n  - role: bad\n' > "$OTHER_DIR/c.yaml"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"E_FILE_EMPTY"* ]] || false
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
  [[ "$output" == *"stale"* ]] || false
  grep -q tampered "$OTHER_DIR/out/t/_claude-code/agents/t-r1.md"   # still tampered
}

@test "lint-roles ignores an archive dir (_retired) so retired roles can't break the gate" {
  mkdir -p "$PRIV/_retired/old-role"          # deliberately malformed: empty dir
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

# --- authoring contract (docs/role-authoring.md) --------------------------------

# make_authored_role <name> — a role that satisfies the authoring contract
make_authored_role() {
  make_role "$1"
  cat > "$PRIV/$1/AGENTS.md" <<EOT
# Operating Rules
## Scope
Owns things.
## What to get right hardest
1. a
2. b
3. c
4. d
## Hard rules
- one: verify before claiming, with the command and its evidence
- two: say what is planned and not yet built
- three: paste failing output verbatim
- four: use an independent check and say who
## Receiving work
- x
EOT
  cat > "$PRIV/$1/SOUL.md" <<EOT
# Soul
## Role identity
x
## Core character (role layer)
x
## Decision-making (role layer)
x
## Escalation rules (role layer)
x
## Working style (role layer)
x
## What the T is NOT
x
EOT
  printf '%s\n' "$1" > "$OTHER_DIR/authored.txt"
  export GRID_AUTHORED_ROLES_FILE="$OTHER_DIR/authored.txt"
}

@test "authoring lint passes a role that meets the contract" {
  make_authored_role good
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "authoring lint: missing Hard rules section is E_SECTION_MISSING" {
  make_authored_role bad
  sed -i.bak '/^## Hard rules/,/^- four/d' "$PRIV/bad/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SECTION_MISSING: bad/AGENTS.md"* ]] || false
}

@test "authoring lint: ranked list shorter than 4 is E_SECTION_SHAPE" {
  make_authored_role bad
  sed -i.bak '/^4\. d$/d' "$PRIV/bad/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SECTION_SHAPE"* ]] || false
}

@test "authoring lint: oversized AGENTS.md is E_SIZE" {
  make_authored_role bad
  head -c 5000 /dev/zero | tr '\0' 'x' >> "$PRIV/bad/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SIZE"* ]] || false
}

@test "authoring lint: missing SOUL heading is named" {
  make_authored_role bad
  sed -i.bak '/^## Working style/,/^x$/d' "$PRIV/bad/SOUL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SECTION_MISSING: bad/SOUL.md"* ]] || false
}

@test "authoring lint ignores roles not on the authored list" {
  make_role loose                     # no AGENTS.md at all
  printf 'someone-else\n' > "$OTHER_DIR/authored.txt"
  export GRID_AUTHORED_ROLES_FILE="$OTHER_DIR/authored.txt"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

# --- private roles default location ---------------------------------------------

@test "private roles are picked up from ~/.the-grid-private/roles when the env var is unset" {
  fakehome=$(mktemp -d)
  mkdir -p "$fakehome/.the-grid-private/roles/zz-private"
  printf 'name: zz-private\ntitle: T\nsummary: S.\ndefault_model: sonnet\n' > "$fakehome/.the-grid-private/roles/zz-private/role.yaml"
  # no SOUL.md/SKILL.md: if the dir is picked up, lint must complain about it
  unset GRID_PRIVATE_ROLES_DIR
  HOME="$fakehome" run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"zz-private"* ]] || false
  rm -rf "$fakehome"
}

@test "an EMPTY GRID_PRIVATE_ROLES_DIR disables the fallback" {
  fakehome=$(mktemp -d)
  mkdir -p "$fakehome/.the-grid-private/roles/zz-private"
  GRID_PRIVATE_ROLES_DIR= HOME="$fakehome" run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
  rm -rf "$fakehome"
}
