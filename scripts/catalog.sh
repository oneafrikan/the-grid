#!/usr/bin/env bash
#
# catalog.sh — generate a human-readable catalogue of every wired skill.
#
# Scans every SKILL.md (root-owned + submodules), pulls `name` and
# `description` from the YAML frontmatter, and writes SKILLS.md grouped by
# source. Output is deterministic (entries sorted by name, no timestamp) so
# re-running produces an identical file unless the skills themselves change.
#
# Usage:
#   bash catalog.sh            # write SKILLS.md in the repo root
#   bash catalog.sh /tmp/x.md  # write somewhere else (used by tests)
#
# Re-run after adding, editing, or updating skills — same idea as wire.sh.

set -euo pipefail

# Repo root: parent of scripts/ unless GRID_DIR overrides it.
GRID_DIR="${GRID_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${1:-$GRID_DIR/SKILLS.md}"

# --- Parse one SKILL.md → prints "name<TAB>summary" ------------------------
# Handles inline, quoted, folded (>) and block (|) YAML scalars for the
# description, plus plain multi-line continuations. The "summary" is the first
# sentence of the description, capped for readability.
parse_skill() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN { fm=0; coll=0; name=""; desc="" }
    {
      # Frontmatter fence: first --- opens, second --- closes.
      if ($0 ~ /^---[[:space:]]*$/) {
        if (fm==0) { fm=1; next }
        else if (fm==1) { fm=2; exit }
      }
      if (fm!=1) next

      # Collecting continuation lines of a description block.
      if (coll==1) {
        if ($0 ~ /^[[:space:]]/) { desc=desc " " trim($0); next }
        else { coll=0 }   # de-indented line ends the block; re-parse it below
      }

      if ($0 ~ /^name:/) {
        v=$0; sub(/^name:[[:space:]]*/,"",v); v=trim(v)
        gsub(/^["'\'']|["'\'']$/,"",v); name=v; next
      }
      if ($0 ~ /^description:/) {
        v=$0; sub(/^description:[[:space:]]*/,"",v); v=trim(v)
        # Block/folded indicators (>, |, with optional +/-) → gather next lines.
        if (v ~ /^[>|][+-]?$/ || v=="") { coll=1; desc="" }
        else { gsub(/^["'\'']|["'\'']$/,"",v); desc=v; coll=1 }
        next
      }
    }
    END {
      desc=trim(desc)
      # Quick summary = first sentence (up to ". "), else the whole thing.
      summary=desc
      if (match(desc, /\. /)) summary=substr(desc, 1, RSTART)
      summary=trim(summary)
      # Cap length so the catalogue stays skimmable.
      if (length(summary) > 200) summary=substr(summary,1,199) "\xe2\x80\xa6"
      print name "\t" summary
    }
  ' "$1"
}

