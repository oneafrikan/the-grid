#!/usr/bin/env bats
# project-bootstrap: `cut-project.sh --generic --grid` adds the grid-coupled _common files on
# top of the generic core set, with the same never-overwrite rule; the project-bootstrap skill
# is well-formed and cites only commands and flags that exist. Cuts only happen in temp dirs.

load helpers/setup

setup() {
  common_setup
  CUT="$REPO_ROOT/project-factory/scripts/cut-project.sh"
  SKILL="$REPO_ROOT/skills/project-bootstrap"
  P=$(mktemp_canon)
  Q=$(mktemp_canon)
  # What --grid adds, by name (the same list as GRID_FILES in cut-project.sh, expanded).
  GRIDSET=".claude/skills/project-review/SKILL.md .githooks/pre-commit .grid/project.yaml
AGENTS-SETUP.md BEHAVIOUR.md LEARNINGS.md SPECS.md handoffs/.gitkeep handoffs/TEMPLATE.md
knowledge/README.md knowledge/canon/.gitkeep knowledge/established/.gitkeep
knowledge/provisional/.gitkeep knowledge/retired/.gitkeep knowledge/superseded/.gitkeep
knowledge/wip/.gitkeep loop/ENABLE.md loop/loop.conf.seed scripts/knowledge.py signals/README.md"
}

teardown() {
  rm -rf "$P" "$Q"
  common_teardown
}

# files_in DIR — every file below DIR (not .git), sorted, relative.
files_in() { (cd "$1" && find . -name .git -prune -o -type f -print | sed 's|^\./||' | sort); }

# sums_in DIR — cksum of every file below DIR except the generated MAP.md, sorted.
sums_in() { (cd "$1" && find . -name .git -prune -o -type f ! -name MAP.md -exec cksum {} + | sort); }

@test "--grid on an empty dir writes the generic core set plus exactly the grid files" {
  run bash "$CUT" --generic --grid "$P"
  [ "$status" -eq 0 ]
  want=$( { printf '%s\n' CHANGELOG.md CLAUDE.md CONVENTIONS.md DECISIONS.md DOCS.md GUARDRAILS.md MAP.md PURPOSE.md RULES.md scripts/map.py; printf '%s\n' $GRIDSET; } | sort)
  [ "$(files_in "$P")" = "$want" ]
}

@test "--grid sets core.hooksPath on a seed because the shim now exists" {
  bash "$CUT" --generic --grid "$P" >/dev/null
  [ "$(git -C "$P" config --get core.hooksPath)" = ".githooks" ]
}

@test "without --grid the generic output is unchanged: no grid file, no hooks path" {
  bash "$CUT" --generic "$P" >/dev/null
  want=$(printf '%s\n' CHANGELOG.md CLAUDE.md CONVENTIONS.md DECISIONS.md DOCS.md GUARDRAILS.md MAP.md PURPOSE.md RULES.md scripts/map.py | sort)
  [ "$(files_in "$P")" = "$want" ]
  ! git -C "$P" config --get core.hooksPath || false
}

@test "--grid leaves every generic file byte-identical to a plain generic cut" {
  bash "$CUT" --generic "$P" >/dev/null
  bash "$CUT" --generic --grid "$Q" >/dev/null
  # every checksum line of the plain cut (minus MAP.md) is also in the grid cut
  while IFS= read -r line; do
    sums_in "$Q" | grep -qxF -- "$line"
  done < <(sums_in "$P")
}

@test "--grid with --with works and a second run is a clean no-op" {
  bash "$CUT" --generic --grid --with humans,design "$P" >/dev/null
  before=$(cd "$P" && find . -name .git -prune -o -type f -exec cksum {} + | sort)
  run bash "$CUT" --generic --grid --with humans,design "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) written, 0 skipped"* ]] || false
  [[ "$output" != *"wrote:"* ]] || false
  after=$(cd "$P" && find . -name .git -prune -o -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ]
}

@test "an existing differing grid file is preserved and reported as skipped" {
  echo "my specs" > "$P/SPECS.md"
  mkdir "$P/signals"
  echo "my signals readme" > "$P/signals/README.md"
  run bash "$CUT" --generic --grid "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$P/SPECS.md")" = "my specs" ]
  [ "$(cat "$P/signals/README.md")" = "my signals readme" ]
  [[ "$output" == *"SKIPPED (exists, differs — review manually): SPECS.md"* ]] || false
  [[ "$output" == *"SKIPPED (exists, differs — review manually): signals/README.md"* ]] || false
  [ -f "$P/BEHAVIOUR.md" ]
}

