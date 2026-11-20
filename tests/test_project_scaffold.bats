#!/usr/bin/env bats
# project-scaffold: `cut-project.sh --generic` lays down the generic core docs, optional docs
# only when asked, never overwrites, and the generic templates carry no grid vocabulary.
# Cuts only ever happen in temp dirs.

load helpers/setup

setup() {
  common_setup
  CUT="$REPO_ROOT/project-factory/scripts/cut-project.sh"
  TPL="$REPO_ROOT/project-factory/templates"
  P=$(mktemp_canon)
  CORE="CHANGELOG.md CLAUDE.md CONVENTIONS.md DECISIONS.md DOCS.md GUARDRAILS.md MAP.md PURPOSE.md RULES.md scripts/map.py"
  OPT="ASSUMPTIONS.md CALCULATIONS.md CONTEXT.md DESIGN.md AGENTS.md HUMANS.md LOGS.md"
}

teardown() {
  rm -rf "$P"
  common_teardown
}

# files_in DIR — every file below DIR (not .git), sorted, relative.
files_in() { (cd "$1" && find . -name .git -prune -o -type f -print | sed 's|^\./||' | sort); }

@test "generic cut on an empty dir writes exactly the core set plus the generated MAP.md" {
  run bash "$CUT" --generic "$P"
  [ "$status" -eq 0 ]
  want=$(printf '%s\n' $CORE | sort)
  [ "$(files_in "$P")" = "$want" ]
}

@test "generic cut leaves out every grid-coupled _common file" {
  bash "$CUT" --generic "$P" >/dev/null
  for f in SPECS.md BEHAVIOUR.md AGENTS-SETUP.md LEARNINGS.md signals knowledge loop handoffs .grid .githooks .claude; do
    [ ! -e "$P/$f" ]
  done
}

@test "optional files appear only when asked: none by default" {
  bash "$CUT" --generic "$P" >/dev/null
  for f in $OPT; do [ ! -e "$P/$f" ]; done
}

@test "--with writes only the named optional files" {
  run bash "$CUT" --generic --with humans,design "$P"
  [ "$status" -eq 0 ]
  [ -f "$P/HUMANS.md" ]
  [ -f "$P/DESIGN.md" ]
  [ ! -e "$P/LOGS.md" ]
  [ ! -e "$P/ASSUMPTIONS.md" ]
}

@test "--all-optional writes all seven optional files" {
  run bash "$CUT" --generic --all-optional "$P"
  [ "$status" -eq 0 ]
  for f in $OPT; do [ -f "$P/$f" ]; done
}

@test "an unknown optional name fails before anything is written" {
  run bash "$CUT" --generic --with nonsense "$P"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown optional file 'nonsense'"* ]] || false
  [ -z "$(ls -A "$P")" ]
}

@test "a second run is a clean no-op: nothing written, nothing skipped" {
  bash "$CUT" --generic --all-optional "$P" >/dev/null
  before=$(cd "$P" && find . -name .git -prune -o -type f -exec cksum {} + | sort)
  run bash "$CUT" --generic --all-optional "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) written, 0 skipped"* ]] || false
  [[ "$output" != *"wrote:"* ]] || false
  after=$(cd "$P" && find . -name .git -prune -o -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ]
}

@test "an existing differing CONVENTIONS.md is untouched and reported as skipped" {
  echo "my own conventions" > "$P/CONVENTIONS.md"
  run bash "$CUT" --generic "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$P/CONVENTIONS.md")" = "my own conventions" ]
  [[ "$output" == *"SKIPPED (exists, differs — review manually): CONVENTIONS.md"* ]] || false
  [ -f "$P/RULES.md" ]
}

@test "an existing differing optional file is also preserved" {
  echo "my humans" > "$P/HUMANS.md"
  run bash "$CUT" --generic --with humans "$P"
  [ "$(cat "$P/HUMANS.md")" = "my humans" ]
  [[ "$output" == *"SKIPPED (exists, differs — review manually): HUMANS.md"* ]] || false
}

