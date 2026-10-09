#!/usr/bin/env bash
# runtime-setup.sh — run a submodule's own runtime setup (for example gstack's
# ./setup) safely, then put the-grid's wiring back the way it should be.
#
#   bash scripts/runtime-setup.sh <repo> [--dry-run]
#
# The command comes from scripts/lib/runtimes.txt (the same map wire.sh reads).
# This is a HUMAN-RUN script: the setup command can download a browser, and
# upstream setup scripts may touch global state, so wire.sh never runs it. What
# this wrapper adds around the upstream command:
#   1. refuses to start when a prerequisite is missing or the runtime-root link
#      path is occupied by something that is not ours (it never deletes that);
#   2. snapshots the Claude settings file and the real dirs in the skills dir;
#   3. runs the setup command inside repos/<repo>;
#   4. compares the settings file afterwards and exits 3 if it changed (it
#      NEVER reverts: the upstream rollback keeps its own backup);
#   5. removes the flat per-skill dirs setup created (they shadow wire.sh's
#      symlinks), keeping alias copies and anything that pre-existed;
#   6. re-runs wire.sh, then reports (never reverts) dirt inside the submodule.
#
# Exit codes: 0 ok, 2 unknown repo / missing prerequisite / occupied link /
#             bad usage, 3 the settings file changed, otherwise the setup
#             command's own non-zero status.
#
# Env (all optional): GRID_DIR (default: parent of scripts/), SKILLS_DIR
# (default ~/.claude/skills), CLAUDE_CONFIG_DIR (default ~/.claude), HOME.
# Uses only POSIX cp/cmp/diff (no sha256sum/shasum: they differ per OS).
set -uo pipefail   # NOT -e: every step reports its own failure

src="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$src")" && pwd -P)"
GRID_DIR="${GRID_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export GRID_DIR SKILLS_DIR CLAUDE_CONFIG_DIR   # setup commands and wire.sh inherit these

# find_skill_mds: used to learn which dir names are this repo's skills.
# shellcheck source=lib/find-skill-mds.sh
. "$SCRIPT_DIR/lib/find-skill-mds.sh"

usage() { echo "usage: runtime-setup.sh <repo> [--dry-run]" >&2; exit 2; }

repo=""; dry=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    -*) usage ;;
    *) [ -z "$repo" ] && repo="$a" || usage ;;
  esac
done
[ -n "$repo" ] || usage

