#!/usr/bin/env bash
# reconcile.sh — make the Claude skills dir match the-grid exactly.
#
# wire.sh will NOT clobber a *real* directory that shadows a grid skill
# (a safety rule). On a fresh machine those shadows are often stale copies
# installed by something else (frequently root-owned). This script removes
# those shadows so the-grid can own the slot, then re-wires.
#
# Cleverness: we don't hardcode any skill names. wire.sh already reports
# every shadowed skill as "skip (real dir, not managed): NAME". We parse
# that output, so this script can never drift out of sync with wire.sh.
#
# SAFETY:
#   - Dry-run by default. Pass --force to actually delete + re-wire.
#   - Only ever touches paths that are a REAL dir AND not a symlink.
#   - Only touches names wire.sh itself flagged as shadowing a grid skill.
#   - Uses sudo only when a shadow is not removable as the current user.
#
# Usage:
#   bash reconcile.sh            # dry run — show what would change
#   bash reconcile.sh --force    # remove shadows + re-wire
#
# Env (same contract as wire.sh):
#   GRID_DIR    — root of the-grid repo   (default: parent of scripts/)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# Run wire.sh once and harvest the names it refused to manage.
# Export the env so the child wire.sh targets the same dirs we do.
export GRID_DIR SKILLS_DIR
shadows=$(bash "$GRID_DIR/scripts/wire.sh" \
  | sed -n 's/^  skip (real dir, not managed): //p' \
  | sort -u)

if [ -z "$shadows" ]; then
  echo "Nothing to reconcile — no shadowing real dirs. Already matches the-grid."
  exit 0
fi

echo "Shadowing real dirs (block the-grid from owning the slot):"
echo "$shadows" | sed 's/^/  - /'

if [ "$FORCE" -ne 1 ]; then
  echo
  echo "Dry run. Re-run with --force to remove these and re-wire:"
  echo "  bash reconcile.sh --force"
  exit 0
fi

echo
echo "Removing shadows (sudo only where needed)…"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  target="$SKILLS_DIR/$name"

  # Guard: must be a real dir, never a symlink. Never follow links.
  if [ ! -d "$target" ] || [ -L "$target" ]; then
    echo "  skip (not a real dir anymore): $name"
    continue
  fi

  # Try as current user first; fall back to sudo for root-owned shadows.
  if rm -rf -- "$target" 2>/dev/null; then
    echo "  removed: $name"
  else
    sudo rm -rf -- "$target"
    echo "  removed (sudo): $name"
  fi
done <<< "$shadows"

echo
echo "Re-wiring…"
bash "$GRID_DIR/scripts/wire.sh" >/dev/null

# Verify: every previously-shadowed name should now be a grid symlink.
echo
echo "Verify:"
fail=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  link="$SKILLS_DIR/$name"
  if [ -L "$link" ] && [[ "$(readlink "$link")" == "$GRID_DIR"* ]]; then
    echo "  ok: $name -> grid"
  else
    echo "  FAIL: $name is not a grid symlink"
    fail=1
  fi
done <<< "$shadows"

[ "$fail" -eq 0 ] && echo "Done. Skills dir now matches the-grid." || { echo "Some entries failed."; exit 1; }
