#!/usr/bin/env bats
# Charter files (change `charter-files`): the files every grid project carries so a cold agent
# knows what the project is for, what it must not do and where to look next.
#
# Sections (appended group by group):
#   the-grid half   PURPOSE/GUARDRAILS/BEHAVIOUR, signals/knowledge READMEs, trailhead
# Cuts and scans only ever happen in temp dirs.

load helpers/setup

setup() {
  common_setup
  T=$(mktemp -d)
}

teardown() {
  rm -rf "$T"
  common_teardown
}

# stage_names — the six stage names, one per line.
stage_names() { printf '%s\n' wip provisional established canonical superseded retired; }

# --- PURPOSE.md ------------------------------------------------------------------------
@test "the-grid PURPOSE.md: exactly the three headings in order, a GUARDRAILS link, no guardrail entries, <= 40 lines" {
  f="$REPO_ROOT/PURPOSE.md"
  [ -f "$f" ]
  [ "$(grep -c '^## ' "$f")" -eq 3 ]
  [ "$(grep '^## ' "$f" | paste -sd'|')" = "## Problem|## Intended solution|## Outcome" ]
  grep -qxF 'Must-nots: see [GUARDRAILS.md](GUARDRAILS.md).' "$f"
  ! grep -Eq '^- G[0-9]+:' "$f" || false
  [ "$(wc -l < "$f")" -le 40 ]
}

# --- GUARDRAILS.md ---------------------------------------------------------------------
@test "the-grid GUARDRAILS.md: every '- G' line parses and no ID repeats" {
  f="$REPO_ROOT/GUARDRAILS.md"
  [ -f "$f" ]
  [ "$(grep -c '^- G' "$f")" -ge 1 ]
  bad=$(grep '^- G' "$f" | grep -Ev '^- G[0-9]+: .+ \[check: (human|CI|hook|none)(: .+)?\]$|^- G[0-9]+: \(retired\)$' || true)
  echo "bad lines: $bad"
  [ -z "$bad" ]
  ids=$(grep -o '^- G[0-9]*' "$f")
  [ "$(printf '%s\n' "$ids" | sort | uniq -d | wc -l)" -eq 0 ]
}

@test "the-grid GUARDRAILS.md: every CI or hook check names a script or hook that exists" {
  f="$REPO_ROOT/GUARDRAILS.md"
  n=0
  while IFS= read -r line; do
    case "$line" in *"[check: CI"*|*"[check: hook"*) ;; *) continue ;; esac
    paths=$(printf '%s\n' "$line" | grep -oE '(scripts|hooks)/[A-Za-z0-9_./-]+' || true)
    # a CI or hook check with no path named is itself a defect: it cannot be verified
    [ -n "$paths" ] || { echo "no path named: $line"; return 1; }
    for p in $paths; do
      [ -e "$REPO_ROOT/$p" ] || { echo "missing: $p (in: $line)"; return 1; }
      n=$((n + 1))
    done
  done < <(grep '^- G' "$f")
  [ "$n" -ge 3 ]
}

@test "the-grid GUARDRAILS.md: the secret-scan hook is not claimed as on by default" {
  # the hook is min_profile standard and the-grid has no .grid/project.yaml enabling it
  line=$(grep '^- G[0-9]*:.*secret' "$REPO_ROOT/GUARDRAILS.md")
  [[ "$line" == *"opt-in"* ]] || false
}

# --- BEHAVIOUR.md ----------------------------------------------------------------------
@test "the-grid BEHAVIOUR.md: opens with the additions-only line and does not restate the stage vocabulary" {
  f="$REPO_ROOT/BEHAVIOUR.md"
  [ -f "$f" ]
  first=$(grep -m1 . "$f")
  [[ "$first" == *"agent-factory/_core/AGENTS_base.md"* ]] || false
  [[ "$first" == *"additions only"* ]] || false
  hits=0
  for s in $(stage_names); do grep -qw "$s" "$f" && hits=$((hits + 1)); done
  [ "$hits" -lt 6 ]
  ! grep -q 'never promoted' "$f" || false
}

# --- signals/ and knowledge/ READMEs -----------------------------------------------------
@test "the-grid signals/README.md: layout, handoffs distinguished, honest sweep status, no secrets, own repo only" {
  f="$REPO_ROOT/signals/README.md"
  [ -f "$f" ]
  grep -q 'signals/done/' "$f"
  grep -q '→' "$f"
  grep -qi 'handoff' "$f"
  grep -qi 'not knowledge signals' "$f"
  grep -qi 'no sweep runs' "$f"
  grep -qi 'not processed' "$f"
  grep -qi 'no secrets' "$f"
  grep -qi 'own repo' "$f"
  grep -qi 'about the grid only' "$f"
}