# --- Emit a markdown section for a list of skill dirs ----------------------
# Reads NUL-free SKILL.md paths on stdin (one per line), sorts by skill name,
# prints "- **name** — summary" bullets. Returns the count via a global.
SECTION_COUNT=0
emit_section() {
  local title="$1"; shift
  local lines=() path name summary base
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # `|| true`: malformed/empty community SKILL.md files make read hit EOF and
    # return non-zero; tolerate it (fallbacks below handle the empty values).
    name=""; summary=""
    IFS=$'\t' read -r name summary < <(parse_skill "$path") || true
    base="$(basename "$(dirname "$path")")"
    [ -n "$name" ] || name="$base"                 # fall back to dir name
    [ -n "$summary" ] || summary="_(no description)_"
    # Sort key is the skill name (case-insensitive), payload is the bullet.
    lines+=("$(printf '%s\t- **%s** — %s' "$name" "$name" "$summary")")
  done
  SECTION_COUNT=${#lines[@]}
  printf '## %s — %s\n\n' "$title" "$SECTION_COUNT"
  if [ "$SECTION_COUNT" -gt 0 ]; then
    printf '%s\n' "${lines[@]}" | sort -f | cut -f2-
  else
    printf '_none_\n'
  fi
  printf '\n'
}

# --- Find SKILL.md files under a submodule, skipping a repo-root SKILL.md ---
# Mirrors wire.sh: a SKILL.md sitting directly at the repo root (gstack style)
# is a repo marker, not a wired skill, so it's excluded from the catalogue too.
find_skills() {
  local root="${1%/}"
  find "$root" -name SKILL.md -not -path '*/.git/*' 2>/dev/null | while IFS= read -r p; do
    [ "$(dirname "$p")" = "$root" ] && continue
    printf '%s\n' "$p"
  done
}

# --- Build the document into a buffer, then write once ---------------------
# Total = every SKILL.md minus repo-root markers (which wire.sh skips).
all_md=$(find "$GRID_DIR" -name SKILL.md -not -path '*/.git/*' | wc -l | tr -d ' ')
repo_roots=0
for r in "$GRID_DIR"/repos/*/; do
  if [ -f "${r%/}/SKILL.md" ]; then repo_roots=$((repo_roots + 1)); fi
done
root_owned=0
for d in "$GRID_DIR/skills"/*/; do
  if [ -f "${d%/}/SKILL.md" ]; then root_owned=$((root_owned + 1)); fi
done
total=$((all_md - repo_roots))

# Wiring allowlist (same file wire.sh uses) — to label wired vs library repos.
# Supports two entry formats:
#   repo-name          → whole-repo wired
#   repo-name/skill    → only that skill wired (partial)
WIRE_ALLOWLIST_FILE="$GRID_DIR/wired-submodules.txt"
WIRED_REPOS=()
WIRED_SKILLS=()
wire_all_repos=1
if [ -f "$WIRE_ALLOWLIST_FILE" ]; then
  wire_all_repos=0
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    if [[ "$line" == */* ]]; then
      WIRED_SKILLS+=("$line")
    else
      WIRED_REPOS+=("$line")
    fi
  done < "$WIRE_ALLOWLIST_FILE"
fi
repo_is_wired() {
  [ "$wire_all_repos" -eq 1 ] && return 0
  local n="$1" r
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && return 0; done
  return 1
}
skill_is_wired() {
  local entry="$1/$2" s
  for s in "${WIRED_SKILLS[@]:-}"; do [ "$s" = "$entry" ] && return 0; done
  return 1
}
repo_has_skill_entries() {
  local repo="$1" s
  for s in "${WIRED_SKILLS[@]:-}"; do
    [[ "$s" == "$repo/"* ]] && return 0
  done
  return 1
}

# Pre-pass: tally wired vs library skills for the header summary.
# Partially-wired repos contribute some skills to each bucket.
wired_skill_count=0; library_skill_count=0
for repo in "$GRID_DIR"/repos/*/; do
  [ -d "$repo" ] || continue
  name="$(basename "$repo")"
  if repo_is_wired "$name"; then
    c=$(find_skills "$repo" | wc -l | tr -d ' ')
    wired_skill_count=$((wired_skill_count + c))
  elif repo_has_skill_entries "$name"; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if skill_is_wired "$name" "$(basename "$(dirname "$p")")"; then
        wired_skill_count=$((wired_skill_count + 1))
      else
        library_skill_count=$((library_skill_count + 1))
      fi
    done < <(find_skills "$repo")
  else
    c=$(find_skills "$repo" | wc -l | tr -d ' ')
    library_skill_count=$((library_skill_count + c))
  fi
done
wired_live=$((root_owned + wired_skill_count))

{
  printf '# the-grid — skill catalogue\n\n'
  printf '> Generated by `catalog.sh` from each skill'\''s `SKILL.md` frontmatter.\n'
  printf '> **Do not edit by hand** — re-run `bash catalog.sh` after adding or updating skills.\n\n'
  printf '**%s skills indexed** — %s wired live (%s root-owned + %s from allowlisted repos), %s in library (indexed & searchable, not wired).\n\n' \
    "$total" "$wired_live" "$root_owned" "$wired_skill_count" "$library_skill_count"
  printf 'Library repos are part of the-grid as an index/hub — browse here or search via skill-scout. Promote one to wired in `wired-submodules.txt`.\n\n'

  # Root-owned skills first (skills/ dir).
  emit_section "Root (owned / edited)" < <(
    for d in "$GRID_DIR/skills"/*/; do
      [ -f "$d/SKILL.md" ] && printf '%s\n' "$d/SKILL.md"
    done
  )

  # WIRED submodules: full per-skill detail.
  # Whole-repo entries show all skills; per-skill entries show only the wired subset.
  reference_repos=()
  for repo in "$GRID_DIR"/repos/*/; do
    [ -d "$repo" ] || continue
    name="$(basename "$repo")"
    if repo_is_wired "$name"; then
      paths=()
      while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(find_skills "$repo")
      if [ "${#paths[@]}" -eq 0 ]; then reference_repos+=("$name"); continue; fi
      emit_section "repos/$name (wired)" < <(printf '%s\n' "${paths[@]}")
    elif repo_has_skill_entries "$name"; then
      paths=()
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        skill_is_wired "$name" "$(basename "$(dirname "$p")")" && paths+=("$p")
      done < <(find_skills "$repo")
      [ "${#paths[@]}" -eq 0 ] && continue
      emit_section "repos/$name (partial)" < <(printf '%s\n' "${paths[@]}")
    fi
  done

  # LIBRARY submodules: counts only — not enumerated per-skill (could be 1000s).
  # Browse the repo, or use skill-scout to search them on demand.
  # Partially-wired repos are shown in the wired section above; skip them here.
  lib_lines=()
  for repo in "$GRID_DIR"/repos/*/; do
    [ -d "$repo" ] || continue
    name="$(basename "$repo")"
    repo_is_wired "$name" && continue
    repo_has_skill_entries "$name" && continue
    c=$(find_skills "$repo" | wc -l | tr -d ' ')
    if [ "$c" -eq 0 ]; then reference_repos+=("$name"); continue; fi
    lib_lines+=("$(printf '%s\t- **repos/%s** — %s skills' "$name" "$name" "$c")")
  done
  if [ "${#lib_lines[@]}" -gt 0 ]; then
    printf '## Library submodules (indexed, not wired)\n\n'
    printf 'Not enumerated per-skill here (too many) — browse the repo or search with skill-scout:\n\n'
    printf '%s\n' "${lib_lines[@]}" | sort -f | cut -f2-
    printf '\n'
  fi

  # Footer: reference-only submodules (indexes with nothing to wire).
  if [ "${#reference_repos[@]}" -gt 0 ]; then
    printf '## Reference submodules (no wired skills)\n\n'
    printf 'Kept for reference — these are indexes/awesome-lists, not skill collections:\n\n'
    printf '%s\n' "${reference_repos[@]}" | sort -f | while IFS= read -r r; do
      printf -- '- **repos/%s**\n' "$r"
    done
    printf '\n'
  fi
} > "$OUT"

echo "Wrote $OUT ($total skills)."
