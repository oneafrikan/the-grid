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

# Drift guards (openspec change front-door, task 2.6 cases b to d). They read the tracked tree
# with git ls-files, so a new file must be `git add`ed before these can see it. A later change
# that adds a script, a doc or a write target fails here until the docs name it.

# Case b: every top-level tracked directory (bar the exempt ones and dot-dirs) and every tracked
# file under scripts/ is named in docs/architecture.md.
@test "front door: docs/architecture.md names every top-level directory and every script" {
  cd "$GRID_ROOT"
  missing=""
  # Top-level directories = first path segment of every tracked path that has a slash.
  for d in $(git ls-files | grep / | cut -d/ -f1 | sort -u); do
    case "$d" in repos|openspec|tests|LOGS|.*) continue ;; esac
    grep -qF -- "$d" docs/architecture.md || missing="$missing $d/"
  done
  # Scripts match by file name, so a mention like `lib/foo.sh` or `foo.sh` both count.
  while IFS= read -r f; do
    grep -qF -- "$(basename "$f")" docs/architecture.md || missing="$missing $f"
  done < <(git ls-files scripts)
  [ -z "$missing" ] || { echo "docs/architecture.md is missing:$missing" >&2; return 1; }
}

# Case c: every tracked docs/*.md (top level of docs/ only) is linked from README.md or
# docs/architecture.md, so no doc is orphaned.
@test "front door: every docs/*.md is linked from README.md or docs/architecture.md" {
  cd "$GRID_ROOT"
  missing=""
  while IFS= read -r f; do
    name="$(basename "$f")"
    # architecture.md is the hub that links the others; a self-link would be vacuous.
    [ "$f" != "docs/architecture.md" ] || continue
    # From README.md the link reads docs/<name>; from docs/architecture.md it reads <name>.
    grep -qF -- "](docs/$name" README.md || grep -qF -- "]($name" docs/architecture.md \
      || grep -qF -- "](docs/$name" docs/architecture.md || missing="$missing $f"
  done < <(git ls-files 'docs/*.md' | grep -E '^docs/[^/]+\.md$')
  [ -z "$missing" ] || { echo "not linked from README.md or docs/architecture.md:$missing" >&2; return 1; }
}

# Case d: write targets named in scripts/wire.sh must be disclosed in INSTALL.md and SECURITY.md.
@test "front door: INSTALL.md and SECURITY.md disclose the write targets wire.sh uses" {
  for f in INSTALL.md SECURITY.md; do
    if grep -qF -- 'settings.json' "$GRID_ROOT/scripts/wire.sh"; then
      phrase_in "$f" 'settings.json'
    fi
    if grep -qF -- 'RULES_DIR' "$GRID_ROOT/scripts/wire.sh"; then
      phrase_in "$f" 'rules'
    fi
  done
}

# Trust files (openspec change front-door, group 3).
@test "front door: SECURITY.md starts with '# Security'" {
  [ "$(head -n 1 "$GRID_ROOT/SECURITY.md")" = "# Security" ]
}

@test "front door: SECURITY.md has the advisory URL and the word supported" {
  phrase_in SECURITY.md 'https://github.com/oneafrikan/the-grid/security/advisories/new'
  grep -qw 'supported' "$GRID_ROOT/SECURITY.md"
}

@test "front door: SECURITY.md holds no email address" {
  # The report channel is private vulnerability reporting; an address would invite public mail.
  ! grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' "$GRID_ROOT/SECURITY.md" || false
}

@test "front door: CHANGELOG.md has an Unreleased section" {
  phrase_in CHANGELOG.md '## [Unreleased]'
}

# README front door (openspec change front-door, task 4.5). README.md is a short landing page:
# fixed hero sentence and quickstart, the skeleton's headings in order, generated counts only.

# Fixed strings from design.md; the site and INSTALL.md hand-sync copies of the same text.
HERO='Inspired by Tron. Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine and every AI tool you use.'
CLONE_CMD='git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid && bash ~/.the-grid/scripts/bootstrap.sh --with-agents'

@test "front door: README.md is between 140 and 185 lines" {
  n="$(wc -l < "$GRID_ROOT/README.md")"
  [ "$n" -ge 140 ]
  [ "$n" -le 185 ]
}

