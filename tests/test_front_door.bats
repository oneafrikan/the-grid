#!/usr/bin/env bats
# Front-door docs (INSTALL.md, CONTRIBUTING.md): they exist, carry their heading, link only to
# paths that exist, hold no personal data or typed counts, and still contain the phrases that
# were moved out of README.md/BOOTSTRAP.md (openspec change front-door, tasks 2.5 and 2.6a).
# Later issues append cases to this file: add the doc to NEW_DOCS or write a new @test, and
# reuse the helpers below.
#
# Read-only: the files come from the repo root; nothing here touches the real ~/.claude.

# Pin the locale so grep behaves the same on every machine (the docs hold non-ASCII text).
export LC_ALL=C

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# The docs this slice of the change adds. Group 2's later issues extend this list.
NEW_DOCS="INSTALL.md CONTRIBUTING.md docs/architecture.md"

# Helper: phrase_in <file> <fixed phrase>. One grep per phrase-map row.
phrase_in() {
  grep -qF -- "$2" "$GRID_ROOT/$1" || { echo "$1 is missing the phrase: $2" >&2; return 1; }
}

# Helper: relative_links <file> — the target of every relative markdown link, one per line,
# fragment stripped. Skips http(s), mailto and pure-anchor links.
relative_links() {
  grep -oE '\]\([^)[:space:]]+\)' "$GRID_ROOT/$1" \
    | sed -e 's/^](//' -e 's/)$//' \
    | grep -vE '^(https?:|mailto:|#)' \
    | sed -e 's/#.*$//' \
    | sort -u
}

@test "front door: each new doc exists" {
  for f in $NEW_DOCS; do
    [ -f "$GRID_ROOT/$f" ] || { echo "missing: $f" >&2; return 1; }
  done
}

@test "front door: INSTALL.md starts with '# Install'" {
  [ "$(head -n 1 "$GRID_ROOT/INSTALL.md")" = "# Install" ]
}

@test "front door: CONTRIBUTING.md starts with '# Contributing'" {
  [ "$(head -n 1 "$GRID_ROOT/CONTRIBUTING.md")" = "# Contributing" ]
}

@test "front door: docs/architecture.md starts with '# Architecture'" {
  [ "$(head -n 1 "$GRID_ROOT/docs/architecture.md")" = "# Architecture" ]
}

@test "front door: INSTALL.md is at most 90 lines" {
  [ "$(wc -l < "$GRID_ROOT/INSTALL.md")" -le 90 ]
}

@test "front door: every relative markdown link resolves" {
  for f in $NEW_DOCS; do
    links="$(relative_links "$f")"
    # A link resolves from the directory of the file that holds it (docs/ for docs/*.md).
    base="$(dirname "$f")"
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      [ -e "$GRID_ROOT/$base/$target" ] || { echo "$f: broken link: $target" >&2; return 1; }
    done <<< "$links"
  done
}

@test "front door: no placeholder user name, macOS home path or possessive author name" {
  # The author's first name is assembled from parts so this test file does not itself hold it.
  possessive="Gar""eth's"
  for f in $NEW_DOCS; do
    ! grep -qF -- '<your-username>' "$GRID_ROOT/$f" || { echo "$f: <your-username>" >&2; return 1; }
    ! grep -qF -- '/Users/' "$GRID_ROOT/$f" || { echo "$f: /Users/" >&2; return 1; }
    ! grep -qF -- "$possessive" "$GRID_ROOT/$f" || { echo "$f: possessive author name" >&2; return 1; }
  done
}

@test "front door: no typed counts like '38 roles'" {
  # Counts are generated (see SKILLS.md), never typed into prose.
  for f in $NEW_DOCS; do
    ! grep -qE '[0-9]{2,4} (skills|agents|roles)' "$GRID_ROOT/$f" || { echo "$f: typed count" >&2; return 1; }
  done
}

@test "front door: INSTALL.md keeps 'reconcile.sh --force'" {
  phrase_in INSTALL.md 'reconcile.sh --force'
}

@test "front door: INSTALL.md names python3-venv" {
  phrase_in INSTALL.md 'python3-venv'
}

@test "front door: INSTALL.md keeps the manual submodule step" {
  phrase_in INSTALL.md 'git submodule update --init --recursive'
}

