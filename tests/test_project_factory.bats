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

# --- charter files (change charter-files) --------------------------------------------------
# The eight source paths every cut project receives from templates/_common. MAP.md is not one of
# them: it is generated after the copy (see the "MAP.md at cut time" cases further down).
CHARTER_PATHS="PURPOSE.md GUARDRAILS.md BEHAVIOUR.md scripts/map.py .githooks/pre-commit signals/README.md knowledge/README.md knowledge/canon/.gitkeep"

@test "a seed gets every charter file, and the shim is executable" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  for f in $CHARTER_PATHS; do [ -e "$P/$f" ] || { echo "missing: $f"; return 1; }; done
  [ -x "$P/.githooks/pre-commit" ]
}

@test "every template gets the charter files and the trailhead in its CLAUDE.md" {
  for t in finance-agents-base lamp-agents-base python-astro-content-agent; do
    d=$(mktemp -d)
    bash "$CUT" "$t" "$d" >/dev/null
    for f in $CHARTER_PATHS; do [ -e "$d/$f" ] || { echo "$t missing: $f"; rm -rf "$d"; return 1; }; done
    grep -q '^<!-- charter-trailhead -->$' "$d/CLAUDE.md" || { echo "$t: no trailhead"; rm -rf "$d"; return 1; }
    rm -rf "$d"
  done
}

@test "the seeded GUARDRAILS.md has no active entry and the seeded PURPOSE.md is an unfilled stub" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  ! grep -Eq '^- G[0-9]+:' "$P/GUARDRAILS.md" || false
  grep -q '<fill' "$P/PURPOSE.md"
}

@test "a retrofit leaves a differing PURPOSE.md unchanged, lists it as SKIPPED, and still writes the rest" {
  echo "my own purpose" > "$P/PURPOSE.md"
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$P/PURPOSE.md")" = "my own purpose" ]
  [[ "$output" == *"SKIPPED (exists, differs — review manually): PURPOSE.md"* ]] || false
  [ -f "$P/GUARDRAILS.md" ]
  [ -f "$P/signals/README.md" ]
}

@test "a second identical cut writes nothing" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) written"* ]] || false
}

@test "a default cut writes no RELATED.md" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  [ ! -e "$P/RELATED.md" ]
}
