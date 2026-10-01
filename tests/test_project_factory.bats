#!/usr/bin/env bats
# project-factory seeds: _common files reach every cut project, retrofits never clobber.
# Cuts only into temp dirs.

load helpers/setup

setup() {
  common_setup
  CUT="$REPO_ROOT/project-factory/scripts/cut-project.sh"
  P=$(mktemp -d)
}

teardown() {
  rm -rf "$P"
  common_teardown
}

@test "a seeded project gets the project-review skill with valid frontmatter" {
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  f="$P/.claude/skills/project-review/SKILL.md"
  [ -f "$f" ]
  head -5 "$f" | grep -q '^name: project-review$'
  head -5 "$f" | grep -q '^description: '
}

@test "the project-review seed says plainly that its invariants are unfilled" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  grep -q '<fill' "$P/.claude/skills/project-review/SKILL.md"
  grep -q 'never invent invariants' "$P/.claude/skills/project-review/SKILL.md"
}

@test "a retrofit does not overwrite an existing project-review skill" {
  mkdir -p "$P/.claude/skills/project-review"
  echo mine > "$P/.claude/skills/project-review/SKILL.md"
  run bash "$CUT" python-agents-base "$P"
  [ "$(cat "$P/.claude/skills/project-review/SKILL.md")" = "mine" ]
  [[ "$output" == *"SKIPPED"* ]] || false
}

@test "the seeded agent setup files are present" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  [ -f "$P/AGENTS-SETUP.md" ]
  [ -f "$P/.grid/project.yaml" ]
  [ -f "$P/handoffs/TEMPLATE.md" ]
}

@test "a clean seed exits 0 (regression: the last line used to make it exit 1)" {
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
}
