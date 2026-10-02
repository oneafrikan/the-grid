#!/usr/bin/env bats
# Tests for lint_authoring's variants (orchestrator, unattended) and the shared-four keyword check.
# Fixtures are private roles injected through GRID_PRIVATE_ROLES_DIR and enrolled through
# GRID_AUTHORED_ROLES_FILE, so the real roles/ tree and authored-roles.txt are never touched.

load helpers/setup

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  [ -x "$PY" ] || skip "agent-factory venv not built"
  COMPOSE="$REPO_ROOT/agent-factory/compose.py"
  PRIV=$(mktemp -d)
  ENROL=$(mktemp)
  export GRID_PRIVATE_ROLES_DIR="$PRIV" GRID_AUTHORED_ROLES_FILE="$ENROL"
}

teardown() {
  rm -rf "$PRIV" "$ENROL"
  unset GRID_PRIVATE_ROLES_DIR GRID_AUTHORED_ROLES_FILE
  common_teardown
}

# The four shared rules, as one block of Hard-rules lines.
SHARED='- Verify before claiming: quote the command and its output as evidence.
- Say what is planned and what is not built or not tested yet.
- Paste failing output verbatim.
- Use an independent check and say who ran it.'

# make_role <name> <role.yaml extra lines> — a fully compliant enrolled role; AGENTS.md body is piped in via $HARD
make_role() {
  local name="$1" extra="${2:-}" hard="${3:-$SHARED}" receiving="${4:-yes}"
  mkdir -p "$PRIV/$name"
  printf 'name: %s\ntitle: T\nsummary: S.\ndefault_model: sonnet\n%s\n' "$name" "$extra" > "$PRIV/$name/role.yaml"
  {
    printf '# AGENTS\n\n## Scope\nOwns x.\n\n## What to get right hardest\n1. a\n2. b\n3. c\n4. d\n\n## Hard rules\n%s\n' "$hard"
    [ "$receiving" = yes ] && printf '\n## Receiving work\n- x\n'
  } > "$PRIV/$name/AGENTS.md"
  printf '# soul\n## Role identity\nx\n## Core character (role layer)\nx\n## Decision-making (role layer)\nx\n## Escalation rules (role layer)\nx\n## Working style (role layer)\nx\n## What the T is NOT\nx\n' > "$PRIV/$name/SOUL.md"
  printf '# skill\n' > "$PRIV/$name/SKILL.md"
  echo "$name" >> "$ENROL"
}

@test "a compliant specialist passes" {
  make_role spec "orchestrator: false"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "dropping one of the shared four is E_SHARED_RULE_MISSING naming the idea" {
  make_role spec "orchestrator: false" '- Verify before claiming: quote evidence.
- Say what is planned and not yet built.
- Use an independent check.
- Keep it short.'
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SHARED_RULE_MISSING: spec/AGENTS.md"*"failures verbatim"* ]]
}

@test "an orchestrator needs no Receiving work section and may be up to 5120 bytes; a specialist may not exceed 4096" {
  make_role orch "orchestrator: true" "$SHARED" no
  make_role spec "orchestrator: false"
  # pad both to ~4500 bytes with a trailing section
  for r in orch spec; do
    printf '\n## Notes\n%s\n' "$(head -c 4400 /dev/zero | tr '\0' 'x')" >> "$PRIV/$r/AGENTS.md"
  done
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SIZE: spec/AGENTS.md"* ]]
  [[ "$output" != *"orch/AGENTS.md"* ]]
}

@test "an orchestrator over 5120 bytes is E_SIZE" {
  make_role orch "orchestrator: true" "$SHARED" no
  printf '\n## Notes\n%s\n' "$(head -c 5200 /dev/zero | tr '\0' 'x')" >> "$PRIV/orch/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SIZE: orch/AGENTS.md"*"5120"* ]]
}

@test "an unattended role must state a safe-target step and a run-record rule" {
  make_role un "unattended: true"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_UNATTENDED_RULE_MISSING: un/AGENTS.md"*"safe-target"* ]]
  [[ "$output" == *"E_UNATTENDED_RULE_MISSING: un/AGENTS.md"*"run-record"* ]]
}

@test "an unattended role with both rules passes" {
  make_role un "unattended: true" "$SHARED
- Preview the planned write in the run record before any outward write.
- Append one run-record line per run."
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "the real repo: every enrolled role satisfies its variant" {
  unset GRID_PRIVATE_ROLES_DIR GRID_AUTHORED_ROLES_FILE
  export GRID_PRIVATE_ROLES_DIR=
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}
