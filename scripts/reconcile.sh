#!/usr/bin/env bash
# reconcile.sh — make the Claude skills dir match the-grid exactly.
#
# wire.sh will NOT clobber a *real* directory that shadows a grid skill
# (a safety rule). On a fresh machine those shadows are often stale copies
# installed by something else (frequently root-owned). This script moves
# those shadows aside into a dated backup dir (nothing is deleted) so the-grid
# can own the slot, then re-wires.
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
#     move the shadows aside + re-wire.
#   - Only ever touches paths that are a REAL dir AND not a symlink.
#   - Only touches names wire.sh itself flagged as shadowing a grid skill.
#   - Uses sudo only when a shadow is not movable as the current user.
#
# Usage:
#   bash reconcile.sh            # dry run — show what would change
#   bash reconcile.sh --force    # move shadows into a dated backup dir + re-wire
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
# occupied runtime slot on purpose, so it is never offered for moving. A name with a line
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
  echo "Dry run. Re-run with --force to move these to a dated backup dir and re-wire:"
  echo "  bash reconcile.sh --force"
  exit 0
fi

# Gate BEFORE the first change: the real wire that follows runs the audit, and a block (exit 3)
# or a missing python3 / policy.yaml must not arrive after the user's dirs are already moved.
# Same rules as wire.sh step 0: GRID_SKIP_AUDIT skips it, GRID_AUDIT=warn continues.
if [ -z "${GRID_SKIP_AUDIT:-}" ]; then
  gate_msg=""
  if [ ! -f "$GRID_DIR/policy.yaml" ]; then gate_msg="no policy.yaml to audit against"
  elif ! command -v python3 >/dev/null 2>&1; then gate_msg="python3 not found, so the audit cannot run"
  elif ! bash "$GRID_DIR/scripts/audit.sh" --wired --quiet; then gate_msg="the audit found high-severity issues"
  fi
  if [ -n "$gate_msg" ]; then
    if [ "${GRID_AUDIT:-}" = warn ]; then
      echo "reconcile: $gate_msg; GRID_AUDIT=warn so continuing" >&2
    else
      echo "reconcile: BLOCKED ($gate_msg); nothing was changed. The re-wire would be blocked the same way." >&2
      exit 3
    fi
  fi
fi

# Move each shadow aside into one dated backup dir instead of deleting it: the user's data stays
# recoverable, and so does the state if the re-wire fails. The dir is a dot-dir inside SKILLS_DIR
# (same filesystem, so a rename), outside the set of links wire.sh manages.
backup=""   # created below by mktemp -d: the second-resolution date alone is not unique
moved=""
restore_moved() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -d "$backup/$n" ] && [ ! -e "$SKILLS_DIR/$n" ] && [ ! -L "$SKILLS_DIR/$n" ]; then
      mv -- "$backup/$n" "$SKILLS_DIR/$n" 2>/dev/null || sudo mv -- "$backup/$n" "$SKILLS_DIR/$n"
    fi
  done <<< "$moved"
}
echo
# mktemp -d appends a random suffix and fails if the dir exists, so two --force runs in the
# same second get two dirs. (A plain `mkdir -p` of the dated name reused the first run's dir,
# and `mv dir existing-dir` then nested the new shadow inside the old backup of the same name.)
backup="$(mktemp -d "$SKILLS_DIR/.grid-reconcile-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
echo "Moving shadows aside to $backup (sudo only where needed)…"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  target="$SKILLS_DIR/$name"

  # Guard: must be a real dir, never a symlink. Never follow links.
  if [ ! -d "$target" ] || [ -L "$target" ]; then
    echo "  skip (not a real dir anymore): $name"
    continue
  fi

  # Try as current user first; fall back to sudo for root-owned shadows.
  if mv -- "$target" "$backup/$name" 2>/dev/null; then
    echo "  moved: $name"
  else
    sudo mv -- "$target" "$backup/$name"
    echo "  moved (sudo): $name"
  fi
  moved="$moved$name"$'\n'
done <<< "$shadows"

echo
echo "Re-wiring…"
if ! bash "$GRID_DIR/scripts/wire.sh" >/dev/null; then
  restore_moved
  echo "reconcile: the re-wire failed; the moved dirs were put back where they were." >&2
  rmdir "$backup" 2>/dev/null || true
  exit 1
fi

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