@test "front door: README.md '##' headings follow the skeleton order" {
  prev=0
  for h in "Who it's for" "Quickstart" "What you get" "How it works" 'Why "the grid"' "Status" "Docs"; do
    n="$(grep -nxF -- "## $h" "$GRID_ROOT/README.md" | head -n 1 | cut -d: -f1)"
    [ -n "$n" ] || { echo "README.md: missing heading: $h" >&2; return 1; }
    [ "$n" -gt "$prev" ] || { echo "README.md: heading out of order: $h" >&2; return 1; }
    prev="$n"
  done
}

@test "front door: README.md has the hero sentence once, as a bold paragraph, not a blockquote" {
  [ "$(grep -cF -- "$HERO" "$GRID_ROOT/README.md")" -eq 1 ]
  grep -qxF -- "**$HERO**" "$GRID_ROOT/README.md"
  ! grep -F -- "$HERO" "$GRID_ROOT/README.md" | grep -q '^>' || false
}

@test "front door: the hero sentence names no product" {
  for w in "Claude Code" ECC gstack; do
    [[ "$HERO" != *"$w"* ]] || { echo "hero names $w" >&2; return 1; }
  done
}

@test "front door: README.md has the status line and the empty langs marker" {
  phrase_in README.md 'Works today with Claude Code. Other AI tools: see [docs/roadmap.md](docs/roadmap.md).'
  grep -qxF -- '<!-- langs --><!-- /langs -->' "$GRID_ROOT/README.md"
}

@test "front door: README.md carries the clone URL and no your-username placeholder" {
  phrase_in README.md 'https://github.com/oneafrikan/the-grid.git'
  for f in README.md BOOTSTRAP.md; do
    ! grep -qF -- 'your-username' "$GRID_ROOT/$f" || { echo "$f: your-username" >&2; return 1; }
  done
}

@test "front door: the README quickstart command uses --with-agents and matches INSTALL.md" {
  phrase_in README.md "$CLONE_CMD"
  phrase_in README.md '--with-agents'
  # INSTALL.md writes the clone and the bootstrap as two blocks (line-continued clone, then
  # --with-agents), so the exact one-line string is not there yet: check both halves instead.
  # Tighten to the full CLONE_CMD once INSTALL.md carries it.
  phrase_in INSTALL.md 'git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid'
  phrase_in INSTALL.md 'bash ~/.the-grid/scripts/bootstrap.sh --with-agents'
}

@test "front door: README.md has a mermaid diagram, the banner and the Flynn attribution" {
  grep -qxF -- '```mermaid' "$GRID_ROOT/README.md"
  phrase_in README.md '████████╗'
  phrase_in README.md 'Kevin Flynn'
}

@test "front door: README.md has no heading naming ECC, gstack or 'Why not'" {
  ! grep -E '^#+ .*(ECC|gstack|Why not)' "$GRID_ROOT/README.md" || false
}

@test "front door: README.md has no typed count outside the generated markers" {
  stripped="$(sed -E 's/<!--count:[^>]*-->[^<]*<!--\/count-->//g' "$GRID_ROOT/README.md")"
  ! grep -qE '[0-9]{2,4} (skills|agents|roles)' <<< "$stripped" || false
}

@test "front door: every count marker in README.md is one of the six known names" {
  names="$(grep -oE '<!--count:[^>]*-->' "$GRID_ROOT/README.md" | sed -e 's/^<!--count://' -e 's/-->$//' | sort -u)"
  [ -n "$names" ]
  while IFS= read -r name; do
    case "$name" in
      indexed|wired|root_owned|upstream_wired|library|roles) ;;
      *) echo "README.md: unknown count name: $name" >&2; return 1 ;;
    esac
  done <<< "$names"
}

@test "front door: every relative link in README.md resolves" {
  links="$(relative_links README.md)"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    [ -e "$GRID_ROOT/$target" ] || { echo "README.md: broken link: $target" >&2; return 1; }
  done <<< "$links"
}

@test "front door: README.md Status line does not claim wire.sh touches only symlinks" {
  # wire.sh also writes settings.json (hook) and, opt-in, rules and harness dirs; INSTALL.md has the list
  ! grep -qF -- 'only ever touches symlinks' "$GRID_ROOT/README.md" || false
  status="$(awk '/^## Status/{f=1;next} /^## /{f=0} f' "$GRID_ROOT/README.md")"
  [[ "$status" == *settings.json* ]]
  [[ "$status" == *"Versioned from v0.1.0"* ]]
}