@test "generic mode never prints the grid trailhead block for an existing CLAUDE.md" {
  echo "mine" > "$P/CLAUDE.md"
  run bash "$CUT" --generic "$P"
  [ "$(cat "$P/CLAUDE.md")" = "mine" ]
  [[ "$output" != *"charter-trailhead"* ]] || false
}

@test "--with also works on a stack template cut" {
  run bash "$CUT" --with calculations python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ -f "$P/CALCULATIONS.md" ]
}

@test "the generated MAP.md lists the new core docs" {
  bash "$CUT" --generic --with humans "$P" >/dev/null
  for f in RULES.md CONVENTIONS.md DECISIONS.md DOCS.md CHANGELOG.md HUMANS.md; do
    grep -q "\`$f\`" "$P/MAP.md"
  done
}

@test "CLAUDE.md template is under 60 lines and every core template opens with a purpose line" {
  [ "$(wc -l < "$TPL/_core/CLAUDE.md" | tr -d ' ')" -lt 60 ]
  for f in "$TPL"/_core/*.md "$TPL"/_optional/*.md "$TPL/_common/CONTEXT.md"; do
    head -1 "$f" | grep -q '^# '
    grep -q 'What goes here' "$f"
  done
}

@test "RULES.md template has the entry format, an archive section and three baseline rules" {
  f="$TPL/_core/RULES.md"
  grep -q '^## Archived Rules' "$f"
  [ "$(grep -c '^### \[<fill' "$f")" -eq 3 ]
  [ "$(grep -c '^\*\*Why:\*\*' "$f")" -ge 3 ]
}

@test "generic templates and the skill carry none of the grid vocabulary" {
  # bounded words, not \b: BSD grep portability (docs/portability.md)
  run grep -rniE '(^|[^[:alnum:]_-])grid([^[:alnum:]_-]|$)|the-grid|agent-factory|signals/|knowledge/|openspec|wire\.sh' \
    "$TPL/_core" "$TPL/_optional" "$TPL/_common/CONTEXT.md" "$REPO_ROOT/skills/project-scaffold"
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "the skill has name and description frontmatter and stays under 4000 bytes" {
  f="$REPO_ROOT/skills/project-scaffold/SKILL.md"
  head -5 "$f" | grep -q '^name: project-scaffold$'
  head -5 "$f" | grep -q '^description: '
  [ "$(wc -c < "$f" | tr -d ' ')" -lt 4000 ]
}

# The generic map must say nothing about files or folders the project does not have.
@test "the generated MAP.md of a bare generic cut has none of the grid vocabulary and no absent-file sections" {
  bash "$CUT" --generic "$P" >/dev/null
  run grep -niE '(^|[^[:alnum:]_-])grid([^[:alnum:]_-]|$)|the-grid|agent-factory|signals/|knowledge/|openspec|wire\.sh|learning: on' "$P/MAP.md"
  echo "$output"
  [ "$status" -eq 1 ]
  ! grep -qE '^## (Topology|Epistemology)|^### (Signals|Memory|Canon|Roles|Skills|Knowledge)' "$P/MAP.md" || false
}

@test "the copied scripts/map.py docstring carries none of the grid vocabulary" {
  bash "$CUT" --generic "$P" >/dev/null
  doc=$(python3 -c 'import ast,sys; print(ast.get_docstring(ast.parse(open(sys.argv[1]).read())))' "$P/scripts/map.py")
  [ -n "$doc" ]
  run grep -niE '(^|[^[:alnum:]_-])grid([^[:alnum:]_-]|$)|the-grid|agent-factory|signals/|knowledge/|openspec|wire\.sh|learning: on' <<< "$doc"
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "adding signals/ makes the Signals section appear in the regenerated map" {
  bash "$CUT" --generic "$P" >/dev/null
  ! grep -q '^### Signals' "$P/MAP.md" || false
  mkdir "$P/signals"
  (cd "$P" && python3 scripts/map.py)
  grep -q '^### Signals' "$P/MAP.md"
}

@test "a stack-template cut still gets the Signals, Canon and Memory sections" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  grep -q '^### Signals' "$P/MAP.md"
  grep -q '^### Canon' "$P/MAP.md"
  grep -q '^### Memory' "$P/MAP.md"
}