@test "the-grid signals/README.md: restates all six stages and the warrant rule in <= 25 lines" {
  f="$REPO_ROOT/signals/README.md"
  sec=$(awk '/^## Evidence and stages/ {on=1; next} /^## / {on=0} on' "$f")
  [ -n "$sec" ]
  [ "$(printf '%s\n' "$sec" | wc -l)" -le 25 ]
  for s in $(stage_names); do printf '%s\n' "$sec" | grep -qw "$s"; done
  printf '%s\n' "$sec" | grep -qF '`wip` is never promoted'
}

@test "the-grid knowledge/README.md: layout, the two keys map.py reads, own repo, sweep status" {
  f="$REPO_ROOT/knowledge/README.md"
  [ -f "$f" ]
  [ -f "$REPO_ROOT/knowledge/canon/.gitkeep" ]
  grep -q 'knowledge/canon/' "$f"
  grep -q '`stage`' "$f"
  grep -q '`claim`' "$f"
  grep -q 'scripts/map.py' "$f"
  grep -qi 'own repo' "$f"
  grep -qi 'no sweep runs' "$f"
}

# --- the trailhead block ---------------------------------------------------------------
# extract_trailhead <file> — the marker-delimited block, markers included.
extract_trailhead() { sed -n '/^<!-- charter-trailhead -->$/,/^<!-- \/charter-trailhead -->$/p' "$1"; }

@test "trailhead.md holds the block and tells the reader what to read when" {
  f="$REPO_ROOT/project-factory/trailhead.md"
  [ -f "$f" ]
  [ "$(head -n 1 "$f")" = "<!-- charter-trailhead -->" ]
  [ "$(tail -n 1 "$f")" = "<!-- /charter-trailhead -->" ]
  grep -q 'Session start: read `PURPOSE.md` and `MAP.md`' "$f"
  grep -q 'read `GUARDRAILS.md`' "$f"
  grep -q 'read `signals/README.md`' "$f"
  # RELATED.md: only before building something new, never at session start
  line=$(grep 'RELATED.md' "$f")
  [[ "$line" == "- Before building a new capability or adding a dependency:"* ]] || false
  ! grep 'Session start' "$f" | grep -q 'RELATED' || false
}

@test "the-grid CLAUDE.md carries the trailhead at the very top, byte-identical to trailhead.md" {
  [ "$(head -n 1 "$REPO_ROOT/CLAUDE.md")" = "<!-- charter-trailhead -->" ]
  extract_trailhead "$REPO_ROOT/CLAUDE.md" > "$T/block"
  cmp "$T/block" "$REPO_ROOT/project-factory/trailhead.md"
  # exactly one block
  [ "$(grep -c '^<!-- charter-trailhead -->$' "$REPO_ROOT/CLAUDE.md")" -eq 1 ]
}

# --- MAP.md (dogfood) ------------------------------------------------------------------
@test "the-grid MAP.md lists the charter files and directories and is current" {
  for p in 'PURPOSE.md' 'GUARDRAILS.md' 'BEHAVIOUR.md' 'signals/' 'knowledge/'; do
    grep -qF "| \`$p\` |" "$REPO_ROOT/MAP.md" || { echo "no row: $p"; return 1; }
  done
  run python3 "$REPO_ROOT/scripts/map.py" --check
  [ "$status" -eq 0 ]
}

@test "the-grid has no RELATED.md (opt-in, not seeded for the grid itself)" {
  [ ! -e "$REPO_ROOT/RELATED.md" ]
}

