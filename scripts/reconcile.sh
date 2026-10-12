#!/usr/bin/env bash
# reconcile.sh — make the Claude skills dir match the-grid exactly.
#
# wire.sh will NOT clobber a *real* directory that shadows a grid skill
# (a safety rule). On a fresh machine those shadows are often stale copies
# installed by something else (frequently root-owned). This script removes
# those shadows so the-grid can own the slot, then re-wires.
#
# Cleverness: we don't hardcode any skill names. We run wire.sh once into a
# THROWAWAY home (GRID_DRY_HOME) to learn exactly which skill names it would
# link, then flag the ones whose live slot is a real dir. wire.sh itself
# decides what is wired (manifest, overlay, precedence), so this script can
# never drift out of sync with it.
#
# SAFETY:
#   - Dry-run by default: nothing outside a temp dir is written (no links, no
#     settings.json, no SKILLS.md, no manifest). Pass --force to actually
#     delete + re-wire.
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
# Physical spelling, like wire.sh: its links carry this spelling, and the verify step below
# compares against it.
GRID_DIR="$(cd "$GRID_DIR" && pwd -P)"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# Wire into a throwaway home to learn which skill names the grid would link. GRID_DRY_HOME
# forces every wire.sh target under it and writes nothing to the repo (it also skips the
# audit, like --check), so this step cannot change the machine. The old harvest ran a REAL
# wire here, which tore down and rebuilt every link on a "dry run".
export GRID_DIR SKILLS_DIR
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
GRID_DRY_HOME="$tmp/home" bash "$GRID_DIR/scripts/wire.sh" >/dev/null

# A name is a shadow when the grid would link it AND the live slot is a real dir (not a
# symlink): the same condition wire_skill uses to print "skip (real dir, not managed)".
# A submodule-root link (repos/<r>, the gstack runtime root) is not a skill: wire.sh skips an
# occupied runtime slot on purpose, so it is never offered for removal. A name with a line
# break is skipped (one name per line below).
grid_phys="$(cd "$GRID_DIR" && pwd -P)"
shadows=""
for link in "$tmp/home/.claude/skills"/*; do
  [ -L "$link" ] || continue
  name="${link##*/}"
  case "$name" in *$'\n'*) continue ;; esac
  rel="$(readlink "$link")"; rel="${rel%/}"; rel="${rel#"$grid_phys"/}"
  case "$rel" in repos/*/*) ;; repos/*) continue ;; esac
  if [ -d "$SKILLS_DIR/$name" ] && [ ! -L "$SKILLS_DIR/$name" ]; then
    shadows="$shadows$name"$'\n'
  fi
done
shadows="$(printf '%s' "$shadows" | sort -u)"

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
