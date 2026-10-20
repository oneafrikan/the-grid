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

# --- MAP.md at cut time (5.1, 5.3) -------------------------------------------------------------
# stub_python — put a recording python3 first on PATH; it logs its arguments and runs nothing.
stub_python() {
  STUB=$(mktemp -d)
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/python3.calls"\nexit 0\n' "$STUB" > "$STUB/python3"
  chmod +x "$STUB/python3"
}

@test "a fresh seed has a current MAP.md: map.py --check run in the target exits 0" {
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ -f "$P/MAP.md" ]
  [[ "$output" == *"wrote:     MAP.md"* ]] || false
  run python3 "$P/scripts/map.py" --check
  [ "$status" -eq 0 ]
  grep -q '`PURPOSE.md`' "$P/MAP.md"
}

@test "an existing MAP.md is left byte-identical and map.py is not run" {
  stub_python
  echo "my own map" > "$P/MAP.md"
  run env PATH="$STUB:$PATH" bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$P/MAP.md")" = "my own map" ]
  [ ! -e "$STUB/python3.calls" ]
  rm -rf "$STUB"
}

@test "with python3 hidden the cut still exits 0, writes no MAP.md and prints the regenerate command" {
  NOPY="$(path_without 'python3*' python python2*)"
  run env PATH="$NOPY" bash "$CUT" python-agents-base "$P"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$P/MAP.md" ]
  [[ "$output" == *"run: python3 scripts/map.py"* ]] || false
}

@test "a project with its own, different scripts/map.py is not run and gets no MAP.md" {
  stub_python
  mkdir -p "$P/scripts"
  echo "# mine" > "$P/scripts/map.py"
  run env PATH="$STUB:$PATH" bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ ! -e "$P/MAP.md" ]
  [ ! -e "$STUB/python3.calls" ]
  [[ "$output" == *"SKIPPED (exists, differs — review manually): scripts/map.py"* ]] || false
  # the retrofit says how to generate the map by hand
  [[ "$output" == *"MAP.md not generated; run: python3 scripts/map.py"* ]] || false
  rm -rf "$STUB"
}

@test "a second cut leaves MAP.md alone (it existed) and writes nothing" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  cp "$P/MAP.md" "$BATS_TEST_TMPDIR/map1"
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) written"* ]] || false
  cmp "$P/MAP.md" "$BATS_TEST_TMPDIR/map1"
}

# --- git hooks path (5.1b) ---------------------------------------------------------------------
@test "a seed cut points core.hooksPath at .githooks" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  [ "$(git -C "$P" config core.hooksPath)" = ".githooks" ]
}

@test "a seeded project refuses a commit when MAP.md is stale, naming the fix" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  git -C "$P" config user.email t@t
  git -C "$P" config user.name t
  git -C "$P" add -A
  git -C "$P" commit -q -m seed
  # a new registry file (RELATED.md) makes the committed MAP.md stale
  echo x > "$P/RELATED.md"
  git -C "$P" add -A
  run git -C "$P" commit -q -m stale
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"run: python3 scripts/map.py"* ]] || false
}

@test "a retrofit never touches git config and prints the one-line command instead" {
  git -C "$P" init -q
  echo "keep" > "$P/README.md"
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$P" config --local --get core.hooksPath || true)" ]
  [[ "$output" == *"git config core.hooksPath .githooks"* ]] || false
}

# --- trailhead for a retrofit (5.2) ------------------------------------------------------------
@test "a retrofit with its own CLAUDE.md leaves it unchanged and prints the trailhead block" {
  printf '# Mine\nmy conventions\n' > "$P/CLAUDE.md"
  cp "$P/CLAUDE.md" "$BATS_TEST_TMPDIR/claude.before"
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  cmp "$P/CLAUDE.md" "$BATS_TEST_TMPDIR/claude.before"
  [[ "$output" == *"<!-- charter-trailhead -->"* ]] || false
  [[ "$output" == *"Session start: read \`PURPOSE.md\` and \`MAP.md\`."* ]] || false
  [[ "$output" == *"paste"* ]] || false
}

@test "no trailhead notice in a seed, and none for a CLAUDE.md that already has the marker" {
  run bash "$CUT" python-agents-base "$P"
  [[ "$output" != *"paste at the top"* ]] || false
  run bash "$CUT" python-agents-base "$P"
  [[ "$output" != *"paste at the top"* ]] || false
}

@test "cut-project.sh never edits a CLAUDE.md, even one without the marker" {
  printf '# Mine\n' > "$P/CLAUDE.md"
  bash "$CUT" python-agents-base "$P" >/dev/null
  [ "$(cat "$P/CLAUDE.md")" = "# Mine" ]
}

# --- optional RELATED.md (5.1c) ------------------------------------------------------------------
@test "--with-related copies related.md as RELATED.md, with the flag before, between or after the positionals" {
  for pos in 1 2 3; do
    d=$(mktemp -d)
    case "$pos" in
      1) bash "$CUT" --with-related python-agents-base "$d" >/dev/null ;;
      2) bash "$CUT" python-agents-base --with-related "$d" >/dev/null ;;
      3) bash "$CUT" python-agents-base "$d" --with-related >/dev/null ;;
    esac
    cmp "$d/RELATED.md" "$REPO_ROOT/project-factory/related.md" || { echo "position $pos differs"; rm -rf "$d"; return 1; }
    grep -qi 'same or greater privacy' "$d/RELATED.md"
    rm -rf "$d"
  done
}

