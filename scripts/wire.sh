#!/usr/bin/env bash
# wire.sh — link skills from the-grid into the Claude skills directory.
#
# Precedence: root-level skills (yours) override same-named repo skills.
# Order: repos wired first, root-level wired second so they win.
#
# Override defaults via env vars (used by tests):
#   GRID_DIR    — root of the-grid repo  (default: parent of scripts/)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
#   AGENTS_DIR  — Claude subagents directory (default: ~/.claude/agents)
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.claude/agents}"

# --- Wiring allowlist ---------------------------------------------------------
# Only submodules listed in wired-submodules.txt have their skills wired into
# SKILLS_DIR. Every other repo under repos/ is library-only (indexed by
# catalog.sh, not symlinked). If the file is absent, all repos are wired (legacy).
#
# Two entry formats are supported:
#   repo-name          → wire ALL skills in that submodule (existing behaviour)
#   repo-name/skill    → wire ONLY that specific skill (granular control)
#
# catalog.sh reads the SAME file to label wired vs library in SKILLS.md.
WIRE_ALLOWLIST_FILE="$GRID_DIR/wired-submodules.txt"
WIRED_REPOS=()   # whole-repo entries
WIRED_SKILLS=()  # repo/skill-name entries
wire_all_repos=1
if [ -f "$WIRE_ALLOWLIST_FILE" ]; then
  wire_all_repos=0
  while IFS= read -r line; do
    line="${line%%#*}"                       # strip trailing comment
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    if [[ "$line" == */* ]]; then
      WIRED_SKILLS+=("$line")              # per-skill entry
    else
      WIRED_REPOS+=("$line")              # whole-repo entry
    fi
  done < "$WIRE_ALLOWLIST_FILE"
fi

# Is a given submodule dir name fully wired (whole-repo entry)?
repo_is_wired() {
  [ "$wire_all_repos" -eq 1 ] && return 0
  local n="$1" r
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && return 0; done
  return 1
}

# Is a specific skill (repo, skill-name) listed in WIRED_SKILLS?
skill_is_wired() {
  local entry="$1/$2" s
  for s in "${WIRED_SKILLS[@]:-}"; do [ "$s" = "$entry" ] && return 0; done
  return 1
}

# Does this repo have any per-skill entries in WIRED_SKILLS?
repo_has_skill_entries() {
  local repo="$1" s
  for s in "${WIRED_SKILLS[@]:-}"; do
    [[ "$s" == "$repo/"* ]] && return 0
  done
  return 1
}

mkdir -p "$SKILLS_DIR" "$AGENTS_DIR"

# --- 1. Tear down ALL grid-owned symlinks (rebuilt below) ---
# A symlink is grid-owned if its target is under GRID_DIR. We remove every one
# and recreate only the wired set, so moving a repo to library-only actually
# drops its links — not just broken/stale ones (their targets still exist).
# Foreign symlinks (target outside GRID_DIR) are never touched. Applied to both
# the skills dir and the agents dir (composed subagents land in the latter).
teardown_grid_links() {
  local dir="$1" link target
  [ -d "$dir" ] || return 0
  while IFS= read -r link; do
    target=$(readlink "$link")
    [[ "$target" == "$GRID_DIR"* ]] || continue   # not ours, leave it alone
    rm "$link"
  done < <(find "$dir" -maxdepth 1 -type l 2>/dev/null)
}
teardown_grid_links "$SKILLS_DIR"
teardown_grid_links "$AGENTS_DIR"

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

# Wire a single composed-agent .md file into AGENTS_DIR as a symlink.
# Skips a real file (not a symlink) — those are not managed by the-grid.
wire_agent() {
  local agent_file="$1"
  local name
  name=$(basename "$agent_file")
  local target="$AGENTS_DIR/$name"

  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "  skip (real file, not managed): $name"
    return
  fi

  ln -sfn "$agent_file" "$target"
  echo "  wired agent: $name"
}

# --- 2. Wire repo skills first (lower precedence) ---
# Uses find so it handles any nesting depth (flat, skills/, skills/category/, etc.)
# Skips SKILL.md files sitting directly at the repo root (e.g. gstack's root SKILL.md).
# Supports two wiring modes per repo:
#   whole-repo  — repo_is_wired() true: wire every skill found
#   per-skill   — repo_has_skill_entries() true: wire only the explicitly listed skills
if [ -d "$GRID_DIR/repos" ]; then
  for repo_dir in "$GRID_DIR/repos"/*/; do
    [ -d "$repo_dir" ] || continue
    repo_dir="${repo_dir%/}"
    repo_name="$(basename "$repo_dir")"

    if repo_is_wired "$repo_name"; then
      # Wire all skills in this repo (whole-repo entry).
      while IFS= read -r skill_md; do
        skill_dir=$(dirname "$skill_md")
        [ "$skill_dir" = "$repo_dir" ] && continue
        wire_skill "$skill_dir"
      done < <(find "$repo_dir" -name "SKILL.md" -not -path "*/.git/*")
    elif repo_has_skill_entries "$repo_name"; then
      # Wire only the skills explicitly listed (per-skill entries).
      while IFS= read -r skill_md; do
        skill_dir=$(dirname "$skill_md")
        [ "$skill_dir" = "$repo_dir" ] && continue
        skill_is_wired "$repo_name" "$(basename "$skill_dir")" || continue
        wire_skill "$skill_dir"
      done < <(find "$repo_dir" -name "SKILL.md" -not -path "*/.git/*")
    fi
    # else: library-only — don't wire anything
  done
fi

# --- 3. Wire skills/ dir last (higher precedence — overrides repos) ---
if [ -d "$GRID_DIR/skills" ]; then
  for skill_dir in "$GRID_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    wire_skill "$skill_dir"
  done
fi

# --- 3b. Wire agent-factory Claude Code output (composed agents) ---
# compose.py --target claude-code emits per project under
#   agent-factory/projects/<name>/_claude-code/{skills,agents}/
# Orchestrator skills wire into SKILLS_DIR (override same-named ecosystem skills,
# since they're wired last); specialist subagents wire into AGENTS_DIR.
# NOTE: this currently wires EVERY composed project's output. The machine manifest
# (TODO #6) will gate which agents are active per machine; until then it's all-on.
CC_OUT="$GRID_DIR/agent-factory/projects"
if [ -d "$CC_OUT" ]; then
  while IFS= read -r skill_md; do
    wire_skill "$(dirname "$skill_md")"
  done < <(find "$CC_OUT"/*/_claude-code/skills -name "SKILL.md" 2>/dev/null)
  while IFS= read -r agent_md; do
    wire_agent "$agent_md"
  done < <(find "$CC_OUT"/*/_claude-code/agents -name "*.md" 2>/dev/null)
fi

# --- 4. Refresh the skill catalogue so wiring and SKILLS.md never drift ---
# Coupled on purpose: any change to what's wired re-renders the catalogue.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/catalog.sh" ]; then
  GRID_DIR="$GRID_DIR" bash "$SCRIPT_DIR/catalog.sh" "$GRID_DIR/SKILLS.md"
fi


echo "Done."
