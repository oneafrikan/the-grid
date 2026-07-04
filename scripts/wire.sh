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
#   GRID_HOST   — machine key for the overlay (default: hostname -s)
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.claude/agents}"
GRID_HOST="${GRID_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"

# --- Manifest: baseline + per-machine overlay ---------------------------------
# What gets wired is resolved from two layers, unioned in order:
#   1. baseline-submodules.txt   — wired on EVERY machine (the baseline)
#   2. machines/<host>.txt       — THIS machine's overlay (host = GRID_HOST)
# catalog.sh reads the BASELINE only, so SKILLS.md stays a deterministic,
# machine-agnostic index (clean cross-machine diffs); the overlay changes the
# live symlink set, not the catalogue.
#
# Entry grammar (identical in both files):
#   repo                 → wire ALL skills in that submodule
#   repo/skill           → wire ONLY that skill
#   -repo  | -repo/skill → SUBTRACT (remove a baseline entry — overlay escape hatch)
#   project:<name>       → wire that composed agent-factory project's _claude-code output
#   -project:<name>      → un-gate a project
# Legacy fallbacks: if NO manifest file exists at all, every repo is wired; if
# NO project: entry exists anywhere, every composed project is wired.
WIRED_REPOS=()     # whole-repo entries
WIRED_SKILLS=()    # repo/skill entries
DENY_REPOS=()      # -repo subtractions
DENY_SKILLS=()     # -repo/skill subtractions
WIRED_PROJECTS=()  # project:<name> entries
any_project_entry=0
wire_all_repos=1

# Parse one manifest file into the arrays above. Later files (the overlay) layer
# on top of earlier ones (the baseline): additions append, subtractions deny.
load_manifest() {
  local file="$1" line p tmp x
  [ -f "$file" ] || return 0
  wire_all_repos=0                           # a manifest exists → no legacy wire-all
  while IFS= read -r line; do
    line="${line%%#*}"                       # strip trailing comment
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    case "$line" in
      project:*)  any_project_entry=1; WIRED_PROJECTS+=("${line#project:}") ;;
      -project:*) any_project_entry=1
                  p="${line#-project:}"; tmp=()
                  for x in "${WIRED_PROJECTS[@]:-}"; do [ -n "$x" ] && [ "$x" != "$p" ] && tmp+=("$x"); done
                  WIRED_PROJECTS=("${tmp[@]:-}") ;;
      -*/*)       DENY_SKILLS+=("${line#-}") ;;
      -*)         DENY_REPOS+=("${line#-}") ;;
      */*)        WIRED_SKILLS+=("$line") ;;
      *)          WIRED_REPOS+=("$line") ;;
    esac
  done < "$file"
}

load_manifest "$GRID_DIR/baseline-submodules.txt"
load_manifest "$GRID_DIR/machines/$GRID_HOST.txt"

# --- predicates ---------------------------------------------------------------
repo_is_denied()  { local n="$1" r; for r in "${DENY_REPOS[@]:-}";   do [ "$r" = "$n" ] && return 0; done; return 1; }
skill_is_denied() { local e="$1/$2" s; for s in "${DENY_SKILLS[@]:-}"; do [ "$s" = "$e" ] && return 0; done; return 1; }

# Is a given submodule dir name fully wired (whole-repo entry, not denied)?
repo_is_wired() {
  repo_is_denied "$1" && return 1
  [ "$wire_all_repos" -eq 1 ] && return 0
  local n="$1" r
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && return 0; done
  return 1
}

# Is a specific skill (repo, skill-name) wired by a per-skill entry (not denied)?
skill_is_wired() {
  skill_is_denied "$1" "$2" && return 1
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

# Is a composed agent-factory project wired? (no project: entries → all, legacy)
project_is_wired() {
  [ "$any_project_entry" -eq 0 ] && return 0
  local name="$1" p
  for p in "${WIRED_PROJECTS[@]:-}"; do [ "$p" = "$name" ] && return 0; done
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
      # Wire all skills in this repo (whole-repo entry), minus any -repo/skill
      # subtractions from the overlay.
      while IFS= read -r skill_md; do
        skill_dir=$(dirname "$skill_md")
        [ "$skill_dir" = "$repo_dir" ] && continue
        skill_is_denied "$repo_name" "$(basename "$skill_dir")" && continue
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
# Gated per machine by project:<name> manifest entries (project_is_wired); with
# no project: entries anywhere, every composed project wires (legacy fallback).
CC_OUT="$GRID_DIR/agent-factory/projects"
if [ -d "$CC_OUT" ]; then
  for proj_dir in "$CC_OUT"/*/; do
    [ -d "$proj_dir" ] || continue
    proj_name="$(basename "${proj_dir%/}")"
    project_is_wired "$proj_name" || continue
    while IFS= read -r skill_md; do
      wire_skill "$(dirname "$skill_md")"
    done < <(find "$proj_dir/_claude-code/skills" -name "SKILL.md" 2>/dev/null)
    while IFS= read -r agent_md; do
      wire_agent "$agent_md"
    done < <(find "$proj_dir/_claude-code/agents" -name "*.md" 2>/dev/null)
  done
fi

# --- 3c. Wire root-owned agents/ dir (highest precedence — root wins) ---
# Hand-authored subagents that aren't composed via agent-factory (no
# delegates_to, not a team role — e.g. a ported persona/behavior-modifier
# skill like ponytail) live here so they're tracked and reproducible across
# machines, same ownership model as root-level skills/. Wired last so a
# root-owned agent overrides a same-named composed one.
if [ -d "$GRID_DIR/agents" ]; then
  for agent_file in "$GRID_DIR/agents"/*.md; do
    [ -f "$agent_file" ] || continue
    wire_agent "$agent_file"
  done
fi

# --- 4. Refresh the skill catalogue so wiring and SKILLS.md never drift ---
# Coupled on purpose: any change to what's wired re-renders the catalogue.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/catalog.sh" ]; then
  GRID_DIR="$GRID_DIR" bash "$SCRIPT_DIR/catalog.sh" "$GRID_DIR/SKILLS.md"
fi


echo "Done."