@test "front door: CONTRIBUTING.md keeps 'Adding a skill directly'" {
  phrase_in CONTRIBUTING.md 'Adding a skill directly'
}

@test "front door: CONTRIBUTING.md keeps 'Running tests'" {
  phrase_in CONTRIBUTING.md 'Running tests'
}

@test "front door: CONTRIBUTING.md keeps the OpenSpec section (spec-scout)" {
  phrase_in CONTRIBUTING.md 'spec-scout'
}

@test "front door: CONTRIBUTING.md keeps the OpenSpec section (AGENTS_base.md)" {
  phrase_in CONTRIBUTING.md 'AGENTS_base.md'
}

@test "front door: CONTRIBUTING.md keeps 'git submodule add'" {
  phrase_in CONTRIBUTING.md 'git submodule add'
}

@test "front door: CONTRIBUTING.md keeps 'Checking grid health'" {
  phrase_in CONTRIBUTING.md 'Checking grid health'
}

@test "front door: CONTRIBUTING.md names main and the gate command" {
  grep -qw 'main' "$GRID_ROOT/CONTRIBUTING.md"
  phrase_in CONTRIBUTING.md 'bash scripts/gate.sh'
}

@test "front door: docs/architecture.md keeps 'How wire.sh works'" {
  phrase_in docs/architecture.md 'How wire.sh works'
}

@test "front door: docs/architecture.md keeps the wire.sh env override example" {
  phrase_in docs/architecture.md 'GRID_DIR='
}

@test "front door: docs/architecture.md keeps the factories table (automation-factory)" {
  phrase_in docs/architecture.md 'automation-factory'
}

@test "front door: CONTRIBUTING.md does not name the retired next branch" {
  ! grep -qw 'next' "$GRID_ROOT/CONTRIBUTING.md" || false
}

# Roadmap and private-projects split (openspec change front-door, task 2.4).
SPLIT_DOCS="docs/roadmap.md docs/private-projects.md"

@test "front door: roadmap and private-projects docs exist" {
  for f in $SPLIT_DOCS; do
    [ -f "$GRID_ROOT/$f" ] || { echo "missing: $f" >&2; return 1; }
  done
}

@test "front door: docs/roadmap.md starts with '# Roadmap'" {
  [ "$(head -n 1 "$GRID_ROOT/docs/roadmap.md")" = "# Roadmap" ]
}

@test "front door: docs/private-projects.md starts with '# Private projects'" {
  [ "$(head -n 1 "$GRID_ROOT/docs/private-projects.md")" = "# Private projects" ]
}

@test "front door: roadmap and private-projects relative links resolve" {
  for f in $SPLIT_DOCS; do
    links="$(relative_links "$f")"
    base="$(dirname "$f")"
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      [ -e "$GRID_ROOT/$base/$target" ] || { echo "$f: broken link: $target" >&2; return 1; }
    done <<< "$links"
  done
}

@test "front door: roadmap and private-projects hold no placeholder user, home path or author name" {
  possessive="Gar""eth's"
  for f in $SPLIT_DOCS; do
    ! grep -qF -- '<your-username>' "$GRID_ROOT/$f" || { echo "$f: <your-username>" >&2; return 1; }
    ! grep -qF -- '/Users/' "$GRID_ROOT/$f" || { echo "$f: /Users/" >&2; return 1; }
    ! grep -qF -- "$possessive" "$GRID_ROOT/$f" || { echo "$f: possessive author name" >&2; return 1; }
  done
}

@test "front door: roadmap and private-projects hold no typed counts" {
  for f in $SPLIT_DOCS; do
    ! grep -qE '[0-9]{2,4} (skills|agents|roles)' "$GRID_ROOT/$f" || { echo "$f: typed count" >&2; return 1; }
  done
}

@test "front door: docs/roadmap.md keeps 'model-selection.md'" {
  phrase_in docs/roadmap.md 'model-selection.md'
}

@test "front door: docs/roadmap.md keeps 'Roadmap'" {
  phrase_in docs/roadmap.md 'Roadmap'
}

@test "front door: docs/private-projects.md keeps 'GRID_PRIVATE_ROLES_DIR'" {
  phrase_in docs/private-projects.md 'GRID_PRIVATE_ROLES_DIR'
}

@test "front door: docs/private-projects.md keeps the overwrite warning" {
  phrase_in docs/private-projects.md 'overwrites'
}