@test "a retrofit with --grid does not touch git config and prints the hook command" {
  git -C "$P" init -q
  echo "mine" > "$P/README.md"
  run bash "$CUT" --generic --grid "$P"
  [ "$status" -eq 0 ]
  ! git -C "$P" config --get core.hooksPath || false
  [[ "$output" == *"git config core.hooksPath .githooks"* ]] || false
}

@test "--grid without --generic is a documented no-op: prints a note, tree equals the plain stack cut" {
  run bash "$CUT" --grid python-agents-base "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--grid has no effect without --generic"* ]] || false
  bash "$CUT" python-agents-base "$Q" >/dev/null
  [ "$(files_in "$P")" = "$(files_in "$Q")" ]
}

@test "a stack-template cut is unchanged by the --grid code: same tree as the _common set requires" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  for f in $GRIDSET; do [ -f "$P/$f" ]; done
}

@test "the MAP.md of a --grid cut shows the Signals and Epistemology sections and passes map --check" {
  bash "$CUT" --generic --grid "$P" >/dev/null
  grep -q '^### Signals' "$P/MAP.md"
  grep -q '^## Epistemology' "$P/MAP.md"
  run python3 "$P/scripts/map.py" --check --root "$P"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the project-scaffold skill and the generic templates still carry no grid vocabulary" {
  # --grid must not leak into the generic layer: the files it reads stay clean.
  run grep -rniE '(^|[^[:alnum:]_-])grid([^[:alnum:]_-]|$)|the-grid|agent-factory|signals/|knowledge/|openspec|wire\.sh' \
    "$REPO_ROOT/skills/project-scaffold" "$REPO_ROOT/project-factory/templates/_core" "$REPO_ROOT/project-factory/templates/_optional"
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "project-bootstrap: frontmatter, description length and sizes are valid" {
  f="$SKILL/SKILL.md"
  head -5 "$f" | grep -q '^name: project-bootstrap$'
  desc=$(grep -m1 '^description: ' "$f" | sed 's/^description: //')
  [ -n "$desc" ]
  [ "${#desc}" -le 250 ]
  [ "$(wc -c < "$f" | tr -d ' ')" -lt 4000 ]
  for s in "$SKILL"/sections/*.md; do
    [ "$(wc -c < "$s" | tr -d ' ')" -le 6000 ]
    grep -q "^- sections/$(basename "$s"):" "$f"
  done
}

@test "project-bootstrap: every sections/ line in the index points at a real file" {
  grep -oE '^- sections/[A-Za-z0-9._-]+' "$SKILL/SKILL.md" | sed 's/^- //' | while IFS= read -r rel; do
    [ -f "$SKILL/$rel" ]
  done
}

@test "project-bootstrap: every flag the skill cites exists in a tool it names" {
  tools="$REPO_ROOT/project-factory/scripts/cut-project.sh $REPO_ROOT/agent-factory/deploy.py $REPO_ROOT/agent-factory/deploy_hooks.py $REPO_ROOT/scripts/map.py"
  flags=$(cat "$SKILL/SKILL.md" "$SKILL"/sections/*.md | grep -oE '(^|[ `\[|])--[a-z][a-z-]+' | tr -d ' `[|' | sort -u)
  [ -n "$flags" ]
  for fl in $flags; do
    # shellcheck disable=SC2086
    grep -qF -- "$fl" $tools || { echo "flag not found in any tool: $fl"; false; }
  done
}

@test "project-bootstrap: every script and path the skill cites exists" {
  [ -f "$REPO_ROOT/project-factory/scripts/cut-project.sh" ]
  [ -f "$REPO_ROOT/agent-factory/deploy.py" ]
  [ -f "$REPO_ROOT/agent-factory/deploy_hooks.py" ]
  [ -f "$REPO_ROOT/project-factory/templates/_common/scripts/map.py" ]
  # the cited names resolve to real template files
  for f in BEHAVIOUR.md SPECS.md AGENTS-SETUP.md .grid/project.yaml signals/README.md loop/ENABLE.md \
           .claude/skills/project-review/SKILL.md .githooks/pre-commit; do
    [ -e "$REPO_ROOT/project-factory/templates/_common/$f" ]
  done
  # and the skill names the commands it relies on
  grep -q 'cut-project.sh --generic' "$SKILL/SKILL.md"
  grep -q 'deploy.py --list' "$SKILL/sections/grid-extras.md"
  grep -q 'deploy_hooks.py' "$SKILL/sections/grid-extras.md"
  grep -q 'python3 scripts/map.py --check' "$SKILL/SKILL.md"
}

@test "project-bootstrap: the skill states the no-invention rule and the unknown marker" {
  grep -q 'never invent a fact' "$SKILL/SKILL.md"
  grep -q '<unknown: ask the operator>' "$SKILL/SKILL.md"
}
