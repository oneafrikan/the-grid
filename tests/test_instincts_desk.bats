#!/usr/bin/env bats
# Tests for instincts group 7: learning-desk integration (tank evolve, oracle source, docs).
# Text assertions on role files plus one run of `instincts.sh clusters` on a fixture store
# built in a temp dir. Everything is synthetic.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SH="$REPO_ROOT/scripts/instincts.sh"
TANK="$REPO_ROOT/agent-factory/roles/tank"
ORACLE="$REPO_ROOT/agent-factory/roles/oracle"

setup() {
  unset GRID_HOST GRID_INSTINCTS GRID_STATE_DIR GRID_LEARNING_DIR GRID_PRIVATE_DIR
  export PYTHONDONTWRITEBYTECODE=1
}

@test "tank AGENTS.md names the instincts store and the skill-drafts path" {
  grep -qF '~/.the-grid-private/learning/instincts/' "$TANK/AGENTS.md"
  grep -qF '~/.the-grid-private/learning/tank/skill-drafts/' "$TANK/AGENTS.md"
  grep -qF 'scripts/instincts.sh clusters' "$TANK/AGENTS.md"
}

@test "tank AGENTS.md has the instinct definition, the skill-drafts hard rule and the evolve routing row" {
  grep -qF 'An instinct in one project is a lead; an instinct active in 2+ projects is a pattern' "$TANK/AGENTS.md"
  grep -qF 'never into `skills/`' "$TANK/AGENTS.md"
  grep -qF 'tank `evolve`' "$TANK/AGENTS.md"
}

@test "tank AGENTS.md is at most 4096 bytes" {
  [ "$(wc -c < "$TANK/AGENTS.md")" -le 4096 ]
}

@test "oracle SKILL.md mentions preference instincts" {
  grep -q 'preference' "$ORACLE/SKILL.md"
  grep -q 'OBSERVED' "$ORACLE/SKILL.md"
}

@test "tank SKILL.md has Step 4b with the four frontmatter keys" {
  grep -qF '## Step 4b' "$TANK/SKILL.md"
  for k in 'name: <slug>' 'description: <' 'status: draft' 'generated-by: tank-evolve'; do
    grep -qF "$k" "$TANK/SKILL.md"
  done
}

@test "tank SKILL.md mentions allowed-tools only in the forbidden-content rule" {
  # Every other line must be free of it; the one allowed line is the rule itself.
  run bash -c "grep 'allowed-tools' '$TANK/SKILL.md' | grep -v 'Leave out, and list under'"
  [ "$status" -eq 1 ]
}

@test "docs/instincts.md exists and covers learning: on and forget" {
  [ -f "$REPO_ROOT/docs/instincts.md" ]
  grep -qF 'learning: on' "$REPO_ROOT/docs/instincts.md"
  grep -q 'forget' "$REPO_ROOT/docs/instincts.md"
}

@test "instincts.sh clusters prints a cluster from a fixture store" {
  export GRID_LEARNING_DIR="$BATS_TEST_TMPDIR/learning"
  export GRID_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GRID_HOST=host-a
  local d="$GRID_LEARNING_DIR/instincts/aaaaaaaaaaaa"
  mkdir -p "$d"
  for n in one two three; do
    printf '%s\n' "{\"id\":\"habit-$n\",\"trigger\":\"when testing\",\"action\":\"do the $n thing\",\"domain\":\"testing\",\"scope\":\"project\",\"project\":\"aaaaaaaaaaaa\",\"confidence\":0.7,\"weeks_seen\":3,\"first_seen\":\"2026-W38\",\"last_seen\":\"2026-W40\",\"misses\":0,\"status\":\"active\",\"host\":\"host-a\"}" >> "$d/host-a.jsonl"
  done
  run "$SH" clusters
  [ "$status" -eq 0 ]
  [[ "$output" == *"cluster: project=aaaaaaaaaaaa domain=testing size=3"* ]]
}
