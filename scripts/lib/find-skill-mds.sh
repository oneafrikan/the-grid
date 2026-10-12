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
# .opencode/, .kiro/, .hermes/ ... — 482 stray SKILL.md on one Linux box).
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
#      component: a bare code from a known list (ja, tr, zh ...) or xx-YY /
#      xx_YY / xx-Hans with an upper-case region (ja-JP, zh-CN, zh-Hans). A
#      bare two-letter name that is NOT a known locale (qa, go, ui, db, ci) is
#      a real skill dir and stays.
#   2. Harness copies / maintainer skills: first path component starts with ".".
#   3. Listed prefixes: a row `repo | prefix/` in scripts/lib/skill-excludes.txt
#      whose repo equals the basename of the repo dir.
#   4. Vendored copies: any path with a node_modules component.
#
# Only real, regular-file, single-line SKILL.md paths are returned, identically in
# both branches: a symlinked SKILL.md (it can point outside the repo), a directory
# named SKILL.md, a dangling link, and any path holding a line break (CR or LF; the
# output is one path per line, so a break would forge extra "paths") are skipped,
# the last with a stderr warning. Callers also check containment (wire.sh).
#
# Fallback: a directory that is not its own git checkout (an uninitialised
# submodule, a `grid install` repo, or a test fixture) uses plain find, sorted
# (LC_ALL=C) — the same exclusion rules apply to its output.

# Where the listed-prefix data lives: next to this file, NOT under GRID_DIR,
# because mock-grid tests run the real script against throwaway grids.
_SKILL_EXCLUDES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skill-excludes.txt"

# _skill_git <repo-dir> <git args...>: git with every repository-selecting variable removed.
# An inherited GIT_DIR / GIT_INDEX_FILE (a git hook's environment) would make git answer for
# some other repository, and discovery would silently come back empty or wrong.
_skill_git() {
  local dir="$1"; shift
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_PREFIX \
    git -C "$dir" "$@"
}

# _skill_has_linebreak <path>: true when the path holds a CR or LF. Warns once per path.
_skill_has_linebreak() {
  case "$1" in
    *$'\n'*|*$'\r'*)
      printf 'find-skill-mds: skipping a path that contains a line break: %q\n' "$1" >&2
      return 0 ;;
  esac
  return 1
}

# _skill_excluded <repo-name> <relative-path>
# Returns 0 (true) when the path must be dropped, 1 when it is kept.
# bash 3.2-safe: only [[ =~ ]] with the regex held in a variable, no mapfile.
_skill_excluded() {
  local repo="$1" rel="$2" first rest second row_repo row_prefix
  # xx-YY / xx_YY (region) or xx-Hans / xx-Hant (script): an upper-case second part.
  local locale_re='^[a-z]{2}[-_]([A-Z]{2}|Hans|Hant)$'
  # Bare codes: only these two-letter names are locales (so docs/qa, docs/go stay skills).
  local locale_codes=" ar bn cs da de el en es fa fi fr he hi hu id it ja ko ms nl no pl pt ro ru sv ta th tr uk vi zh "

  # Rule 4: a vendored copy (node_modules anywhere in the path).
  case "/$rel" in */node_modules/*) return 0 ;; esac

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
        case "$locale_codes" in *" $second "*) return 0 ;; esac
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
  if [ -e "$root/.git" ] && _skill_git "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # -z: NUL-delimited, safe for any filename. Pathspecs: root-level + nested.
    _skill_git "$root" ls-files -z -- 'SKILL.md' '*/SKILL.md' |
      while IFS= read -r -d '' f; do
        # Skip tracked-but-deleted files (ls-files lists the index, not disk), and a
        # tracked SKILL.md that is a symlink: it may point at a file outside the repo.
        [ -f "$root/$f" ] && [ ! -L "$root/$f" ] || continue
        _skill_has_linebreak "$f" && continue
        _skill_excluded "$repo" "$f" && continue
        printf '%s/%s\n' "$root" "$f"
      done
  else
    # -type f: a directory named SKILL.md, a dangling link and a symlink are not skills
    # (the git branch drops them the same way). -print0 / sorted so the order is stable.
    find "$root" -type f -name SKILL.md -not -path '*/.git/*' -print0 2>/dev/null |
      while IFS= read -r -d '' p; do
        _skill_has_linebreak "$p" && continue
        rel="${p#"$root"/}"
        _skill_excluded "$repo" "$rel" && continue
        printf '%s\n' "$p"
      done | LC_ALL=C sort
  fi
}
