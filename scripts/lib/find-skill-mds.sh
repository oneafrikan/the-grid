#!/usr/bin/env bash
#
# find-skill-mds.sh — shared by wire.sh and catalog.sh (source it, don't run it).
#
# find_skill_mds <repo-dir> prints the path of every SKILL.md the repo ships
# (as <repo-dir>/<relative path>, one per line), MINUS the copies that are not
# the repo's canonical skills (see "Exclusion rules" below).
#
# Why not plain `find`: some submodules generate untracked, gitignored copies
# of their skills at setup time (gstack writes ~54 per host into .slate/,
# .opencode/, .kiro/, .hermes/ ... — 482 stray SKILL.md on guide-server).
# A raw find counts and wires those, so SKILLS.md flipped between ~239 and ~725
# depending on which machine ran wire.sh last. Asking git for tracked files
# gives the same answer on every machine.
#
# Tracked is not enough, though: several repos TRACK duplicates of their own
# skills (ECC: 1027 SKILL.md, only 293 under skills/). So, on top of the
# tracked-only listing, three exclusion rules drop non-canonical paths. This
# deliberately reverses the older behaviour of honouring skills tracked inside
# dot-dirs: what lives in a root-level dot-dir is either a per-harness copy of
# the repo's skills (.kiro, .cursor, .gemini, .openclaw ...) or the upstream
# repo's own maintainer skills (.agents/skills/), never something to wire.
#
# Exclusion rules (all on the repo-relative path):
#   1. Translations: docs/ i18n/ translations/ locales/ followed by a locale
#      component such as tr, ja-JP, zh-CN (^[a-z]{2}([-_][A-Za-z]{2,4})?$).
#   2. Harness copies / maintainer skills: first path component starts with ".".
#   3. Listed prefixes: a row `repo | prefix/` in scripts/lib/skill-excludes.txt
#      whose repo equals the basename of the repo dir.
#
# Fallback: a directory that is not its own git checkout (an uninitialised
# submodule, or a test fixture) uses plain find, as before — the same
# exclusion rules apply to its output.

# Where the listed-prefix data lives: next to this file, NOT under GRID_DIR,
# because mock-grid tests run the real script against throwaway grids.
_SKILL_EXCLUDES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skill-excludes.txt"

# _skill_excluded <repo-name> <relative-path>
# Returns 0 (true) when the path must be dropped, 1 when it is kept.
# bash 3.2-safe: only [[ =~ ]] with the regex held in a variable, no mapfile.
_skill_excluded() {
  local repo="$1" rel="$2" first rest second row_repo row_prefix
  local locale_re='^[a-z]{2}([-_][A-Za-z]{2,4})?$'

  # Rule 2: any root-level dot-dir (.kiro, .agents, .cursor, ...).
  first="${rel%%/*}"
  case "$first" in .*) return 0 ;; esac

  # Rule 1: <translation-root>/<locale>/... — e.g. docs/ja-JP/skills/a.
  case "$first" in
    docs|i18n|translations|locales)
      rest="${rel#*/}"
      # A SKILL.md directly under e.g. docs/ has no second component: keep it.
      if [ "$rest" != "$rel" ]; then
        second="${rest%%/*}"
        if [[ "$second" =~ $locale_re ]]; then return 0; fi
      fi
      ;;
  esac

  # Rule 3: listed prefixes for this repo. Missing data file = no rows.
  if [ -f "$_SKILL_EXCLUDES_FILE" ]; then
    while IFS='|' read -r row_repo row_prefix; do
      row_repo="${row_repo%%#*}"                            # drop a comment
      row_repo="${row_repo#"${row_repo%%[![:space:]]*}"}"   # ltrim
      row_repo="${row_repo%"${row_repo##*[![:space:]]}"}"   # rtrim
      [ -n "$row_repo" ] || continue                        # blank / comment
      row_prefix="${row_prefix#"${row_prefix%%[![:space:]]*}"}"
      row_prefix="${row_prefix%"${row_prefix##*[![:space:]]}"}"
      [ -n "$row_prefix" ] || continue
      if [ "$row_repo" = "$repo" ]; then
        case "$rel" in "$row_prefix"*) return 0 ;; esac
      fi
    done < "$_SKILL_EXCLUDES_FILE"
  fi
  return 1
}

find_skill_mds() {
  local root="${1%/}" f p rel repo
  repo="$(basename "$root")"
  # `-e .git` (file or dir) = root is its own checkout, not just a subdir of
  # the parent repo, so ls-files won't silently answer for the wrong repo.
  if [ -e "$root/.git" ] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # -z: NUL-delimited, safe for any filename. Pathspecs: root-level + nested.
    git -C "$root" ls-files -z -- 'SKILL.md' '*/SKILL.md' |
      while IFS= read -r -d '' f; do
        # Skip tracked-but-deleted files (ls-files lists the index, not disk).
        [ -f "$root/$f" ] || continue
        _skill_excluded "$repo" "$f" && continue
        printf '%s/%s\n' "$root" "$f"
      done
  else
    find "$root" -name SKILL.md -not -path '*/.git/*' 2>/dev/null |
      while IFS= read -r p; do
        rel="${p#"$root"/}"
        _skill_excluded "$repo" "$rel" && continue
        printf '%s\n' "$p"
      done
  fi
}
