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