@test "--with-related: the map then lists RELATED.md with its read-when text" {
  bash "$CUT" --with-related python-agents-base "$P" >/dev/null
  grep '^| `RELATED.md` |' "$P/MAP.md" | grep -q 'before building a new capability or adding a dependency'
  run python3 "$P/scripts/map.py" --check
  [ "$status" -eq 0 ]
}

@test "--with-related never overwrites a differing RELATED.md and reports it SKIPPED" {
  echo "mine" > "$P/RELATED.md"
  run bash "$CUT" python-agents-base "$P" --with-related
  [ "$status" -eq 0 ]
  [ "$(cat "$P/RELATED.md")" = "mine" ]
  [[ "$output" == *"SKIPPED (exists, differs — review manually): RELATED.md"* ]] || false
}

@test "--with-related twice writes 0 files the second time" {
  bash "$CUT" --with-related python-agents-base "$P" >/dev/null
  run bash "$CUT" --with-related python-agents-base "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) written"* ]] || false
}

@test "--with-related with only one positional still prints usage and exits 1" {
  run bash "$CUT" --with-related python-agents-base
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]] || false
}

@test "usage documents --with-related" {
  run bash "$CUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--with-related"* ]] || false
}

# ---- the issue-loop seed (opt-in, off by default) ----

@test "the loop seed lands, ENABLE.md lands, and the runner does not exist (the loop stays off)" {
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ -f "$P/loop/loop.conf.seed" ]
  [ -f "$P/loop/ENABLE.md" ]
  [ ! -e "$P/loop/run-issue.sh" ]
  [ ! -e "$P/loop/loop.conf" ]
  [ ! -e "$P/prompts/autonomous-coding-loop.template.md" ]
}

@test "ENABLE.md is at most 40 lines and names VERIFY_CMD, the PR-only rule and the instantiate command" {
  f="$REPO_ROOT/project-factory/templates/_common/loop/ENABLE.md"
  [ "$(wc -l < "$f")" -le 40 ]
  grep -q 'VERIFY_CMD' "$f"
  grep -qi 'opt-in' "$f"
  grep -q 'refuses to run' "$f"
  grep -q 'never merges' "$f"
  grep -q 'instantiate.sh issue-loop . --profile work' "$f"
}

@test "the seed sources cleanly and carries every loop.conf key, in step with the pattern's template" {
  seed="$REPO_ROOT/project-factory/templates/_common/loop/loop.conf.seed"
  tpl="$REPO_ROOT/automation-factory/patterns/issue-loop/loop.conf.template"
  ( . "$seed" )
  for k in $(grep -oE '^[A-Z_]+=' "$tpl" | tr -d '='); do
    grep -q "^$k=" "$seed" || { echo "seed lacks $k"; return 1; }
  done
  # the seed is a seed: it does not default the one value the loop needs
  grep -q "^VERIFY_CMD=''" "$seed"
  grep -q "^MODE='pr'" "$seed"
}

@test "a retrofit with a different loop seed skips it and reports it" {
  mkdir -p "$P/loop"
  echo "VERIFY_CMD='make check'" > "$P/loop/loop.conf.seed"
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$P/loop/loop.conf.seed")" = "VERIFY_CMD='make check'" ]
  [[ "$output" == *"SKIPPED"*"loop/loop.conf.seed"* ]] || false
}

@test "a second cut leaves the seed unchanged and writes nothing new" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [[ "$output" != *"wrote:"* ]] || false
}

@test "no template doc points at the old pairing prompt or a literal {{VERIFY_CMD}}" {
  cd "$REPO_ROOT/project-factory"
  for f in README.md templates/lamp-agents-base/README.md templates/lamp-agents-base/CLAUDE.md \
           templates/python-agents-base/CLAUDE.md templates/python-astro-content-agent/CLAUDE.md \
           templates/finance-agents-base/README.md templates/finance-agents-base/CLAUDE.md \
           scripts/cut-project.sh; do
    if grep -q 'autonomous-coding-loop' "$f"; then echo "$f still names the old prompt"; return 1; fi
    if grep -q '{{VERIFY_CMD}}' "$f"; then echo "$f still has a literal placeholder"; return 1; fi
  done
}

@test "the templates keep their own verify command and say the loop is opt-in" {
  cd "$REPO_ROOT/project-factory"
  grep -q 'pytest' templates/python-agents-base/CLAUDE.md
  grep -q 'phpunit' templates/lamp-agents-base/CLAUDE.md
  grep -q 'worktree-setup.sh' templates/lamp-agents-base/CLAUDE.md
  grep -q 'loop/ENABLE.md' templates/python-agents-base/CLAUDE.md
  grep -qi 'opt-in' README.md
  grep -q 'refuses to run' README.md
  # nothing claims every project grinds its backlog unattended
  if grep -rniE 'unattended|grinding it|grind through' README.md templates/*/README.md templates/*/CLAUDE.md; then return 1; fi
}
