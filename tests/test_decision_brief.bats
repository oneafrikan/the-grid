#!/usr/bin/env bats
# Tests for the shared decision-brief fragment (agent-factory/_core/DECISION_BRIEF.md):
# appended by compose.py to orchestrators only (full render and lean deploy), and linted.
# Needs the agent-factory venv; skipped where it isn't built. Everything renders into temp
# dirs; no model is called.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  FRAGMENT="$REPO_ROOT/agent-factory/_core/DECISION_BRIEF.md"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
  common_teardown
}

@test "fragment carries the format's fixed strings" {
  for s in "Summary" "Stakes" "Recommendation" "D3: B" "destructive or irreversible"; do
    grep -qF -- "$s" "$FRAGMENT"
  done
}

@test "fixture claude-code output: every orchestrator skill has the section, no specialist does" {
  # Same pinned inputs as scripts/compose-goldens.sh: fixture roles + neutral identity.
  GRID_PRIVATE_ROLES_DIR="$REPO_ROOT/tests/fixtures/compose/roles" \
  GRID_USER_CONFIG="$REPO_ROOT/agent-factory/user.public.yaml" \
  GRID_MODELS_FILE="$REPO_ROOT/agent-factory/models.yaml" \
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
      --target claude-code --out "$TMP/out"
  [ "$status" -eq 0 ]
  skills=$(find "$TMP/out" -path '*/skills/*/SKILL.md')
  agents=$(find "$TMP/out" -path '*/agents/*.md')
  [ -n "$skills" ]
  [ -n "$agents" ]
  for f in $skills; do grep -qF "## Decision briefs" "$f"; done
  for f in $agents; do ! grep -qF "## Decision briefs" "$f"; done
}

@test "lean deploy writes the section into the orchestrator only" {
  run "$PY" "$REPO_ROOT/agent-factory/deploy.py" "$TMP" --roles tech-lead,qa-engineer --profile lean
  [ "$status" -eq 0 ]
  grep -qF "## Decision briefs" "$TMP/.claude/skills/grid-tech-lead/SKILL.md"
  ! grep -qF "## Decision briefs" "$TMP/.claude/agents/grid-qa-engineer.md"
}

@test "role lint passes (fragment present, under the cap, has D<N>)" {
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" --lint-roles
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "lint_decision_brief flags an oversize fragment" {
  # 1600 bytes, contains D<N>: only the size rule can fire.
  { printf 'D<N> '; head -c 1595 /dev/zero | tr '\0' 'x'; } > "$TMP/big.md"
  [ "$(wc -c < "$TMP/big.md")" -eq 1600 ]
  run "$PY" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/agent-factory')
import compose
from pathlib import Path
p = compose.lint_decision_brief(Path('$TMP/big.md'))
print(p)
assert len(p) == 1 and p[0].startswith('E_DECISION_BRIEF')
"
  [ "$status" -eq 0 ]
}

@test "lint_decision_brief flags a missing file and a fragment without D<N>" {
  printf 'no label here\n' > "$TMP/nolabel.md"
  run "$PY" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/agent-factory')
import compose
from pathlib import Path
for path in ('$TMP/missing.md', '$TMP/nolabel.md'):
    p = compose.lint_decision_brief(Path(path))
    print(p)
    assert len(p) == 1 and p[0].startswith('E_DECISION_BRIEF')
"
  [ "$status" -eq 0 ]
}
