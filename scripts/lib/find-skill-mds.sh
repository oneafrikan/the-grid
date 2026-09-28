#!/usr/bin/env bash
#
# find-skill-mds.sh — shared by wire.sh and catalog.sh (source it, don't run it).
#
# find_skill_mds <repo-dir> prints the path of every SKILL.md the repo ships.
#
# Why not plain `find`: some submodules generate untracked, gitignored copies
# of their skills at setup time (gstack writes ~54 per host into .slate/,
# .opencode/, .kiro/, .hermes/ ... — 482 stray SKILL.md on guide-server).
# A raw find counts and wires those, so SKILLS.md flipped between ~239 and ~725
# depending on which machine ran wire.sh last. Asking git for tracked files
# gives the same answer on every machine, while still honouring skills that
# really are tracked inside dot-dirs (openspec, ponytail, ...).
#
# Fallback: a directory that is not its own git checkout (an uninitialised
# submodule, or a test fixture) uses plain find, as before.

find_skill_mds() {
  local root="${1%/}" f
  # `-e .git` (file or dir) = root is its own checkout, not just a subdir of
  # the parent repo, so ls-files won't silently answer for the wrong repo.
  if [ -e "$root/.git" ] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # -z: NUL-delimited, safe for any filename. Pathspecs: root-level + nested.
    git -C "$root" ls-files -z -- 'SKILL.md' '*/SKILL.md' |
      while IFS= read -r -d '' f; do
        # Skip tracked-but-deleted files (ls-files lists the index, not disk).
        [ -f "$root/$f" ] && printf '%s/%s\n' "$root" "$f"
      done
  else
    find "$root" -name SKILL.md -not -path '*/.git/*' 2>/dev/null
  fi
}
