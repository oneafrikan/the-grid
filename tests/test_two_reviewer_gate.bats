#!/usr/bin/env bats
# Tests for the Step 6 two-reviewer release gate in agent-factory/roles/tech-lead/SKILL.md.
# The gate's invariants are exact strings in the prompt, so they are pinned with grep -F inside
# the Step 6 section only (a match elsewhere in the file must not count). The text checks need
# no venv; the deploy / lint / eval-validate checks skip without it. No model is ever called.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  SKILL="$REPO_ROOT/agent-factory/roles/tech-lead/SKILL.md"
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  # Just the Step 6 section: from its heading to the next "## " heading.
  SECTION=$(awk '/^## Step 6 /{f=1;print;next} /^## /{f=0} f' "$SKILL")
}

teardown() {
  common_teardown
}

@test "Step 6 section exists and is the release gate" {
  [ -n "$SECTION" ]
  printf '%s\n' "$SECTION" | head -1 | grep -qF "## Step 6 — Release gate: two independent reviewers"
}

# Each string is case-sensitive and must appear verbatim inside Step 6.
@test "Step 6 names qa-engineer" {
  printf '%s\n' "$SECTION" | grep -qF "qa-engineer"
}

@test "Step 6 names security-reviewer" {
  printf '%s\n' "$SECTION" | grep -qF "security-reviewer"
}

@test "Step 6 says both must pass" {
  printf '%s\n' "$SECTION" | grep -qF "Both must pass."
}

@test "Step 6 keeps the reviewers independent" {
  printf '%s\n' "$SECTION" | grep -qF "does not see"
}

@test "Step 6 caps the fix loop at 3 rounds" {
  printf '%s\n' "$SECTION" | grep -qF "Maximum 3 rounds"
}

@test "a lean deploy of tech-lead carries the gate" {
  require_venv "$PY"
  PROJ=$(mktemp -d)
  run "$PY" "$REPO_ROOT/agent-factory/deploy.py" "$PROJ" --roles tech-lead --profile lean
  [ "$status" -eq 0 ]
  grep -rqF "Release gate: two independent reviewers" "$PROJ/.claude"
  rm -rf "$PROJ"
}

@test "role lint passes" {
  require_venv "$PY"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" --lint-roles
  [ "$status" -eq 0 ]
}

@test "eval case validation passes" {
  require_venv "$PY"
  run "$PY" "$REPO_ROOT/agent-factory/run_evals.py" --validate
  [ "$status" -eq 0 ]
}

# WP-070: the verdict derivation, the docs-only definition and the packet wording are exact strings.
@test "Step 6 derives the security verdict from the severity table" {
  printf '%s\n' "$SECTION" | grep -qF "no open Critical or High finding in it"
  printf '%s\n' "$SECTION" | grep -qF "Do not re-rate findings."
}

@test "Step 6 defines docs-only" {
  printf '%s\n' "$SECTION" | grep -qF 'only `*.md` files under `docs/`'
}

@test "Step 6 packet is a role spawn, not the /qa_engineer slash form" {
  printf '%s\n' "$SECTION" | grep -qF 'Spawn the `qa-engineer` role with this packet:'
  run bash -c 'printf "%s\n" "$1" | grep -qF "/qa_engineer"' _ "$SECTION"
  [ "$status" -ne 0 ]
}