# --- personal data ---------------------------------------------------------------------
@test "check-personal.sh finds nothing in the new charter files" {
  # The scan reads TRACKED files only, so scan a throwaway repo holding copies of them and the
  # real rule files. GRID_PRIVATE_DENYLIST= disables the private half on purpose (as CI does).
  R="$T/repo"
  mkdir -p "$R/scripts"
  git -C "$R" init -q
  cp "$REPO_ROOT"/scripts/personal-patterns.txt "$REPO_ROOT"/scripts/personal-allow-paths.txt \
     "$REPO_ROOT"/scripts/personal-denylist.example.txt "$R/scripts/"
  for p in PURPOSE.md GUARDRAILS.md BEHAVIOUR.md MAP.md CLAUDE.md signals/README.md knowledge/README.md \
           project-factory/trailhead.md; do
    mkdir -p "$R/$(dirname "$p")"
    cp "$REPO_ROOT/$p" "$R/$p"
  done
  git -C "$R" add -A
  run env GRID_DIR="$R" GRID_PRIVATE_DENYLIST= HOME="$T/home" bash "$REPO_ROOT/scripts/check-personal.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

# =========================================================================================
# vocabulary half: agent-factory/_core/AGENTS_base.md (spec agent-boot-vocabulary)
# =========================================================================================
BASE="agent-factory/_core/AGENTS_base.md"

# base_section <heading text> — the body of one `## ` section of AGENTS_base.md (heading excluded).
base_section() { awk -v h="## $1" '$0 == h {on=1; next} /^## / {on=0} on' "$REPO_ROOT/$BASE"; }

@test "AGENTS_base: Evidence and Stages names all six stages, RAN/READ/UNTESTED and the wip rule" {
  sec=$(base_section "Evidence and Stages")
  [ -n "$sec" ]
  for s in $(stage_names); do printf '%s\n' "$sec" | grep -qF "\`$s\`" || { echo "missing $s"; return 1; }; done
  for w in RAN READ UNTESTED; do printf '%s\n' "$sec" | grep -qw "$w"; done
  printf '%s\n' "$sec" | grep -qF '`wip` is never promoted'
  printf '%s\n' "$sec" | grep -q 'is always decided by a human'
  printf '%s\n' "$sec" | grep -q 'not stages'
}

@test "AGENTS_base: Memory names the always-in-context and on-demand sets" {
  sec=$(base_section "Memory")
  for w in 'LEARNINGS.md' 'knowledge/' 'instincts' 'learning: on' 'MAP.md' 'never present unread'; do
    printf '%s\n' "$sec" | grep -qF "$w" || { echo "missing: $w"; return 1; }
  done
}

@test "AGENTS_base: the filing section applies only if signals/README.md exists and keeps handoffs separate" {
  first=$(base_section "Filing a Knowledge Signal" | grep -m1 .)
  [[ "$first" == *"signals/README.md"* ]] || false
  base_section "Filing a Knowledge Signal" | grep -qF 'signals/→<agent>.md'
}

@test "AGENTS_base: the added block is exactly 1670 bytes and the file exactly 4578" {
  n=$(sed -n '/^## Evidence and Stages/,/^## Signal Protocol (handoff)/p' "$REPO_ROOT/$BASE" | sed '$d' | sed '$d' | wc -c)
  echo "block=$n"
  [ "$n" -eq 1670 ]
  [ "$n" -le 2000 ]
  [ "$(wc -c < "$REPO_ROOT/$BASE")" -eq 4578 ]
}

@test "AGENTS_base: the block sits between the OpenSpec section and the handoff section" {
  a=$(grep -n '^## Spec-Driven Repos' "$REPO_ROOT/$BASE" | cut -d: -f1)
  b=$(grep -n '^## Evidence and Stages' "$REPO_ROOT/$BASE" | cut -d: -f1)
  c=$(grep -n '^## Signal Protocol (handoff)' "$REPO_ROOT/$BASE" | cut -d: -f1)
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
}

@test "AGENTS_base: the three new headings appear in no role AGENTS.md (merge would unify them)" {
  run bash -c "grep -l '^## \(Evidence and Stages\|Memory\|Filing a Knowledge Signal\)' '$REPO_ROOT'/agent-factory/roles/*/AGENTS.md"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "AGENTS_base: the handoff section is byte-identical to origin/main (skipped without that ref)" {
  git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null || skip "origin/main absent"
  git -C "$REPO_ROOT" show "origin/main:$BASE" > "$T/old"
  sect() { sed -n '/^## Signal Protocol (handoff)$/,/^## Scope$/p' "$1" | sed '$d'; }
  sect "$T/old" > "$T/old.sect"
  sect "$REPO_ROOT/$BASE" > "$T/new.sect"
  [ -s "$T/old.sect" ]
  cmp "$T/old.sect" "$T/new.sect"
}

@test "AGENTS_base: the change adds lines only (nothing in the old text is edited or removed)" {
  git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null || skip "origin/main absent"
  run git -C "$REPO_ROOT" diff -U0 origin/main -- "$BASE"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E '^-[^-]' || false
}

@test "no compose.py and no role file is modified by this change (skipped without origin/main)" {
  git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null || skip "origin/main absent"
  run git -C "$REPO_ROOT" diff --name-only origin/main
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E '(^|/)compose\.py$' || false
  ! printf '%s\n' "$output" | grep -E '^agent-factory/roles/' || false
}

# =========================================================================================
# template half: project-factory/templates/_common (spec project-charter-files)
# =========================================================================================
COMMON="project-factory/templates/_common"
TEMPLATES="finance-agents-base lamp-agents-base python-agents-base python-astro-content-agent"

@test "template PURPOSE.md: three headings in order, a GUARDRAILS link, <fill markers, no guardrail entries, <= 40 lines" {
  f="$REPO_ROOT/$COMMON/PURPOSE.md"
  [ -f "$f" ]
  [ "$(grep '^## ' "$f" | paste -sd'|')" = "## Problem|## Intended solution|## Outcome" ]
  grep -qxF 'Must-nots: see [GUARDRAILS.md](GUARDRAILS.md).' "$f"
  grep -q '<fill' "$f"
  ! grep -Eq '^- G[0-9]+:' "$f" || false
  [ "$(wc -l < "$f")" -le 40 ]
}

@test "template GUARDRAILS.md: states the format, carries no active entry, example is commented out" {
  f="$REPO_ROOT/$COMMON/GUARDRAILS.md"
  [ -f "$f" ]
  ! grep -Eq '^- G[0-9]+:' "$f" || false
  grep -q '\[check: human|CI|hook|none\]' "$f"
  grep -q '<fill' "$f"
  grep -Eq '^<!-- - G1: ' "$f"
}

@test "template BEHAVIOUR.md: additions-only opening line, empty body, no stage vocabulary" {
  f="$REPO_ROOT/$COMMON/BEHAVIOUR.md"
  first=$(grep -m1 . "$f")
  [[ "$first" == *"agent-factory/_core/AGENTS_base.md"* ]] || false
  [[ "$first" == *"additions only"* ]] || false
  grep -qxF '(none yet)' "$f"
  ! grep -q 'never promoted' "$f" || false
}

@test "template signals/README.md and knowledge/README.md: own-repo wording, honest sweep status, restated vocabulary" {
  s="$REPO_ROOT/$COMMON/signals/README.md"
  k="$REPO_ROOT/$COMMON/knowledge/README.md"
  [ -f "$s" ]
  [ -f "$k" ]
  [ -f "$REPO_ROOT/$COMMON/knowledge/canon/.gitkeep" ]
  for f in "$s" "$k"; do
    grep -qi 'own repo' "$f"
    grep -qi 'no sweep runs' "$f"
    grep -qi 'no secrets' "$f"
  done
  grep -q '→' "$s"
  grep -qi 'not knowledge signals' "$s"
  sec=$(awk '/^## Evidence and stages/ {on=1; next} /^## / {on=0} on' "$s")
  [ "$(printf '%s\n' "$sec" | wc -l)" -le 25 ]
  for st in $(stage_names); do printf '%s\n' "$sec" | grep -qw "$st"; done
  printf '%s\n' "$sec" | grep -qF '`wip` is never promoted'
  grep -q '`stage`' "$k" && grep -q '`claim`' "$k"
}

@test "MAP.md is NOT shipped in _common (cut-project.sh generates it) and no CI workflow is seeded" {
  [ ! -e "$REPO_ROOT/$COMMON/MAP.md" ]
  [ ! -e "$REPO_ROOT/$COMMON/.github" ]
}

@test "scripts/map.py and the _common mirror are byte-identical" {
  cmp "$REPO_ROOT/scripts/map.py" "$REPO_ROOT/$COMMON/scripts/map.py"
}

@test "the trailhead block is byte-identical in the four template CLAUDE.md files and at the top of each" {
  for t in $TEMPLATES; do
    f="$REPO_ROOT/project-factory/templates/$t/CLAUDE.md"
    extract_trailhead "$f" > "$T/block"
    cmp "$T/block" "$REPO_ROOT/project-factory/trailhead.md" || { echo "differs: $t"; return 1; }
    [ "$(head -n 1 "$f")" = "<!-- charter-trailhead -->" ] || { echo "not at top: $t"; return 1; }
    [ "$(grep -c '^<!-- charter-trailhead -->$' "$f")" -eq 1 ]
  done
}

@test "no template and not _common ships a RELATED.md (it is opt-in)" {
  [ ! -e "$REPO_ROOT/$COMMON/RELATED.md" ]
  for t in $TEMPLATES; do [ ! -e "$REPO_ROOT/project-factory/templates/$t/RELATED.md" ]; done
}

@test "related.md template: header sentences, six entry fields, <= 25 lines, outside templates/" {
  f="$REPO_ROOT/project-factory/related.md"
  [ -f "$f" ]
  [ "$(wc -l < "$f")" -le 25 ]
  grep -qi 'not exhaustive' "$f"
  grep -qi 'search' "$f"
  grep -qi 'same or greater privacy' "$f"
  grep -qi 'signal' "$f"
  grep -qi 'issue' "$f"
  grep -qi 'never push' "$f"
  for key in 'repo:' 'owns:' 'provides to us / we provide to it:' "don't build here:" 'reach:' 'verified: YYYY-MM-DD'; do
    grep -qF -- "- $key" "$f" || { echo "missing field: $key"; return 1; }
  done
}

# mk_proj — a fixture project with the seeded map.py and a current MAP.md; sets $P.
mk_proj() {
  P="$T/proj"
  mkdir -p "$P/scripts" "$P/.githooks"
  cp "$REPO_ROOT/$COMMON/scripts/map.py" "$P/scripts/map.py"
  cp "$REPO_ROOT/$COMMON/.githooks/pre-commit" "$P/.githooks/pre-commit"
  echo x > "$P/PURPOSE.md"
  python3 "$P/scripts/map.py" --root "$P"
}

@test "pre-commit shim is executable and shellcheck-clean" {
  [ -x "$REPO_ROOT/$COMMON/.githooks/pre-commit" ]
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  shellcheck -S warning "$REPO_ROOT/$COMMON/.githooks/pre-commit"
}

@test "pre-commit shim: a current map passes (0)" {
  mk_proj
  run bash -c "cd '$P' && .githooks/pre-commit"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "pre-commit shim: a stale map is refused (1) with the regenerate command" {
  mk_proj
  echo x > "$P/CONTEXT.md"
  run bash -c "cd '$P' && .githooks/pre-commit"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run: python3 scripts/map.py"* ]] || false
}

@test "pre-commit shim: with python3 hidden it exits 0 with a skip notice" {
  mk_proj
  echo x > "$P/CONTEXT.md"
  NOPY="$(path_without 'python3*' python python2*)"
  run env PATH="$NOPY" bash -c "cd '$P' && .githooks/pre-commit"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || false
}

@test "pre-commit shim: it works when invoked from another directory (git runs hooks from the top level, but be safe)" {
  mk_proj
  run bash -c "cd / && '$P/.githooks/pre-commit'"
  [ "$status" -eq 0 ]
}

@test "check-personal.sh finds nothing in the template charter files" {
  R="$T/repo"
  mkdir -p "$R/scripts"
  git -C "$R" init -q
  cp "$REPO_ROOT"/scripts/personal-patterns.txt "$REPO_ROOT"/scripts/personal-allow-paths.txt \
     "$REPO_ROOT"/scripts/personal-denylist.example.txt "$R/scripts/"
  for p in "$COMMON/PURPOSE.md" "$COMMON/GUARDRAILS.md" "$COMMON/BEHAVIOUR.md" "$COMMON/signals/README.md" \
           "$COMMON/knowledge/README.md" "$COMMON/.githooks/pre-commit" project-factory/related.md; do
    mkdir -p "$R/$(dirname "$p")"
    cp "$REPO_ROOT/$p" "$R/$p"
  done
  git -C "$R" add -A
  run env GRID_DIR="$R" GRID_PRIVATE_DENYLIST= HOME="$T/home" bash "$REPO_ROOT/scripts/check-personal.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "signals/README.md and AGENTS_base.md agree on the six stage names and the wip sentence" {
  base_section "Evidence and Stages" > "$T/a"
  awk '/^## Evidence and stages/ {on=1; next} /^## / {on=0} on' "$REPO_ROOT/signals/README.md" > "$T/b"
  for s in $(stage_names); do
    grep -qF "\`$s\`" "$T/a" && grep -qF "\`$s\`" "$T/b" || { echo "disagree on $s"; return 1; }
  done
  grep -qF '`wip` is never promoted' "$T/a"
  grep -qF '`wip` is never promoted' "$T/b"
}
