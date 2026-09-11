#!/usr/bin/env bash
# bootstrap.sh — one-command machine setup for the-grid.
#
# Runs from inside an existing clone of the-grid and brings the machine fully
# online: sync submodules → wire skills → (optionally) compose + wire the
# agent-factory team. Mirrors the manual sequence in BOOTSTRAP.md so the two
# never drift — if you change the boot steps, change them here.
#
# The initial `git clone` can't be done by a script that lives *inside* the
# repo, so the true new-machine one-liner is:
#
#   git clone <repo-url> ~/.the-grid && bash ~/.the-grid/scripts/bootstrap.sh
#
# Usage:
#   bash scripts/bootstrap.sh                 # submodules + wire skills
#   bash scripts/bootstrap.sh --with-agents   # also compose + wire the grid team agents
#
# Env (same contract as wire.sh):
#   GRID_DIR    — root of the-grid repo   (default: parent of scripts/)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
#   AGENTS_DIR  — Claude subagents directory (default: ~/.claude/agents)
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
WITH_AGENTS=0

for arg in "$@"; do
  case "$arg" in
    --with-agents) WITH_AGENTS=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"  # print the header comment as help
      exit 0 ;;
    *) echo "bootstrap.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$GRID_DIR"

# 1. Sync every skill submodule to the pointer this commit records.
echo "==> [1/4] Syncing submodules (git submodule update --init --recursive)"
git submodule update --init --recursive

# Activate the in-repo git hooks (pre-commit runs bats). Idempotent; only
# affects commits made in this repo, so it's harmless on consumer machines.
git config core.hooksPath .githooks

# 2. Seed the wiring manifest (personal curation, gitignored — see #24).
#    Skip a file that already exists; without this, wire.sh falls back to
#    wiring every repo (harmless but noisy) instead of the curated baseline.
echo "==> [2/4] Seeding wiring manifest from examples (baseline-submodules.txt, machines/$(hostname -s).txt)"
[[ -f "$GRID_DIR/baseline-submodules.txt" ]] || cp "$GRID_DIR/baseline-submodules.example.txt" "$GRID_DIR/baseline-submodules.txt"
[[ -f "$GRID_DIR/machines/$(hostname -s).txt" ]] || cp "$GRID_DIR/machines/example.txt" "$GRID_DIR/machines/$(hostname -s).txt"

# 3. Wire skills (and any already-composed agents) into Claude.
echo "==> [3/4] Wiring skills (scripts/wire.sh)"
bash "$GRID_DIR/scripts/wire.sh"

# 4. Optionally build the composed agent team, then re-wire so the freshly
#    compiled orchestrator skills + specialist subagents go live.
if [[ "$WITH_AGENTS" == "1" ]]; then
  echo "==> [4/4] Composing agent-factory teams (core, grid, finance-desk) + re-wiring"
  cd "$GRID_DIR/agent-factory"
  # Create the venv on first run; reuse it afterwards (idempotent).
  if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
    .venv/bin/pip install -q -r requirements.txt
  fi
  .venv/bin/python compose.py examples/core.yaml --target claude-code
  .venv/bin/python compose.py examples/grid.yaml --target claude-code
  .venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
  cd "$GRID_DIR"
  bash "$GRID_DIR/scripts/wire.sh"
else
  echo "==> [4/4] Skipping agent-factory (pass --with-agents to compose + wire the team)"
fi

echo "==> Bootstrap complete. Open a fresh Claude session to pick up new skills/agents."
