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
#   bash scripts/catalog.sh               # write SKILLS.md in the repo root
#   bash scripts/catalog.sh /tmp/x.md     # write somewhere else (used by tests)
#   bash scripts/catalog.sh --check       # write nothing; exit 0 current, 1 stale, 2 the check itself failed
#   bash scripts/catalog.sh -h | --help   # this usage; writes nothing
#   GRID_BASELINE=<file> bash scripts/catalog.sh   # render from that baseline (gate.sh and wire.sh pin the tracked example)
#
# A leading dash is always an option: an unknown one is a usage error (exit 2) before any file
# is touched. A non-dash argument is the output path.
#
# Re-run after adding, editing, or updating skills — same idea as wire.sh.

set -euo pipefail

# Repo root: parent of scripts/ unless GRID_DIR overrides it.
GRID_DIR="${GRID_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# find_skill_mds: tracked-only SKILL.md discovery, shared with wire.sh.
# shellcheck source=lib/find-skill-mds.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/find-skill-mds.sh"

# usage: print the Usage block of this file's header (the single source of the text).
usage() { sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# A leading dash is always an option, never an output path: `--chek` or `--help` must not
# create a file of that name. A non-dash argument is the output path (wire.sh passes one).
CHECK=0
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "catalog.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    # An empty path must not fall through to the default SKILLS.md (OUT="" reads as unset).
    "")        echo "catalog.sh: empty output path" >&2; usage >&2; exit 2 ;;
    *)         [ -z "$OUT" ] || { echo "catalog.sh: more than one output path" >&2; usage >&2; exit 2; }
               OUT="$1" ;;
  esac
  shift
done

# --check: render to a temp file and diff against the committed SKILLS.md
# instead of overwriting it. Read-only drift detector for hooks / CI.
# Exit status: 0 current, 1 STALE (the diff says so), 2 anything else (no temp file, a render
# or compare failure), so a caller can tell "regenerate it" from "the check itself broke".
CHECK_DONE=0
if [ "$CHECK" = 1 ]; then
  [ -z "$OUT" ] || { echo "catalog.sh: --check writes nothing and takes no output path" >&2; usage >&2; exit 2; }
  OUT="$(mktemp)" || { echo "catalog.sh: --check cannot create a temp file (is TMPDIR usable?)" >&2; exit 2; }
  # A non-zero exit before the comparison finished is an error (2), whatever set -e saw.
  check_exit() {
    local rc=$?
    rm -f "$OUT"
    if [ "$CHECK_DONE" = 0 ] && [ "$rc" -ne 0 ]; then
      echo "catalog.sh: --check failed before it could compare (exit $rc)" >&2
      exit 2
    fi
  }
  trap check_exit EXIT
else
  OUT="${OUT:-$GRID_DIR/SKILLS.md}"
fi

