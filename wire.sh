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

mkdir -p "$SKILLS_DIR"

# --- 1. Remove stale grid-owned symlinks ---
# A symlink is grid-owned if its absolute target starts with GRID_DIR.
# If the target no longer exists, the symlink is stale — remove it.
while IFS= read -r link; do
  target=$(readlink "$link")
  [[ "$target" == "$GRID_DIR"* ]] || continue   # not ours, leave it alone
  [ -e "$link" ] && continue                     # still valid, leave it
  echo "  remove stale: $(basename "$link")"
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
