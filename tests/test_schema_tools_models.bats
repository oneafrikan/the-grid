#!/usr/bin/env bats
# Tests for the role.yaml `tools:` and `unattended:` keys and the central models.yaml tier map.
# Needs the agent-factory venv; skipped without it. Bad roles are injected through
# GRID_PRIVATE_ROLES_DIR and deploys go to temp dirs, so nothing real is touched.

load helpers/setup

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  [ -x "$PY" ] || skip "agent-factory venv not built"
  COMPOSE="$REPO_ROOT/agent-factory/compose.py"
  DEPLOY="$REPO_ROOT/agent-factory/deploy.py"
  PRIV=$(mktemp -d)
  PROJ=$(mktemp -d)
  export GRID_PRIVATE_ROLES_DIR="$PRIV"
}

teardown() {
  rm -rf "$PRIV" "$PROJ"
  unset GRID_PRIVATE_ROLES_DIR GRID_MODELS_FILE
  common_teardown
}

# make_role <name> [extra role.yaml lines...] — a minimal valid role in the private tree
make_role() {
  local name="$1"; shift
  mkdir -p "$PRIV/$name"
  printf 'name: %s\ntitle: T\nsummary: S.\ndefault_model: sonnet\norchestrator: false\n' "$name" > "$PRIV/$name/role.yaml"
  for line in "$@"; do printf '%s\n' "$line" >> "$PRIV/$name/role.yaml"; done
  printf '# soul\n' > "$PRIV/$name/SOUL.md"
  printf '# skill\n' > "$PRIV/$name/SKILL.md"
}

@test "lint accepts a tools allowlist and unattended: true on a specialist" {
  make_role good "tools: [Read, Grep]" "unattended: true"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "lint rejects tools that is not a list, an empty list, or has a comma inside a name" {
  make_role a "tools: Read"
  make_role b "tools: []"
  make_role c 'tools: ["Read, Grep"]'
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FIELD_TYPE: a/role.yaml"* ]]
  [[ "$output" == *"E_FIELD_TYPE: b/role.yaml"* ]]
  [[ "$output" == *"E_FIELD_TYPE: c/role.yaml"* ]]
}

@test "lint rejects tools on an orchestrator (it deploys as a skill and would ignore it)" {
  make_role orch "tools: [Read]"
  sed -i.bak 's/^orchestrator: false/orchestrator: true/' "$PRIV/orch/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_TOOLS_ON_ORCHESTRATOR: orch/role.yaml"* ]]
}

@test "lint rejects a non-boolean unattended" {
  make_role u "unattended: maybe"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"'unattended' must be true/false"* ]]
}

@test "deploy writes a tools line only for roles that set one; orchestrator skills get none" {
  run "$PY" "$DEPLOY" "$PROJ" --roles qa-engineer,security-reviewer,backend-dev,tech-lead
  [ "$status" -eq 0 ]
  grep -q '^tools: Read, Grep, Glob, Bash$' "$PROJ/.claude/agents/grid-qa-engineer.md"
  grep -q '^tools: Read, Grep, Glob, Bash, WebFetch, WebSearch$' "$PROJ/.claude/agents/grid-security-reviewer.md"
  ! grep -qE '^tools:.*(Edit|Write)' "$PROJ/.claude/agents/grid-qa-engineer.md"
  ! grep -qE '^tools:.*(Edit|Write)' "$PROJ/.claude/agents/grid-security-reviewer.md"
  ! grep -q '^tools:' "$PROJ/.claude/agents/grid-backend-dev.md"
  ! grep -q '^tools:' "$PROJ/.claude/skills/grid-tech-lead/SKILL.md"
}

@test "models.yaml default maps each tier to itself, so nothing changes until a tier is pinned" {
  "$PY" "$DEPLOY" "$PROJ" --roles qa-engineer,finance-risk-officer
  grep -q '^model: sonnet$' "$PROJ/.claude/agents/grid-qa-engineer.md"
  grep -q '^model: haiku$' "$PROJ/.claude/agents/grid-finance-risk-officer.md"
}

@test "pinning a tier in a models file changes every role on that tier, and only that tier" {
  printf 'tiers:\n  sonnet: claude-sonnet-5-5\n' > "$PRIV/models.yaml"
  GRID_MODELS_FILE="$PRIV/models.yaml" "$PY" "$DEPLOY" "$PROJ" --roles qa-engineer,finance-risk-officer
  grep -q '^model: claude-sonnet-5-5$' "$PROJ/.claude/agents/grid-qa-engineer.md"
  grep -q '^model: haiku$' "$PROJ/.claude/agents/grid-finance-risk-officer.md"
}

@test "the shipped models.yaml lints clean and covers every tier a role can use" {
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
  run "$PY" -c "
import sys; sys.path.insert(0, '$REPO_ROOT/agent-factory')
import compose
missing = compose.ROLE_MODELS - set(compose._model_map(str(compose.MODELS_FILE)))
assert not missing, missing"
  [ "$status" -eq 0 ]
}

@test "models lint rejects an unknown tier and an empty value" {
  printf 'tiers:\n  gpt: x\n  haiku: ""\n' > "$PRIV/models.yaml"
  GRID_MODELS_FILE="$PRIV/models.yaml" run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_MODEL_INVALID: models.yaml: unknown tier 'gpt'"* ]]
  [[ "$output" == *"E_MODELS_FILE: models.yaml: tier 'haiku' needs a non-empty model string"* ]]
}

@test "the hand-kept OpenClaw roster.json agrees with role.yaml on every orchestrator's model" {
  run "$PY" -c "
import json, sys; sys.path.insert(0, '$REPO_ROOT/agent-factory')
import compose
roster = json.load(open('$REPO_ROOT/agent-factory/openclaw/roster.json'))['orchestrators']
bad = {r: (e.get('model'), compose.resolve_model({'role': r})) for r, e in roster.items()
       if 'model' in e and e['model'] != compose.resolve_model({'role': r})}
assert not bad, bad"
  [ "$status" -eq 0 ]
}

@test "gh-triage and finance-manager are marked unattended" {
  grep -q '^unattended: true' "$REPO_ROOT/agent-factory/roles/gh-triage/role.yaml"
  grep -q '^unattended: true' "$REPO_ROOT/agent-factory/roles/finance-manager/role.yaml"
}
