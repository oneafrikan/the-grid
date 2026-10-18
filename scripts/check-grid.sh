#!/usr/bin/env bash
# check-grid.sh — "is the grid healthy?" check: the full test suite plus a link scan.
#
# Two signals, no wall of bats output (the suite is the whole of tests/, so it takes
# many minutes: roughly 15 on CI, longer locally; it is not a quick check):
#   1. Run the full bats suite, print one PASS/FAIL line. On failure (only then)
#      replay the full bats output so you can see what broke.
#   2. Scan the live Claude skills + agents dirs for BROKEN symlinks that point
#      back into this repo (a grid-owned link whose target has gone missing —
#      e.g. a submodule wasn't initialised, or a skill dir was renamed upstream).
#
# Exit non-zero if either signal is bad, so it doubles as a CI / pre-push gate.
#
# Usage:
#   bash scripts/check-grid.sh
#
# Env (same contract as wire.sh):
#   GRID_DIR    — root of the-grid repo   (default: parent of scripts/)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
#   AGENTS_DIR  — Claude subagents directory (default: ~/.claude/agents)
set -uo pipefail  # NOT -e: we want to run every check and aggregate the result

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.claude/agents}"

rc=0

# --- 1. bats suite -----------------------------------------------------------
echo "==> Running test suite..."
bats_out="$(tests/lib/bats-core/bin/bats tests/ 2>&1)"
if [[ $? -eq 0 ]]; then
  # Pull the trailing "N tests, M failures" summary if present, else count oks.
  n_ok="$(grep -c '^ok ' <<<"$bats_out")"
  echo "    PASS — $n_ok tests green"
else
  echo "    FAIL — bats reported failures:"
  echo "$bats_out" | sed 's/^/      /'
  rc=1
fi

# --- 2. broken grid-owned symlinks ------------------------------------------
# Only flag links that (a) are broken AND (b) point into GRID_DIR — i.e. links
# this repo owns. Foreign/broken links from other tools are not our problem.
echo "==> Checking for broken grid-owned symlinks..."
broken=0
for dir in "$SKILLS_DIR" "$AGENTS_DIR"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    case "$target" in
      "$GRID_DIR"/*)
        echo "    BROKEN: $link -> $target"
        broken=$((broken + 1))
        ;;
    esac
  done < <(find "$dir" -maxdepth 1 -xtype l -print0 2>/dev/null)
done
if [[ "$broken" -eq 0 ]]; then
  echo "    OK — no broken grid-owned symlinks"
else
  echo "    FAIL — $broken broken symlink(s); run scripts/wire.sh to repair"
  rc=1
fi

# --- verdict -----------------------------------------------------------------
if [[ "$rc" -eq 0 ]]; then
  echo "==> Grid healthy."
else
  echo "==> Grid UNHEALTHY (see above)."
fi
exit "$rc"