trim() { # trim leading/trailing whitespace without forking
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- 1. Look up the row and check prerequisites -------------------------------
MAP="$GRID_DIR/scripts/lib/runtimes.txt"
[ -f "$MAP" ] || { echo "runtime-setup: no runtime map at $MAP" >&2; exit 2; }
found=0
while IFS='|' read -r r_repo r_link r_marker r_needs r_setup; do
  r_repo="$(trim "${r_repo%%#*}")"
  [ "$r_repo" = "$repo" ] || continue
  link="$(trim "$r_link")"; marker="$(trim "$r_marker")"
  needs="$(trim "$r_needs")"; setup_cmd="$(trim "$r_setup")"
  found=1; break
done < "$MAP"
[ "$found" = 1 ] || { echo "runtime-setup: '$repo' is not in $MAP" >&2; exit 2; }

root="$GRID_DIR/repos/$repo"
if [ -z "$(ls -A "$root" 2>/dev/null)" ]; then
  echo "runtime-setup: $root is missing or empty - run: git submodule update --init" >&2
  exit 2
fi
if [ -n "$needs" ] && ! command -v "$needs" >/dev/null 2>&1; then
  echo "runtime-setup: '$needs' is required but not on PATH." >&2
  echo "  the-grid never installs it; the upstream setup prints checksum-verified install instructions." >&2
  exit 2
fi
# The runtime-root link path must be absent or already ours. If it is a real
# dir or points elsewhere, upstream setup would leave it alone and skip
# registration while wire.sh kept warning - so stop before doing anything.
if [ -n "$link" ]; then
  lp="$SKILLS_DIR/$link"
  if { [ -e "$lp" ] || [ -L "$lp" ]; } &&
     { [ ! -L "$lp" ] || [ "$(readlink "$lp")" != "$root" ]; }; then
    echo "runtime-setup: $lp exists and is not a symlink to $root." >&2
    echo "  remove or move it first (the-grid never deletes it), then re-run." >&2
    exit 2
  fi
fi

if [ "$dry" = 1 ]; then
  echo "runtime-setup (dry run): would run, inside $root:"
  echo "  bash -c '$setup_cmd'"
  echo "then compare ${CLAUDE_CONFIG_DIR}/settings.json, remove setup's flat skill dirs under $SKILLS_DIR, and re-run wire.sh."
  exit 0
fi

# --- 2. Snapshot: settings file + pre-existing real dirs in the skills dir -----
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
settings="$CLAUDE_CONFIG_DIR/settings.json"
if [ -f "$settings" ]; then cp "$settings" "$work/settings.before"; had_settings=1; else had_settings=0; fi
mkdir -p "$SKILLS_DIR"
# Real (non-symlink) directories directly under the skills dir. -type d does
# not match symlinks (find does not follow them), which is what we want.
list_real_dirs() { find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do basename "$d"; done | LC_ALL=C sort; }
list_real_dirs > "$work/dirs.before"

# --- 3. Run the setup command inside the submodule -----------------------------
echo "runtime-setup: running in $root:"
echo "  $setup_cmd"
( cd "$root" && bash -c "$setup_cmd" )
setup_rc=$?
[ "$setup_rc" -eq 0 ] || echo "runtime-setup: setup command exited $setup_rc (continuing with the checks)" >&2

# --- 4. Did the global settings file change? ------------------------------------
final_rc=0
settings_changed=0
if [ "$had_settings" = 1 ] && [ -f "$settings" ]; then
  cmp -s "$work/settings.before" "$settings" || settings_changed=1
elif [ "$had_settings" = 1 ] || [ -f "$settings" ]; then
  settings_changed=1        # existed before XOR exists now
fi
if [ "$settings_changed" = 1 ]; then
  echo "runtime-setup: SETTINGS CHANGED: $settings was modified by setup." >&2
  if [ "$had_settings" = 1 ]; then before="$work/settings.before"; else before=/dev/null; fi
  if [ -f "$settings" ]; then after="$settings"; else after=/dev/null; fi
  diff "$before" "$after" >&2 || true
  hook="$root/bin/gstack-settings-hook"
  [ -x "$hook" ] && echo "runtime-setup: to roll back (this script never reverts): $hook rollback" >&2
  final_rc=3
  # Deliberately NOT exiting yet: the flat-dir cleanup and re-wire below must
  # still run, otherwise a second attempt would treat setup's flat dirs as
  # pre-existing and never clean them.
fi

# --- 5. Remove setup's flat skill dirs (they shadow wire.sh's symlinks) ---------
# Skill dir names of this repo, per the same discovery wire.sh uses.
find_skill_mds "$root" | while IFS= read -r p; do basename "$(dirname "$p")"; done \
  | LC_ALL=C sort -u > "$work/skillnames"
list_real_dirs > "$work/dirs.after"
removed=0; aliases=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  grep -qxF -- "$name" "$work/dirs.before" && continue      # pre-existing: never touched
  if grep -qxF -- "$name" "$work/skillnames"; then
    rm -rf "${SKILLS_DIR:?}/$name"; removed=$((removed + 1))
  else
    aliases="$aliases $name"                                  # alias copy: kept, listed
  fi
done < "$work/dirs.after"
echo "runtime-setup: removed $removed flat skill dir(s) created by setup"
if [ -n "$aliases" ]; then
  echo "runtime-setup: alias copies created by this run (left in place):$aliases"
fi

# --- 6. Re-wire, then report dirt inside the submodule --------------------------
bash "$SCRIPT_DIR/wire.sh" || echo "runtime-setup: wire.sh failed" >&2
if [ -e "$root/.git" ]; then
  dirt="$(git -C "$root" status --short 2>/dev/null || true)"
  if [ -n "$dirt" ]; then
    echo "WARNING: setup modified tracked files in the submodule (reported, not reverted):"
    printf '%s\n' "$dirt"
  fi
fi

# Final verdict on the marker wire.sh warns about.
if [ -x "$root/$marker" ] || [ -s "$root/$marker" ]; then
  echo "runtime-setup: marker present: $marker"
else
  echo "runtime-setup: marker STILL MISSING: $marker (setup did not produce it)" >&2
fi

if [ "$final_rc" -ne 0 ]; then exit "$final_rc"; fi
exit "$setup_rc"
