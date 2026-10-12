#!/usr/bin/env bats
# Tests for the role.yaml `description:` key (budget-and-usage group 2): when present,
# compose.py emits it verbatim as the subagent / skill description; when absent the
# legacy formula is kept byte-for-byte. Needs the agent-factory venv (PyYAML); skipped
# where it isn't built. Roles are injected through GRID_PRIVATE_ROLES_DIR so the real
# roles/ tree is never touched, and output goes to a temp dir.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  COMPOSE="$REPO_ROOT/agent-factory/compose.py"
  PRIV=$(mktemp -d)
  OUT=$(mktemp -d)
  export GRID_PRIVATE_ROLES_DIR="$PRIV"
}

teardown() {
  rm -rf "$PRIV" "$OUT"
  unset GRID_PRIVATE_ROLES_DIR
  common_teardown
}

# make_role <name> <orchestrator true|false> [extra role.yaml lines] — a minimal valid role
make_role() {
  mkdir -p "$PRIV/$1"
  printf 'name: %s\ntitle: Tee\nsummary: Does the thing.\ndefault_model: sonnet\norchestrator: %s\n%s\n' \
    "$1" "$2" "${3:-}" > "$PRIV/$1/role.yaml"
  printf '# soul\n' > "$PRIV/$1/SOUL.md"
  printf '# skill\n' > "$PRIV/$1/SKILL.md"
}

# compose_one <role> — compose a one-role temp project (slug "s") for the claude-code target
compose_one() {
  local cfg="$OUT/cfg.yaml"
  printf 'project: p\nslug: tt\nagents:\n  - role: %s\n' "$1" > "$cfg"
  run "$PY" "$COMPOSE" "$cfg" --target claude-code --out "$OUT/out"
  [ "$status" -eq 0 ]
}

# desc_of <file> — the frontmatter `description:` value (a single line)
desc_of() {
  sed -n 's/^description: //p' "$1" | head -1
}

@test "specialist with description: composes to a subagent carrying it exactly" {
  make_role spec false 'description: "Tee. Owns x. Use for y."'
  compose_one spec
  f="$OUT/out/p/_claude-code/agents/tt-spec.md"
  [ -f "$f" ]
  [ "$(desc_of "$f")" = "Tee. Owns x. Use for y." ]
  [[ "$(desc_of "$f")" != *"Use this subagent"* ]]
}

@test "orchestrator with description: composes to a skill carrying it exactly" {
  make_role orch true 'description: "Tee. Leads x. Use for y."'
  compose_one orch
  f="$OUT/out/p/_claude-code/skills/tt-orch/SKILL.md"
  [ -f "$f" ]
  [ "$(desc_of "$f")" = "Tee. Leads x. Use for y." ]
  [[ "$(desc_of "$f")" != *"Invoke with"* ]]
}

@test "a folded multi-line description: is emitted as one line" {
  make_role spec false 'description: >-
  Tee. Owns x.
  Use for y.'
  compose_one spec
  [ "$(desc_of "$OUT/out/p/_claude-code/agents/tt-spec.md")" = "Tee. Owns x. Use for y." ]
}

@test "a role without description: keeps the legacy subagent formula exactly" {
  make_role spec false
  compose_one spec
  [ "$(desc_of "$OUT/out/p/_claude-code/agents/tt-spec.md")" = "Tee. Does the thing. Use this subagent for spec work." ]
}

@test "a role without description: keeps the legacy orchestrator formula exactly" {
  make_role orch true
  compose_one orch
  [ "$(desc_of "$OUT/out/p/_claude-code/skills/tt-orch/SKILL.md")" = "Tee orchestrator. Does the thing. Invoke with /tt-orch." ]
}

@test "lint-roles accepts description: on the real roles and an injected role" {
  make_role good false 'description: "Tee. Owns x. Use for y."'
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "lint-roles still rejects a misspelt description key" {
  make_role bad false 'descripton: "Tee. Owns x. Use for y."'
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FIELD_UNKNOWN"* ]] || false
}

@test "every public role.yaml has a single-line description of at most 250 chars" {
  run "$PY" - "$REPO_ROOT/agent-factory/roles" <<'EOF'
import sys, pathlib, yaml
bad = []
for p in sorted(pathlib.Path(sys.argv[1]).glob("*/role.yaml")):
    if p.parent.name == "_retired":
        continue
    d = yaml.safe_load(p.read_text()).get("description")
    if not d or "\n" in d or len(d) > 250 or "Use this subagent" in d or "Invoke with" in d:
        bad.append(str(p))
print("\n".join(bad))
sys.exit(1 if bad else 0)
EOF
  [ "$status" -eq 0 ]
}
