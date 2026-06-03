#!/usr/bin/env bash
# wire.sh — link skills from the-grid into the Claude skills directory.
#
# Precedence: root-level skills (yours) override same-named repo skills.
# Order: repos wired first, root-level wired second so they win.
#
# Override defaults via env vars (used by tests):
#   GRID_DIR    — root of the-grid repo  (default: directory of this script)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")" && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"

# Dirs inside GRID_DIR that are never skills
EXCLUDED=(repos tests .git)

# --- Wiring allowlist ---------------------------------------------------------
# Only submodules listed in wired-submodules.txt have their skills wired into
# SKILLS_DIR. Every other repo under repos/ is library-only (indexed by
# catalog.sh, not symlinked). If the file is absent, all repos are wired (legacy).
# catalog.sh reads the SAME file to label wired vs library in SKILLS.md.
WIRE_ALLOWLIST_FILE="$GRID_DIR/wired-submodules.txt"
WIRED_REPOS=()
wire_all_repos=1
if [ -f "$WIRE_ALLOWLIST_FILE" ]; then
  wire_all_repos=0
  while IFS= read -r line; do
    line="${line%%#*}"                       # strip trailing comment
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && WIRED_REPOS+=("$line")
  done < "$WIRE_ALLOWLIST_FILE"
fi

# Is a given submodule dir name in the wired set?
repo_is_wired() {
  [ "$wire_all_repos" -eq 1 ] && return 0
  local n="$1" r
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && return 0; done
  return 1
}

mkdir -p "$SKILLS_DIR"

# --- 1. Tear down ALL grid-owned symlinks (rebuilt below) ---
# A symlink is grid-owned if its target is under GRID_DIR. We remove every one
# and recreate only the wired set, so moving a repo to library-only actually
# drops its links — not just broken/stale ones (their targets still exist).
# Foreign symlinks (target outside GRID_DIR) are never touched.
while IFS= read -r link; do
  target=$(readlink "$link")
  [[ "$target" == "$GRID_DIR"* ]] || continue   # not ours, leave it alone
  rm "$link"
done < <(find "$SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null)

# Wire a skill directory to SKILLS_DIR.
# Skips real directories (not symlinks) — those are not managed by the-grid.
wire_skill() {
  local skill_dir="$1"
  local name
  name=$(basename "$skill_dir")
  local target="$SKILLS_DIR/$name"

  if [ -d "$target" ] && [ ! -L "$target" ]; then
    echo "  skip (real dir, not managed): $name"
    return
  fi

  # ln -sfn: -s symlink, -f force-replace, -n treat existing symlink-to-dir as file
  ln -sfn "$skill_dir" "$target"
  echo "  wired: $name"
}

# --- 2. Wire repo skills first (lower precedence) ---
# Uses find so it handles any nesting depth (flat, skills/, skills/category/, etc.)
# Skips SKILL.md files sitting directly at the repo root (e.g. gstack's root SKILL.md).
if [ -d "$GRID_DIR/repos" ]; then
  for repo_dir in "$GRID_DIR/repos"/*/; do
    [ -d "$repo_dir" ] || continue
    repo_dir="${repo_dir%/}"  # strip trailing slash for comparison
    repo_is_wired "$(basename "$repo_dir")" || continue   # library-only: don't wire
    while IFS= read -r skill_md; do
      skill_dir=$(dirname "$skill_md")
      [ "$skill_dir" = "$repo_dir" ] && continue  # skip repo-root SKILL.md
      wire_skill "$skill_dir"
    done < <(find "$repo_dir" -name "SKILL.md" -not -path "*/.git/*")
  done
fi

# --- 3. Wire root-level skills last (higher precedence — overrides repos) ---
for skill_dir in "$GRID_DIR"/*/; do
  [ -d "$skill_dir" ] || continue
  name=$(basename "$skill_dir")
  [[ " ${EXCLUDED[*]} " == *" $name "* ]] && continue  # skip non-skill dirs
  [ -f "$skill_dir/SKILL.md" ] || continue              # must be a valid skill
  wire_skill "$skill_dir"
done

# --- 4. Refresh the skill catalogue so wiring and SKILLS.md never drift ---
# Coupled on purpose: any change to what's wired re-renders the catalogue.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/catalog.sh" ]; then
  GRID_DIR="$GRID_DIR" bash "$SCRIPT_DIR/catalog.sh" "$GRID_DIR/SKILLS.md"
fi

echo "Done."