# --- Parse one SKILL.md → prints "name<TAB>summary" ------------------------
# Handles inline, quoted, folded (>) and block (|) YAML scalars for the
# description, plus plain multi-line continuations. The "summary" is the first
# sentence of the description, capped for readability.
#
# All sorts are pinned to LC_ALL=C (byte-order collation) so the output is
# identical on every machine — without this, macOS (C collation) and Linux
# (UTF-8 dictionary collation) order punctuation differently (e.g. "web-…"
# vs "webapp-…"), causing spurious cross-machine diffs on every re-run.
#
# The awk is pinned to LC_ALL=C too: substr()/length() count BYTES under mawk
# (Ubuntu default) but CHARACTERS under gawk/macOS awk in a UTF-8 locale, so
# the 200-char cap cut multibyte descriptions (em dashes etc.) at different
# points per machine. Under LC_ALL=C every awk counts bytes; the cut is then
# backed off to a UTF-8 character boundary so it never splits a character.
#
# Agreement with scripts/lib/skill_frontmatter.py (the reader wire.sh uses): the same
# file must give the same name and description from either, so the awk follows its
# rules for the inputs that used to differ (tests/test_catalog.bats pins each):
#   - the frontmatter opens on LINE 1 (a leading BOM is ignored) and closes at the next
#     line that is only `---` (surrounding whitespace allowed); an UNCLOSED fence is no
#     frontmatter at all, so the skill falls back to its directory name;
#   - the FIRST `name:` and the FIRST `description:` win (a later duplicate is ignored);
#   - a plain (unquoted, non-block) description ends at ` #` (a YAML comment).
# Not aligned, on purpose (about 1320 python spawns would slow the gate): backslash
# escapes inside a double-quoted description (the python reader decodes \" and \\, this
# one keeps them) and a multi-line `name: |` (python folds the continuation lines, this
# reads the first line only). No wired skill uses either.
parse_skill() {
  LC_ALL=C awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN { fm=0; coll=0; gotname=0; gotdesc=0; plain=0; name=""; desc="" }
    {
      if (NR==1) sub(/^(\357\273\277)+/, "")      # leading UTF-8 BOM(s)
      # Frontmatter fence: only line 1 opens (a fence anywhere else leaves fm at 0: no
      # frontmatter), the next fence line closes.
      if ($0 ~ /^[[:space:]]*---[[:space:]]*$/) {
        if (NR==1) { fm=1; next }
        else if (fm==1) { fm=2; exit }
      }
      if (fm!=1) next

      # Collecting continuation lines of a description block.
      if (coll==1) {
        if ($0 ~ /^[[:space:]]/) { desc=desc " " trim($0); next }
        else { coll=0 }   # de-indented line ends the block; re-parse it below
      }

      if ($0 ~ /^name[[:space:]]*:/) {
        if (gotname) next                          # first name: wins
        gotname=1
        v=$0; sub(/^name[[:space:]]*:[[:space:]]*/,"",v); v=trim(v)
        if (v !~ /^["'\'']/) { sub(/[[:space:]]+#.*$/,"",v); v=trim(v) }   # plain: " #" is a comment
        gsub(/^["'\'']|["'\'']$/,"",v); name=v; next
      }
      if ($0 ~ /^description[[:space:]]*:/) {
        if (gotdesc) next                          # first description: wins
        gotdesc=1
        v=$0; sub(/^description[[:space:]]*:[[:space:]]*/,"",v); v=trim(v)
        # Block/folded indicators (>, |, with optional +/-/digit) → gather next lines.
        if (v ~ /^[>|][-+0-9]*$/ || v=="") { coll=1; desc=""; plain=(v=="") }
        else { plain=(v !~ /^["'\'']/); gsub(/^["'\'']|["'\'']$/,"",v); desc=v; coll=1 }
        next
      }
    }
    END {
      # An unclosed fence (or no fence) is no frontmatter: print an empty record, so the
      # caller falls back to the directory name, as it does for skill_frontmatter.py.
      if (fm!=2) { name=""; desc=""; plain=0 }
      desc=trim(desc)
      # A plain scalar ends at " #" (YAML comment); quoted and block scalars keep their #.
      if (plain) { sub(/[[:space:]]+#.*$/,"",desc); desc=trim(desc) }
      # Quick summary = first sentence (up to ". "), else the whole thing.
      summary=desc
      if (match(desc, /\. /)) summary=substr(desc, 1, RSTART)
      summary=trim(summary)
      # Cap length so the catalogue stays skimmable.
      if (length(summary) > 200) {
        n=199
        # Back off while the first dropped byte is a UTF-8 continuation byte
        # (0x80-0xBF) — i.e. the cut would land mid-character.
        while (n>0 && substr(summary,n+1,1) ~ /[\200-\277]/) n--
        summary=substr(summary,1,n) "\xe2\x80\xa6"
      }
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
    printf '%s\n' "${lines[@]}" | LC_ALL=C sort -f | cut -f2-
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
  local repo_name; repo_name="$(basename "$root")"
  find_skill_mds "$root" | while IFS= read -r p; do
    [ "$(dirname "$p")" = "$root" ] && continue
    # Drop `-repo/skill` subtractions so the catalogue matches what wire.sh
    # actually links (both the per-skill listing and the headline counts).
    skill_is_denied "$repo_name" "$(basename "$(dirname "$p")")" && continue
    printf '%s\n' "$p"
  done
}

# --- Build the document into a buffer, then write once ---------------------
# Count root-owned skills (skills/ dir only — not agent-factory, not repo root).
root_owned=0
for d in "$GRID_DIR/skills"/*/; do
  if [ -f "${d%/}/SKILL.md" ]; then root_owned=$((root_owned + 1)); fi
done

# Baseline manifest (same baseline wire.sh uses) — to label wired vs library repos.
# catalog.sh reads the BASELINE only (not per-machine overlays), so SKILLS.md is a
# deterministic, machine-agnostic index. Supports two entry formats:
#   repo-name          → whole-repo wired
#   repo-name/skill    → only that skill wired (partial)
#
# Subtractions (`-repo`, `-repo/skill`) are honoured too — a whole-repo entry
# minus a specific skill is a real baseline pattern (repos/openspec wires its
# workflow skills but not the maintainer-only release one), and without this
# SKILLS.md would advertise a skill wire.sh never links. `project:` entries gate
# composed agent-factory output, not submodules, so they're skipped.
#
# GRID_BASELINE pins which baseline file is read (the same override wire.sh, audit.sh and
# budget.py take). The committed SKILLS.md is rendered from the TRACKED example baseline
# (gate.sh and wire.sh pin it), so CI and every machine agree; with no pin the personal,
# gitignored baseline is used as before. A pin that names a missing file is an error, not a
# silent "wire everything" render.
if [ -n "${GRID_BASELINE:-}" ] && [ ! -f "$GRID_BASELINE" ]; then
  echo "catalog: GRID_BASELINE names a missing file: $GRID_BASELINE" >&2
  exit 2
fi
WIRE_ALLOWLIST_FILE="${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}"
WIRED_REPOS=()
WIRED_SKILLS=()
DENY_REPOS=()
DENY_SKILLS=()
wire_all_repos=1
if [ -f "$WIRE_ALLOWLIST_FILE" ]; then
  wire_all_repos=0
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    case "$line" in
      project:*|-project:*) continue ;;
      *:*) continue ;;   # typed entries (rules:, -rules:, harness:, hook:, ...) are not repos
      -*/*) DENY_SKILLS+=("${line#-}") ;;
      -*)   DENY_REPOS+=("${line#-}") ;;
      */*)  WIRED_SKILLS+=("$line") ;;
      *)    WIRED_REPOS+=("$line") ;;
    esac
  done < "$WIRE_ALLOWLIST_FILE"
fi
repo_is_denied()  { local n="$1" r; for r in "${DENY_REPOS[@]:-}";    do [ "$r" = "$n" ] && return 0; done; return 1; }
skill_is_denied() { local e="$1/$2" s; for s in "${DENY_SKILLS[@]:-}"; do [ "$s" = "$e" ] && return 0; done; return 1; }
repo_is_wired() {
  repo_is_denied "$1" && return 1
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
  # else: pure library repo — skills shown as counts in the Library section,
  # but not added to the headline total (could be thousands from community repos).
  fi
done
wired_live=$((root_owned + wired_skill_count))
# Total = wired + unlisted skills from partially-wired repos.
# Pure library repos are excluded from the headline to avoid explosion when
# community submodules are initialized (they can contain thousands of skills).
total=$((wired_live + library_skill_count))

{
  printf '# the-grid — skill catalogue\n\n'
  printf '> Generated by `catalog.sh` from each skill'\''s `SKILL.md` frontmatter.\n'
  printf '> **Do not edit by hand** — re-run `bash scripts/catalog.sh` after adding or updating skills.\n\n'
  printf '**%s skills indexed** — %s wired live (%s root-owned + %s from allowlisted repos), %s in library (indexed & searchable, not wired).\n\n' \
    "$total" "$wired_live" "$root_owned" "$wired_skill_count" "$library_skill_count"
  printf 'Library repos are part of the-grid as an index/hub — browse here or search via skill-scout. Promote one to wired in `baseline-submodules.txt`.\n\n'

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
    printf '%s\n' "${lib_lines[@]}" | LC_ALL=C sort -f | cut -f2-
    printf '\n'
  fi

  # Footer: reference-only submodules (indexes with nothing to wire).
  if [ "${#reference_repos[@]}" -gt 0 ]; then
    printf '## Reference submodules (no wired skills)\n\n'
    printf 'Kept for reference — these are indexes/awesome-lists, not skill collections:\n\n'
    printf '%s\n' "${reference_repos[@]}" | LC_ALL=C sort -f | while IFS= read -r r; do
      printf -- '- **repos/%s**\n' "$r"
    done
    printf '\n'
  fi
} > "$OUT"

if [ "$CHECK" = 1 ]; then
  # diff exits 0 identical, 1 different, 2 trouble (for example no SKILLS.md to compare to).
  diff_rc=0
  diff -u "$GRID_DIR/SKILLS.md" "$OUT" >&2 || diff_rc=$?
  CHECK_DONE=1
  case "$diff_rc" in
    0) echo "SKILLS.md is up to date ($total skills)."; exit 0 ;;
    1) echo "SKILLS.md is stale — run: bash scripts/catalog.sh" >&2; exit 1 ;;
    *) echo "catalog.sh: --check could not compare against $GRID_DIR/SKILLS.md" >&2; exit 2 ;;
  esac
fi

echo "Wrote $OUT ($total skills)."
