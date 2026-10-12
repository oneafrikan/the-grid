#!/usr/bin/env bash
# wire.sh — link skills from the-grid into the Claude skills directory.
#
# Precedence: root-level skills (yours) override same-named repo skills.
# Order: repos wired first, root-level wired second so they win.
#
# Override defaults via env vars (used by tests):
#   GRID_DIR    — root of the-grid repo  (default: parent of scripts/)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
#   AGENTS_DIR  — Claude subagents directory (default: ~/.claude/agents)
#   GRID_HOST   — machine key for the overlay (default: hostname -s)
#   RULES_DIR   — Claude rules directory (default: ~/.claude/rules). Only $RULES_DIR/grid/
#                 is grid-owned: `rules:<pack>` manifest entries symlink each rules/<pack>/*.md
#                 (never README.md) to $RULES_DIR/grid/<pack>/. When GRID_DRY_HOME is set it
#                 FORCES RULES_DIR=$GRID_DRY_HOME/.claude/rules, ignoring any inherited
#                 value (see the dry-home block below), so no dry run can reach the real one.
#   GRID_BASELINE — baseline manifest file (default: $GRID_DIR/baseline-submodules.txt)
#   GRID_SKIP_CATALOG=1 — don't regenerate SKILLS.md at the end (used by --check)
#   GRID_SKIP_AUDIT=1 — skip the pre-wire audit (step 0). Set by audit.sh's own dry run
#                   so the audit does not recurse into itself; not for everyday use.
#   GRID_AUDIT=warn — a high-severity audit finding prints a warning and wiring continues
#                   (default: it blocks, exit 3, before any link is touched)
#   GRID_NO_CATALOG=1 — skip ONLY the SKILLS.md refresh (step 4); .wired.manifest is still
#                   written. Set by `grid install`: on a machine without submodules most
#                   library repos are empty, so a refresh would rewrite the tracked SKILLS.md.
#   CLAUDE_CONFIG_DIR — Claude config dir whose settings.json receives the machine-level
#                   hooks (default: ~/.claude). Wiring hooks is ON by default for
#                   auto-handoff: `-hook:auto-handoff` in the manifest (baseline, machine
#                   overlay or local overlay; the last file to mention it wins) turns it
#                   off and removes the generated entry; `hook:auto-handoff` turns it
#                   back on. Only entries the grid generated are touched.
#   GRID_DRY_HOME — dry-run home: when set, HOME is exported to it and SKILLS_DIR,
#                   AGENTS_DIR, CLAUDE_CONFIG_DIR, RULES_DIR and GRID_HARNESS_HOME
#                   are FORCED under it (inherited values ignored), and nothing is
#                   written to the repo (SKILLS.md, .wired.manifest). RULES_DIR and
#                   GRID_HARNESS_HOME are forced under it; every later home-derived
#                   target (~/.grid state) MUST be forced under it in this same block.
#                   Every dry-run caller sets ONLY this (plus GRID_HOST/GRID_BASELINE).
#
#   GRID_HARNESS  — comma list of non-Claude harnesses to wire for THIS run (names from
#                   scripts/lib/harnesses.txt, e.g. codex,opencode). When non-empty it
#                   REPLACES the manifest's harness:<name> set, so a one-off run
#                   deactivates (and tears down) every other harness. Unknown name: exit 2.
#   GRID_HARNESS_HOME — base for every non-Claude harness dir (default: $HOME). Tests point
#                   it at a temp dir; GRID_DRY_HOME overrides it (see above).
#
# Exit codes: 0 wired | 1 --check found drift | 2 bad harness name / python3 missing
#             for an active harness (nothing changed) | 3 blocked by the audit (nothing changed)
#
# Usage:
#   bash wire.sh           # wire (idempotent)
#   bash wire.sh --check   # change nothing; exit 1 if live links differ from
#                          # what a fresh wire would create
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# Canonical spelling: physical path, no trailing slash. Every link wire creates carries
# this spelling, and ownership (target_is_ours) is decided on resolved paths, so a clone
# reached through a symlink, a trailing slash or a ".." no longer splits the grid's links
# across two spellings that neither teardown nor --check could match.
GRID_DIR="$(cd "$GRID_DIR" 2>/dev/null && pwd -P)" || { echo "wire: GRID_DIR is not a directory" >&2; exit 2; }

# GRID_DRY_HOME: redirect EVERY home-derived target into a throwaway home.
# Values are forced, not defaulted, so an inherited SKILLS_DIR or
# CLAUDE_CONFIG_DIR from the operator's shell cannot leak a dry run into the
# real home. RULES_DIR (rule-packs) and GRID_HARNESS_HOME (harness paths) are
# forced here too; any later home target (~/.grid state) MUST be added here.
if [ -n "${GRID_DRY_HOME:-}" ]; then
  mkdir -p "$GRID_DRY_HOME"
  export HOME="$GRID_DRY_HOME"
  SKILLS_DIR="$GRID_DRY_HOME/.claude/skills"
  AGENTS_DIR="$GRID_DRY_HOME/.claude/agents"
  export CLAUDE_CONFIG_DIR="$GRID_DRY_HOME/.claude"
  export RULES_DIR="$GRID_DRY_HOME/.claude/rules"
  export GRID_HARNESS_HOME="$GRID_DRY_HOME"
  export GRID_SKIP_CATALOG=1   # no SKILLS.md / .wired.manifest writes either
fi

# find_skill_mds: tracked-only SKILL.md discovery, shared with catalog.sh.
# shellcheck source=lib/find-skill-mds.sh
. "$(dirname "$0")/lib/find-skill-mds.sh"
# Harness registry helpers and the portability filter for non-Claude skills dirs.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# Two harnesses sharing one rules_file is a registry error, refused before anything is wired.
harness_registry_check || { echo "wire: the harness registry is invalid (see above)" >&2; exit 2; }
# shellcheck source=lib/skill-portable.sh
. "$(dirname "$0")/lib/skill-portable.sh"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.claude/agents}"
RULES_DIR="${RULES_DIR:-$HOME/.claude/rules}"
GRID_HOST="${GRID_HOST:-$(hostname -s 2>/dev/null || uname -n 2>/dev/null | cut -d. -f1 || echo unknown)}"

# --- harness registry: the distinct dirs of every NON-claude harness ----------------
# Raw registry values (the "~/..." form, which is also what the manifest rows show).
# ALL registry harnesses count, active or not: a harness that was deactivated must
# have its grid links torn down, and --check must see stale links in its dirs.
# Claude's own dirs stay on SKILLS_DIR / AGENTS_DIR exactly as before.
in_list() { local n="$1" x; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
HARNESS_SKILL_DIRS=()
HARNESS_AGENT_DIRS=()
while IFS= read -r h_name; do
  [ "$h_name" = claude ] && continue
  h_dir="$(harness_field "$h_name" skills_dir)"
  if [ "$h_dir" != "-" ] && ! in_list "$h_dir" "${HARNESS_SKILL_DIRS[@]:-}"; then HARNESS_SKILL_DIRS+=("$h_dir"); fi
  h_dir="$(harness_field "$h_name" agents_dir)"
  if [ "$h_dir" != "-" ] && ! in_list "$h_dir" "${HARNESS_AGENT_DIRS[@]:-}"; then HARNESS_AGENT_DIRS+=("$h_dir"); fi
done < <(harness_names)

# --- ownership: is a link target inside the grid? ---------------------------------
# lex_norm <abs path>: collapse "//", "." and ".." lexically into NORM (no forks).
lex_norm() {
  local part res="" parts
  IFS=/ read -r -d '' -a parts < <(printf '%s' "$1") || true
  for part in "${parts[@]:-}"; do
    case "$part" in
      ''|.) ;;
      ..)   res="${res%/*}" ;;
      *)    res="$res/$part" ;;
    esac
  done
  NORM="${res:-/}"
}

# target_is_ours <link target>: true when the target RESOLVES to a path under GRID_DIR.
# Resolution, not a string prefix: the target's parent is resolved physically (cd -P, so
# symlinks and ".." in it are followed) and the last component is appended unresolved
# (a link's own target is what is compared, not where that finally ends up). When the
# parent does not exist (a dangling grid link) the path is normalised lexically instead.
# Only absolute targets can be ours: wire writes nothing else, so a relative one is
# foreign. "$GRID_DIR/../x" is textually under the grid and physically outside it: not ours.
target_is_ours() {
  local t="$1" dir base phys res=""
  case "$t" in /*) ;; *) return 1 ;; esac
  while [ "${t%/}" != "$t" ] && [ -n "${t%/}" ]; do t="${t%/}"; done   # trailing slashes
  base="${t##*/}"
  case "$base" in
    .|..)                       # the target IS a directory spelled "." / "..": resolve it whole
      if phys="$(cd -P "$t" 2>/dev/null && pwd -P)"; then res="$phys"; fi ;;
    *)
      dir="${t%/*}"; [ -n "$dir" ] || dir=/
      if phys="$(cd -P "$dir" 2>/dev/null && pwd -P)"; then
        [ "$phys" = / ] && phys=""
        res="$phys/$base"
      fi ;;
  esac
  if [ -z "$res" ]; then lex_norm "$t"; res="$NORM"; fi   # parent missing: lexical
  case "$res" in "$GRID_DIR"/*) return 0 ;; esac
  return 1
}

# link_is_ours <path>: true when <path> is a symlink whose target is ours. Used by the link
# steps (wire_skill / wire_agent) and the --check shadow filter, so a foreign link, a dangling
# one or a real file at a grid name is never replaced.
link_is_ours() {
  [ -L "$1" ] || return 1
  local t
  t="$(readlink "$1")" || return 1
  target_is_ours "$t"
}

# --- --check: dry-run drift detector ----------------------------------------
# Wires into throwaway dirs with the same inputs, then compares the grid-owned
# symlinks (name -> target) against the live SKILLS_DIR / AGENTS_DIR. Foreign
# links and real dirs are ignored, exactly as the real run ignores them.
if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # The child wires into a dry home (GRID_DRY_HOME forces every target under
  # it and skips the catalog/manifest writes), not just two overridden dirs.
  GRID_DRY_HOME="$tmp/home" GRID_DIR="$GRID_DIR" GRID_HOST="$GRID_HOST" \
    bash "$0" >/dev/null
  chk_skills="$tmp/home/.claude/skills"; chk_agents="$tmp/home/.claude/agents"
  # "name -> target" lines for grid-owned links only, sorted (C locale: stable).
  # $2 (optional) = live dir: names shadowed there by a real dir/file, or by a link that
  # is not into the grid (foreign or dangling), are skipped, because a real wire skips
  # them too ("not managed") — they can never be drift.
  links() { # $1 = dir to list, $2 = live dir for the shadow filter
    [ -d "$1" ] || return 0
    # -H: follow the command-line dir if it is itself a symlink (a symlinked
    # skills dir), otherwise find lists nothing and drift is never reported.
    find -H "$1" -maxdepth 1 -type l | while IFS= read -r l; do
      t="$(readlink "$l")"; n="$(basename "$l")"
      if [ -n "${2:-}" ] && { [ -e "$2/$n" ] || [ -L "$2/$n" ]; } && ! link_is_ours "$2/$n"; then continue; fi
      if target_is_ours "$t"; then printf '%s -> %s\n' "$n" "$t"; fi
    done | LC_ALL=C sort
  }
  # Recursive twin of links() for the rules tree: rules are symlinks nested one level
  # down ($RULES_DIR/grid/<pack>/<topic>.md), which links() (-maxdepth 1) cannot see.
  # $1 = rules dir whose grid/ subtree is listed, $2 (optional) = live rules dir for
  # the same real-file shadow filter. Prints "pack/topic.md -> target".
  rule_links() {
    [ -d "$1/grid" ] || return 0
    find -H "$1/grid" -type l | while IFS= read -r l; do
      t="$(readlink "$l")"; n="${l#"$1"/grid/}"
      if [ -n "${2:-}" ] && [ -e "$2/grid/$n" ] && [ ! -L "$2/grid/$n" ]; then continue; fi
      if target_is_ours "$t"; then printf '%s -> %s\n' "$n" "$t"; fi
    done | LC_ALL=C sort
  }
  rc=0
  for kind in skills agents; do
    live="$SKILLS_DIR"; fresh="$chk_skills"
    if [ "$kind" = agents ]; then live="$AGENTS_DIR"; fresh="$chk_agents"; fi
    if ! diff <(links "$fresh" "$live") <(links "$live") >"$tmp/$kind.diff"; then
      echo "wire --check: $kind drift in $live ('<' = should exist, '>' = stale):" >&2
      cat "$tmp/$kind.diff" >&2
      rc=1
    fi
  done
  # Non-Claude harness dirs (every distinct registry dir, active or not). hlinks is
  # links() for these dirs: the shadow filter skips a name when the live path exists
  # (-e or -L) and is NOT a symlink into the grid, because wire_harness_link never
  # replaces such an entry (real dir/file, foreign or dangling symlink), so it can
  # never be drift. The fresh side lives under $tmp/home: GRID_DRY_HOME redirects every
  # registry path there, the live side resolves through harness_path as the real run does.
  hlinks() { # $1 = dir to list, $2 = live dir for the shadow filter
    [ -d "$1" ] || return 0
    find -H "$1" -maxdepth 1 -type l | while IFS= read -r l; do
      t="$(readlink "$l")"; n="$(basename "$l")"
      if [ -n "${2:-}" ] && { [ -e "$2/$n" ] || [ -L "$2/$n" ]; }; then
        lt="$(readlink "$2/$n" 2>/dev/null || true)"
        target_is_ours "$lt" || continue
      fi
      if target_is_ours "$t"; then printf '%s -> %s\n' "$n" "$t"; fi
    done | LC_ALL=C sort
  }
  for raw in "${HARNESS_SKILL_DIRS[@]:-}" "${HARNESS_AGENT_DIRS[@]:-}"; do
    [ -n "$raw" ] || continue
    if ! live="$(harness_path "$raw")"; then rc=1; continue; fi
    fresh="$( GRID_DRY_HOME="$tmp/home"; harness_path "$raw" )"
    if ! diff <(hlinks "$fresh" "$live") <(hlinks "$live") >"$tmp/harness.diff"; then
      echo "wire --check: harness drift in $live ('<' = should exist, '>' = stale):" >&2
      cat "$tmp/harness.diff" >&2
      rc=1
    fi
  done
  # Rule packs: same comparison for $RULES_DIR/grid. The dry-run child wrote under
  # $tmp/home/.claude/rules because GRID_DRY_HOME forces RULES_DIR there.
  if ! diff <(rule_links "$tmp/home/.claude/rules" "$RULES_DIR") <(rule_links "$RULES_DIR") >"$tmp/rules.diff"; then
    echo "wire --check: rules drift in $RULES_DIR/grid ('<' = should exist, '>' = stale):" >&2
    cat "$tmp/rules.diff" >&2
    rc=1
  fi
  # Rules delivery to the harness instruction files: the dry-run child left, per harness
  # that has one, "<name> TAB <active 0|1> TAB <packs csv>" in $tmp/home/.rules-wanted (one
  # source of truth for the manifest grammar). Repeat the decision against the LIVE files
  # with rules.py --check, which writes nothing; harness_rules_action is the same function
  # the real run uses, so the two cannot disagree. An absent or symlinked file is not drift.
  if [ -s "$tmp/home/.rules-wanted" ]; then
    while IFS=$'\t' read -r rw_name rw_active rw_csv; do
      rw_raw="$(harness_field "$rw_name" rules_file)"
      if ! rw_file="$(harness_path "$rw_raw")"; then rc=1; continue; fi
      rw_action="$(harness_rules_action "$rw_file" "$rw_active" "$rw_csv" "$rw_raw")"
      case "$rw_action" in
        emit|remove)
          [ "$rw_action" = remove ] && rw_csv=""
          rw_rc=0
          if ! command -v python3 >/dev/null 2>&1; then
            echo "wire --check: python3 not found; rules in $rw_file not checked" >&2
            continue
          fi
          rw_out="$(harness_rules_emit "$(harness_field "$rw_name" rules_harness)" "$rw_csv" "$rw_file" --check 2>&1)" || rw_rc=$?
          if [ "$rw_rc" = 3 ]; then
            # Over the cap is a skip, not drift (the real run warns and records it).
            echo "wire --check: rules ($rw_file): ${rw_out#rules.py emit: }" >&2
          elif [ "$rw_rc" != 0 ] && [ "$rw_action" = remove ] && [[ "$rw_out" == *"expected exactly one BEGIN"* ]]; then
            # A damaged block in a file of an inactive harness is a warning, never drift.
            echo "wire --check: rules ($rw_file): markers unbalanced, not checked" >&2
          elif [ "$rw_rc" != 0 ]; then
            echo "wire --check: rules drift in $rw_file ($rw_name):" >&2
            [ -z "$rw_out" ] || printf '%s\n' "$rw_out" >&2
            rc=1
          fi ;;
      esac
    done < "$tmp/home/.rules-wanted"
  fi
  # Machine-level hooks: the dry-run child above resolved the manifest and left the
  # list it would wire in $tmp/home/.hooks-wanted (one source of truth for the
  # hook:/-hook: grammar). Compare it with the LIVE settings file; writes nothing.
  # Same skip rule as the real wire: a mock or older grid without the emitter is skipped.
  if [ -f "$GRID_DIR/agent-factory/deploy_hooks.py" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "wire --check: python3 not found; hooks not checked" >&2
    elif ! env GRID_DIR="$GRID_DIR" python3 "$GRID_DIR/agent-factory/deploy_hooks.py" --user \
           --hooks "$(cat "$tmp/home/.hooks-wanted" 2>/dev/null || true)" --check; then
      rc=1
    fi
  fi
  [ "$rc" = 0 ] && echo "wire --check: live links match a fresh wire."
  exit "$rc"
fi

# --- Manifest: baseline + per-machine overlay + local (gitignored) overlay ----
# What gets wired is resolved from three layers, unioned in order:
#   1. baseline-submodules.txt   — wired on EVERY machine (the baseline, committed)
#   2. machines/<host>.txt       — THIS machine's overlay (host = GRID_HOST, committed)
#   3. machines/<host>.local.txt — THIS machine's LOCAL overlay (gitignored — for
#      project:<name> gates that must never appear in this repo's git history,
#      e.g. a private research desk composed from GRID_PRIVATE_ROLES_DIR)
# catalog.sh reads the BASELINE only, so SKILLS.md stays a deterministic,
# machine-agnostic index (clean cross-machine diffs); the overlay layers change
# the live symlink set, not the catalogue.
#
# Entry grammar (identical in both files):
#   repo                 → wire ALL skills in that submodule
#   repo/skill           → wire ONLY that skill
#   -repo  | -repo/skill → SUBTRACT (remove a baseline entry — overlay escape hatch)
#   project:<name>       → wire that composed agent-factory project's _claude-code output
#   -project:<name>      → un-gate a project
#   rules:<pack>         → wire rules/<pack>/*.md into $RULES_DIR/grid/<pack>/ (opt-in:
#                          no rules: entry anywhere means no rules, there is no wire-all)
#   -rules:<pack>        → un-gate a pack (overlay escape hatch; a subtraction always wins)
#   hook:<name> | -hook:<name> → enable / disable a machine-level hook (only
#                          auto-handoff exists; it is ON unless a file says -hook:...)
#   harness:<name> | -harness:<name> → also wire the skills (and composed agents) into
#                          that non-Claude harness's dirs (names: scripts/lib/harnesses.txt;
#                          `claude` is always on). Opt-in: no entry means Claude only.
# Legacy fallbacks: if NO manifest file exists at all, every repo is wired; if
# NO project: entry exists anywhere, every composed project is wired.
WIRED_REPOS=()     # whole-repo entries
WIRED_SKILLS=()    # repo/skill entries
DENY_REPOS=()      # -repo subtractions
DENY_SKILLS=()     # -repo/skill subtractions
WIRED_PROJECTS=()  # project:<name> entries
WIRED_HARNESSES=() # harness:<name> entries (-harness:<name> removes one)
WIRED_RULES=()     # rules:<pack> entries
DENY_RULES=()      # -rules:<pack> subtractions
any_project_entry=0
wire_all_repos=1
AUTO_HANDOFF=1     # hook:auto-handoff state: on by default, later manifest files win

# Parse one manifest file into the arrays above. Later files (the overlay) layer
# on top of earlier ones (the baseline): additions append, subtractions deny.
load_manifest() {
  local file="$1" line p tmp x
  [ -f "$file" ] || return 0
  wire_all_repos=0                           # a manifest exists → no legacy wire-all
  while IFS= read -r line; do
    line="${line%%#*}"                       # strip trailing comment
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    case "$line" in
      project:*)  any_project_entry=1; WIRED_PROJECTS+=("${line#project:}") ;;
      -project:*) any_project_entry=1
                  p="${line#-project:}"; tmp=()
                  for x in "${WIRED_PROJECTS[@]:-}"; do [ -n "$x" ] && [ "$x" != "$p" ] && tmp+=("$x"); done
                  WIRED_PROJECTS=("${tmp[@]:-}") ;;
      # rules: / -rules: hold a ':' before any '/', so like project: they must match
      # before the generic repo cases below or they would be read as repos.
      rules:*)    WIRED_RULES+=("${line#rules:}") ;;
      -rules:*)   DENY_RULES+=("${line#-rules:}") ;;
      # hook: / -hook: hold a ':' before any '/', so they must match before the repo
      # cases below. Only auto-handoff is a known hook; anything else is ignored loudly.
      hook:*)     case "${line#hook:}" in
                    auto-handoff) AUTO_HANDOFF=1 ;;
                    *) echo "warning: unknown hook ${line#hook:}" >&2 ;;
                  esac ;;
      -hook:*)    case "${line#-hook:}" in
                    auto-handoff) AUTO_HANDOFF=0 ;;
                    *) echo "warning: unknown hook ${line#-hook:}" >&2 ;;
                  esac ;;
      # harness: / -harness: also hold a ':' before any '/', so they too must match
      # before the repo cases. Names are validated after all layers load (below).
      # -harness: removes the name from the set; a later harness:<name> adds it back
      # (last layer wins, like project:).
      harness:*)  WIRED_HARNESSES+=("${line#harness:}") ;;
      -harness:*) p="${line#-harness:}"; tmp=()
                  for x in "${WIRED_HARNESSES[@]:-}"; do [ -n "$x" ] && [ "$x" != "$p" ] && tmp+=("$x"); done
                  WIRED_HARNESSES=("${tmp[@]:-}") ;;
      -*/*)       DENY_SKILLS+=("${line#-}") ;;
      -*)         DENY_REPOS+=("${line#-}") ;;
      */*)        WIRED_SKILLS+=("$line") ;;
      *)          WIRED_REPOS+=("$line") ;;
    esac
  done < "$file"
}

# GRID_BASELINE lets tests (and CI, which has no personal baseline) point the
# first layer at another file, e.g. baseline-submodules.example.txt. Overlays
# below still load from $GRID_DIR/machines/.
load_manifest "${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}"
load_manifest "$GRID_DIR/machines/$GRID_HOST.txt"
load_manifest "$GRID_DIR/machines/$GRID_HOST.local.txt"

# --- Active harnesses -----------------------------------------------------------
# GRID_HARNESS (comma list), when non-empty, REPLACES the manifest's harness: set for
# this run. `claude` is always active (its dirs are SKILLS_DIR / AGENTS_DIR) and is
# dropped from the list. Every name is validated against the registry BEFORE anything
# is touched (no mkdir, no teardown, no audit): an unknown name exits 2 naming the valid
# ones. Same for python3, which the portability filter needs for an active harness.
HARNESS_SRC=("${WIRED_HARNESSES[@]:-}")
if [ -n "${GRID_HARNESS:-}" ]; then
  IFS=',' read -r -a HARNESS_SRC <<< "$(printf '%s' "$GRID_HARNESS" | tr -d '[:space:]')"
fi
ACTIVE_HARNESSES=()
unknown_harnesses=""
for h_name in "${HARNESS_SRC[@]:-}"; do
  [ -n "$h_name" ] || continue
  if ! harness_valid "$h_name"; then unknown_harnesses="$unknown_harnesses $h_name"; continue; fi
  [ "$h_name" = claude ] && continue
  in_list "$h_name" "${ACTIVE_HARNESSES[@]:-}" || ACTIVE_HARNESSES+=("$h_name")
done
if [ -n "$unknown_harnesses" ]; then
  echo "wire: unknown harness:$unknown_harnesses" >&2
  echo "wire: valid harnesses: $(harness_names | tr '\n' ' ')" >&2
  exit 2
fi
if [ "${#ACTIVE_HARNESSES[@]}" -gt 0 ] && ! command -v python3 >/dev/null 2>&1; then
  echo "wire: python3 is required to wire a non-Claude harness (the skill portability filter reads frontmatter with it); nothing was changed" >&2
  exit 2
fi

# --- predicates ---------------------------------------------------------------
repo_is_denied()  { local n="$1" r; for r in "${DENY_REPOS[@]:-}";   do [ "$r" = "$n" ] && return 0; done; return 1; }
skill_is_denied() { local e="$1/$2" s; for s in "${DENY_SKILLS[@]:-}"; do [ "$s" = "$e" ] && return 0; done; return 1; }

# Is a given submodule dir name fully wired (whole-repo entry, not denied)?
repo_is_wired() {
  repo_is_denied "$1" && return 1
  [ "$wire_all_repos" -eq 1 ] && return 0
  local n="$1" r
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && return 0; done
  return 1
}

# Is a specific skill (repo, skill-name) wired by a per-skill entry (not denied)?
skill_is_wired() {
  skill_is_denied "$1" "$2" && return 1
  local entry="$1/$2" s
  for s in "${WIRED_SKILLS[@]:-}"; do [ "$s" = "$entry" ] && return 0; done
  return 1
}

# Does this repo have any per-skill entries in WIRED_SKILLS?
repo_has_skill_entries() {
  local repo="$1" s
  for s in "${WIRED_SKILLS[@]:-}"; do
    [[ "$s" == "$repo/"* ]] && return 0
  done
  return 1
}

# Is a composed agent-factory project wired? (no project: entries → all, legacy)
project_is_wired() {
  [ "$any_project_entry" -eq 0 ] && return 0
  local name="$1" p
  for p in "${WIRED_PROJECTS[@]:-}"; do [ "$p" = "$name" ] && return 0; done
  return 1
}

# Is a rule pack subtracted (-rules:<pack>) in any manifest layer?
rule_is_denied() { local r; for r in "${DENY_RULES[@]:-}"; do [ "$r" = "$1" ] && return 0; done; return 1; }

mkdir -p "$SKILLS_DIR" "$AGENTS_DIR"

# Audit trail for the manifest written at the end: one row per decision.
MANIFEST_ROWS=()

# --- 0. Vet before touching any link -------------------------------------------
# Skipped in --check's throwaway run (GRID_SKIP_CATALOG) and in audit.sh's own
# dry run (GRID_SKIP_AUDIT, prevents recursion). Skipped LOUDLY when the tool or
# policy is absent, so mock grids in tests and bare machines still wire.
# Runs BEFORE teardown: a blocked wire changes nothing, so a bad upstream bump
# can never leave a machine half-wired. audit.sh exit 2 (broken policy) blocks too.
if [ -z "${GRID_SKIP_AUDIT:-}" ] && [ -z "${GRID_SKIP_CATALOG:-}" ]; then
  if [ ! -f "$GRID_DIR/policy.yaml" ]; then
    echo "wire: no policy.yaml - audit skipped"
  elif ! command -v python3 >/dev/null 2>&1; then
    echo "wire: python3 missing - audit SKIPPED, skills wired unaudited" >&2
  elif ! bash "$(dirname "$0")/audit.sh" --wired --quiet; then
    if [ "${GRID_AUDIT:-}" = warn ]; then
      echo "wire: audit found high-severity issues; GRID_AUDIT=warn so wiring continues" >&2
    else
      echo "wire: BLOCKED by audit (nothing was changed). Fix, allowlist in CURATION.md with a reason, or set GRID_AUDIT=warn once." >&2
      exit 3
    fi
  fi
fi

# --- 1. Tear down ALL grid-owned symlinks (rebuilt below) ---
# A symlink is grid-owned if its target is under GRID_DIR. We remove every one
# and recreate only the wired set, so moving a repo to library-only actually
# drops its links — not just broken/stale ones (their targets still exist).
# Foreign symlinks (target outside GRID_DIR) are never touched. Applied to both
# the skills dir and the agents dir (composed subagents land in the latter).
teardown_grid_links() {
  local dir="$1" link target
  [ -d "$dir" ] || return 0
  while IFS= read -r link; do
    target=$(readlink "$link")
    # target_is_ours compares resolved paths against "$GRID_DIR"/ (with the slash):
    # a bare prefix would also match a sibling dir such as ${GRID_DIR}-private and
    # delete a foreign link into it.
    target_is_ours "$target" || continue   # not ours, leave it alone
    rm "$link"
  # find -H: follow $dir itself when it is a symlink to the real skills dir
  # (without it find lists nothing and stale grid links silently survive).
  done < <(find -H "$dir" -maxdepth 1 -type l 2>/dev/null)
}
teardown_grid_links "$SKILLS_DIR"
teardown_grid_links "$AGENTS_DIR"
# Every non-Claude registry dir too, active or not: a harness that was just deactivated
# (-harness:<name>, or a one-off GRID_HARNESS run) loses its grid links here. The
# function is the same one, so the same ownership test applies: only a symlink into
# "$GRID_DIR"/ goes; real files, foreign and sibling-prefix links stay. A dir that does
# not exist is skipped, so nothing is created for a harness nobody uses.
for h_raw in "${HARNESS_SKILL_DIRS[@]:-}" "${HARNESS_AGENT_DIRS[@]:-}"; do
  [ -n "$h_raw" ] || continue
  h_dir="$(harness_path "$h_raw")" || { echo "wire: cannot resolve harness dir $h_raw" >&2; exit 2; }
  teardown_grid_links "$h_dir"
done

# Rules: same ownership test, but the tree is nested ($RULES_DIR/grid/<pack>/<topic>.md)
# so it is walked recursively, and the pack dirs it leaves empty are removed afterwards.
# Only $RULES_DIR/grid is ever touched. A foreign symlink or a real file keeps its dir
# non-empty, so it survives; the grid/ root itself is left in place.
teardown_rule_links() {
  local root="$RULES_DIR/grid" link target
  [ -d "$root" ] || return 0
  while IFS= read -r link; do
    target=$(readlink "$link")
    target_is_ours "$target" || continue   # not ours, leave it alone
    rm "$link"
  done < <(find -H "$root" -type l 2>/dev/null)
  # -empty -delete only removes directories with nothing in them (-delete implies -depth,
  # so a pack dir emptied by the loop above goes, and so does a parent emptied by that).
  find "$root" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}
teardown_rule_links

# Wire a skill directory to SKILLS_DIR.
# Replaces only what the grid owns: a free name, or a link into the grid (a root skill
# overriding a repo skill wired a moment ago). A real dir, a regular file, a dangling
# link or a link to somewhere else is the user's: skipped, never replaced. The real-dir
# wording is parsed by reconcile.sh and must stay exactly as it is, for real dirs only.
wire_skill() {
  local skill_dir="$1"
  local name
  name=$(basename "$skill_dir")
  local target="$SKILLS_DIR/$name"

  if [ -d "$target" ] && [ ! -L "$target" ]; then
    echo "  skip (real dir, not managed): $name"
    MANIFEST_ROWS+=("skill	$name	$skill_dir	skipped	real dir, not managed")
    return
  fi
  if { [ -e "$target" ] || [ -L "$target" ]; } && ! link_is_ours "$target"; then
    echo "  skip (not managed): $name"
    MANIFEST_ROWS+=("skill	$name	$skill_dir	skipped	not managed")
    return
  fi

  # ln -sfn: -s symlink, -f force-replace, -n treat existing symlink-to-dir as file
  ln -sfn "$skill_dir" "$target"
  MANIFEST_ROWS+=("skill	$name	$skill_dir	wired	")
  echo "  wired: $name"
}

# Wire a single composed-agent .md file into AGENTS_DIR as a symlink.
# Skips a real file (not a symlink) — those are not managed by the-grid.
wire_agent() {
  local agent_file="$1"
  local name
  name=$(basename "$agent_file")
  local target="$AGENTS_DIR/$name"

  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "  skip (real file, not managed): $name"
    MANIFEST_ROWS+=("agent	$name	$agent_file	skipped	real file, not managed")
    return
  fi
  # A foreign or dangling symlink is the user's too; only a link into the grid is replaced.
  if [ -L "$target" ] && ! link_is_ours "$target"; then
    echo "  skip (not managed): $name"
    MANIFEST_ROWS+=("agent	$name	$agent_file	skipped	not managed")
    return
  fi

  ln -sfn "$agent_file" "$target"
  MANIFEST_ROWS+=("agent	$name	$agent_file	wired	")
  echo "  wired agent: $name"
}

# --- 2. Wire repo skills first (lower precedence) ---
# Uses find so it handles any nesting depth (flat, skills/, skills/category/, etc.)
# Skips SKILL.md files sitting directly at the repo root (e.g. gstack's root SKILL.md).
# Supports two wiring modes per repo:
#   whole-repo  — repo_is_wired() true: wire every skill found
#   per-skill   — repo_has_skill_entries() true: wire only the explicitly listed skills
if [ -d "$GRID_DIR/repos" ]; then
  for repo_dir in "$GRID_DIR/repos"/*/; do
    [ -d "$repo_dir" ] || continue
    repo_dir="${repo_dir%/}"
    repo_name="$(basename "$repo_dir")"

    if repo_is_wired "$repo_name"; then
      # Wire all skills in this repo (whole-repo entry), minus any -repo/skill
      # subtractions from the overlay.
      while IFS= read -r skill_md; do
        skill_dir=$(dirname "$skill_md")
        [ "$skill_dir" = "$repo_dir" ] && continue
        skill_is_denied "$repo_name" "$(basename "$skill_dir")" && continue
        wire_skill "$skill_dir"
      done < <(find_skill_mds "$repo_dir")
    elif repo_has_skill_entries "$repo_name"; then
      # Wire only the skills explicitly listed (per-skill entries).
      while IFS= read -r skill_md; do
        skill_dir=$(dirname "$skill_md")
        [ "$skill_dir" = "$repo_dir" ] && continue
        skill_is_wired "$repo_name" "$(basename "$skill_dir")" || continue
        wire_skill "$skill_dir"
      done < <(find_skill_mds "$repo_dir")
    fi
    # else: library-only — don't wire anything
  done
fi

# --- 2b. Runtime roots (scripts/lib/runtimes.txt) ---
# Some wired repos need more than files on disk: gstack's skills call
# ~/.claude/skills/gstack/bin/... and browse/dist/browse, which only exist after
# its ./setup has run. For each map row whose repo is active this step
#   (1) keeps the runtime-root link $SKILLS_DIR/<link> -> $GRID_DIR/repos/<repo>
#       (teardown above deletes every grid-pointing link, so it must be rebuilt
#       here on every run), and
#   (2) WARNS (never fails: exit status is unaffected) when the marker file is
#       missing, pointing at scripts/runtime-setup.sh.
# Map format (pipe-separated, '#' comments): repo | link | marker | needs | setup
# No map file (a mock grid in tests) means nothing to do.
RUNTIMES_FILE="$GRID_DIR/scripts/lib/runtimes.txt"
rt_trim() { # trim leading/trailing whitespace without forking
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
if [ -f "$RUNTIMES_FILE" ]; then
  while IFS='|' read -r rt_repo rt_link rt_marker _rt_needs _rt_setup; do
    rt_repo="$(rt_trim "${rt_repo%%#*}")"
    [ -n "$rt_repo" ] || continue                      # blank / comment line
    rt_link="$(rt_trim "$rt_link")"; rt_marker="$(rt_trim "$rt_marker")"
    # Active = whole-repo entry or any per-skill entry, and not denied.
    repo_is_denied "$rt_repo" && continue
    if ! repo_is_wired "$rt_repo" && ! repo_has_skill_entries "$rt_repo"; then continue; fi
    rt_root="$GRID_DIR/repos/$rt_repo"

    if [ -n "$rt_link" ]; then
      rt_target="$SKILLS_DIR/$rt_link"
      # Occupied = a real dir/file, or a symlink to somewhere outside the grid
      # (e.g. an earlier standalone install). Never touched: gstack's own setup
      # also refuses to repoint a link at another checkout. A symlink INTO the
      # grid (a skill that happens to share the name) is ours: the runtime
      # link wins the clash.
      if { [ -e "$rt_target" ] || [ -L "$rt_target" ]; } &&
         { [ ! -L "$rt_target" ] || ! link_is_ours "$rt_target"; }; then
        echo "  skip (runtime root occupied, not managed): $rt_link"
        MANIFEST_ROWS+=("runtime-link	$rt_link	$rt_root	skipped	runtime root occupied, not managed")
      else
        # Exact shape others rely on: absolute target, no trailing slash.
        ln -sfn "$rt_root" "$rt_target"
        MANIFEST_ROWS+=("runtime-link	$rt_link	$rt_root	wired	")
        echo "  runtime link: $rt_link"
      fi
    fi

    # Marker: must exist and be executable, or be a non-empty file.
    rt_mpath="$rt_root/$rt_marker"
    if [ -x "$rt_mpath" ] || [ -s "$rt_mpath" ]; then
      MANIFEST_ROWS+=("runtime	$rt_repo	$rt_mpath	ok	")
    else
      echo "  runtime MISSING: $rt_repo ($rt_marker) - run: bash scripts/runtime-setup.sh $rt_repo"
      MANIFEST_ROWS+=("runtime	$rt_repo	$rt_mpath	missing	")
    fi
  done < "$RUNTIMES_FILE"
fi

# --- 3. Wire skills/ dir last (higher precedence — overrides repos) ---
if [ -d "$GRID_DIR/skills" ]; then
  for skill_dir in "$GRID_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    wire_skill "$skill_dir"
  done
fi

# --- 3b. Wire agent-factory Claude Code output (composed agents) ---
# compose.py --target claude-code emits per project under
#   agent-factory/projects/<name>/_claude-code/{skills,agents}/
# Orchestrator skills wire into SKILLS_DIR (override same-named ecosystem skills,
# since they're wired last); specialist subagents wire into AGENTS_DIR.
# Gated per machine by project:<name> manifest entries (project_is_wired); with
# no project: entries anywhere, every composed project wires (legacy fallback).
CC_OUT="$GRID_DIR/agent-factory/projects"
if [ -d "$CC_OUT" ]; then
  for proj_dir in "$CC_OUT"/*/; do
    [ -d "$proj_dir" ] || continue
    proj_name="$(basename "${proj_dir%/}")"
    project_is_wired "$proj_name" || continue
    while IFS= read -r skill_md; do
      wire_skill "$(dirname "$skill_md")"
    done < <(find "$proj_dir/_claude-code/skills" -name "SKILL.md" 2>/dev/null)
    while IFS= read -r agent_md; do
      wire_agent "$agent_md"
    done < <(find "$proj_dir/_claude-code/agents" -name "*.md" 2>/dev/null)
  done
fi

# --- 3c. Wire root-owned agents/ dir (highest precedence — root wins) ---
# Hand-authored subagents that aren't composed via agent-factory (no
# delegates_to, not a team role — e.g. a ported persona/behavior-modifier
# skill like ponytail) live here so they're tracked and reproducible across
# machines, same ownership model as root-level skills/. Wired last so a
# root-owned agent overrides a same-named composed one.
if [ -d "$GRID_DIR/agents" ]; then
  for agent_file in "$GRID_DIR/agents"/*.md; do
    [ -f "$agent_file" ] || continue
    wire_agent "$agent_file"
  done
fi

# --- 3c1. Rule packs (rules:<pack>) ---
# Each wired pack's rules/<pack>/*.md (never README.md; pack.yaml is not .md) is
# symlinked into $RULES_DIR/grid/<pack>/ as a per-file link inside a REAL directory
# (not a directory link), so README.md can never load as an always-on rule. Opt-in: with
# no rules: entry the loop body never runs and RULES_DIR is not even created. A pack that
# does not exist, or whose name could escape rules/ (anything but lowercase kebab-case),
# warns on stderr and is recorded as skipped; it never fails the wire. A real file at a
# target is left alone, as with skills and agents.
rules_done=" "   # packs already handled this run (a pack named in baseline AND overlay)
RULES_EFFECTIVE=()   # the wired packs that exist (input to step 3f, rules delivery)
for rule_pack in "${WIRED_RULES[@]:-}"; do
  [ -n "$rule_pack" ] || { echo "warning: empty rules: entry ignored" >&2; continue; }
  rule_is_denied "$rule_pack" && continue
  case "$rules_done" in *" $rule_pack "*) continue ;; esac
  rules_done="$rules_done$rule_pack "
  case "$rule_pack" in
    *[!a-z0-9-]*|-*|*-|*--*) rule_src=""  ;;                  # not lowercase kebab-case
    *)                       rule_src="$GRID_DIR/rules/$rule_pack" ;;
  esac
  if [ -z "$rule_src" ] || [ ! -d "$rule_src" ]; then
    echo "warning: rules:$rule_pack - no such pack in rules/; skipped" >&2
    MANIFEST_ROWS+=("rule	$rule_pack	$GRID_DIR/rules/$rule_pack	skipped	no such pack")
    continue
  fi
  # An existing, valid, not-denied pack: this is the set rules delivery (3f) hands to rules.py.
  RULES_EFFECTIVE+=("$rule_pack")
  rule_dest="$RULES_DIR/grid/$rule_pack"
  if ! mkdir -p "$rule_dest" 2>/dev/null; then
    echo "warning: rules:$rule_pack - cannot create $rule_dest; skipped" >&2
    MANIFEST_ROWS+=("rule	$rule_pack	$rule_src	skipped	cannot create target dir")
    continue
  fi
  for rule_file in "$rule_src"/*.md; do
    [ -f "$rule_file" ] || continue
    rule_name="$(basename "$rule_file")"
    [ "$rule_name" = "README.md" ] && continue
    rule_target="$rule_dest/$rule_name"
    if [ -e "$rule_target" ] && [ ! -L "$rule_target" ]; then
      echo "  skip (real file, not managed): rules/$rule_pack/$rule_name"
      MANIFEST_ROWS+=("rule	$rule_pack/$rule_name	$rule_file	skipped	real file, not managed")
      continue
    fi
    ln -sfn "$rule_file" "$rule_target"
    MANIFEST_ROWS+=("rule	$rule_pack/$rule_name	$rule_file	wired	")
    echo "  wired rule: $rule_pack/$rule_name"
  done
done

# --- 3c2. Machine-level hooks (auto-handoff) ---
# Makes ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json hold exactly the generated
# hook entries the manifest asks for (hook: / -hook:), leaving every hand-written
# hook and key alone. deploy_hooks.py --user is idempotent (a second run writes
# nothing) and stdlib-only, so plain python3 is enough. A failure is a warning, never
# a failed wire: skills and agents are already linked above.
# Skipped silently (no manifest row) under GRID_SKIP_CATALOG, i.e. every dry run, so a
# dry run can never reach a real settings file, and for a mock or older grid without
# the emitter. A dry run only records what it resolved, for `--check` to read.
HOOKS_WANTED=""
[ "$AUTO_HANDOFF" = 1 ] && HOOKS_WANTED="auto-handoff"
HOOKS_EMITTER="$GRID_DIR/agent-factory/deploy_hooks.py"
if [ -f "$HOOKS_EMITTER" ]; then
  if [ -n "${GRID_DRY_HOME:-}" ]; then
    printf '%s\n' "$HOOKS_WANTED" > "$GRID_DRY_HOME/.hooks-wanted"
  elif [ -z "${GRID_SKIP_CATALOG:-}" ]; then
    HOOKS_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    HOOKS_STATUS=wired; [ -n "$HOOKS_WANTED" ] || HOOKS_STATUS=off
    HOOKS_REASON=""
    if ! command -v python3 >/dev/null 2>&1; then
      echo "warning: python3 not found; auto-handoff not wired" >&2
      HOOKS_STATUS=skipped; HOOKS_REASON="python3 not found"
    elif ! env GRID_DIR="$GRID_DIR" python3 "$HOOKS_EMITTER" --user --hooks "$HOOKS_WANTED"; then
      echo "warning: deploy_hooks.py --user failed; auto-handoff not updated (see above)" >&2
      HOOKS_STATUS=failed; HOOKS_REASON="deploy_hooks.py --user failed"
    fi
    MANIFEST_ROWS+=("hook	auto-handoff	$HOOKS_SETTINGS	$HOOKS_STATUS	$HOOKS_REASON")
  fi
fi

# --- 3e. Non-Claude harnesses (harness:<name> / GRID_HARNESS) ---
# Fans the wired set out to every ACTIVE harness, once per distinct dir (codex, opencode,
# gemini, pi and openclaw all share ~/.agents/skills, so it is written once).
#   skills  the set is whatever grid-owned links SKILLS_DIR holds now, in sorted order, so
#           Claude's precedence (root wins) and dedupe apply unchanged. Each is checked
#           by skill_portable (Agent Skills limits, no hard-coded ~/.claude); a failure
#           is a manifest row with its reason, not an error. A submodule-root link (the
#           gstack runtime root) is not a skill at all: reason runtime-root, no stdout line.
#   agents  agent-factory/projects/<p>/_<compose_target>/agents/* for wired projects. A
#           compose target that was never run has no dir and simply links nothing.
# wire_harness_link never replaces anything: ~/.agents/skills is also written by other
# tools, so ANY entry already at the destination after teardown (real dir or file,
# foreign or dangling symlink) is theirs and is skipped. Its stdout line deliberately
# does NOT start `  skip (real dir, not managed)`: reconcile.sh parses that exact
# prefix and would rm -rf the same-named dir in the Claude skills dir.
# Manifest rows use kind skill@<~dir> / agent@<~dir> (home-independent), reason last.
wire_harness_link() { # $1=src $2=dest dir $3=kind (skill|agent) $4=~/-form dir $5=name
  local src="$1" dest_dir="$2" kind="$3" disp="$4" name="$5"
  if [ -e "$dest_dir/$name" ] || [ -L "$dest_dir/$name" ]; then
    echo "  skip ($disp: exists, not managed): $name"
    MANIFEST_ROWS+=("$kind@$disp	$name	$src	skipped	exists, not managed")
    return
  fi
  # Created only now, when a link is about to be made: a harness with nothing to link
  # (or a dir that cannot be created) leaves no empty dirs behind.
  if ! mkdir -p "$dest_dir" 2>/dev/null; then
    echo "  skip ($disp: cannot create dir): $name"
    MANIFEST_ROWS+=("$kind@$disp	$name	$src	skipped	cannot create dir")
    return
  fi
  ln -s "$src" "$dest_dir/$name"
  MANIFEST_ROWS+=("$kind@$disp	$name	$src	wired	")
  echo "  wired ($disp): $name"
}

if [ "${#ACTIVE_HARNESSES[@]}" -gt 0 ]; then
  # Portability is decided once per skill, then applied to each distinct dir.
  HL_NAME=(); HL_SRC=(); HL_REASON=()
  while IFS= read -r hl_link; do
    hl_t="$(readlink "$hl_link")"
    target_is_ours "$hl_t" || continue                  # foreign link: not ours to fan out
    hl_reason=""
    hl_rel="${hl_t%/}"
    case "$hl_rel" in
      # "$GRID_DIR"/repos/<r> with no further component = a submodule root, not a skill.
      "$GRID_DIR"/repos/*) case "${hl_rel#"$GRID_DIR"/repos/}" in
                             */*) ;;
                             *) hl_reason="runtime-root" ;;
                           esac ;;
    esac
    if [ -z "$hl_reason" ]; then hl_reason="$(skill_portable "$hl_t")" || true; fi
    HL_NAME+=("$(basename "$hl_link")"); HL_SRC+=("$hl_t"); HL_REASON+=("$hl_reason")
  done < <(find -H "$SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null | LC_ALL=C sort)

  hl_done=()   # distinct dirs already written this run
  for h_name in "${ACTIVE_HARNESSES[@]}"; do
    h_raw="$(harness_field "$h_name" skills_dir)"
    [ "$h_raw" != "-" ] || continue
    ! in_list "$h_raw" "${hl_done[@]:-}" || continue
    hl_done+=("$h_raw")
    h_dir="$(harness_path "$h_raw")" || { echo "wire: cannot resolve harness dir $h_raw" >&2; exit 2; }
    i=0
    while [ "$i" -lt "${#HL_NAME[@]}" ]; do
      if [ -n "${HL_REASON[$i]}" ]; then
        MANIFEST_ROWS+=("skill@$h_raw	${HL_NAME[$i]}	${HL_SRC[$i]}	skipped	${HL_REASON[$i]}")
      else
        wire_harness_link "${HL_SRC[$i]}" "$h_dir" skill "$h_raw" "${HL_NAME[$i]}"
      fi
      i=$((i + 1))
    done
  done

  hl_done=()
  for h_name in "${ACTIVE_HARNESSES[@]}"; do
    h_raw="$(harness_field "$h_name" agents_dir)"
    h_target="$(harness_field "$h_name" compose_target)"
    { [ "$h_raw" != "-" ] && [ "$h_target" != "-" ]; } || continue
    ! in_list "$h_raw" "${hl_done[@]:-}" || continue
    hl_done+=("$h_raw")
    h_dir="$(harness_path "$h_raw")" || { echo "wire: cannot resolve harness dir $h_raw" >&2; exit 2; }
    for proj_dir in "$CC_OUT"/*/; do
      [ -d "$proj_dir" ] || continue
      proj_dir="${proj_dir%/}"
      project_is_wired "$(basename "$proj_dir")" || continue
      for agent_file in "$proj_dir/_$h_target/agents"/*; do
        [ -f "$agent_file" ] || continue
        wire_harness_link "$agent_file" "$h_dir" agent "$h_raw" "$(basename "$agent_file")"
      done
    done
  done
fi

# --- 3f. Rules delivery into harness instruction files (rules.py emit) ---
# rule-packs owns the format and the emitter; this step only decides WHICH files get a call.
# The wired set is RULES_EFFECTIVE (rules:<pack> minus -rules:<pack>, existing packs only),
# comma-joined in C-locale order. Per harness that has a rules_file in the registry:
#   active, packs wired, regular file     -> emit --harness <rules_harness> --packs <csv>
#   active, packs wired, absent/symlink   -> NO call; manifest row rules@<~file> ... skipped
#                                            (the grid never creates an instruction file, and
#                                            never writes through a symlink)
#   anything else holding the literal marker `BEGIN the-grid rules` in a regular file
#                                         -> emit --packs '' (removes the block; no marker, no call)
# So nothing is injected by default, and an operator's empty opt-in file is never touched.
# A rules.py failure is reported, the remaining steps still run, and wire exits 1 at the end.
# Under GRID_DRY_HOME (the --check sub-run) nothing is delivered: the decision inputs are
# recorded in $GRID_DRY_HOME/.rules-wanted for the parent's --check to replay with --check.
rules_failed=0
rules_csv=""
if [ "${#RULES_EFFECTIVE[@]}" -gt 0 ]; then
  rules_csv="$(printf '%s\n' "${RULES_EFFECTIVE[@]}" | LC_ALL=C sort -u | paste -sd, -)"
fi
[ -z "${GRID_DRY_HOME:-}" ] || : > "$GRID_DRY_HOME/.rules-wanted"
rl_done=()   # distinct instruction files handled this run (two harnesses must never share one)
while IFS= read -r h_name; do
  [ "$h_name" = claude ] && continue
  rl_raw="$(harness_field "$h_name" rules_file)"
  [ "$rl_raw" != "-" ] || continue
  ! in_list "$rl_raw" "${rl_done[@]:-}" || continue
  rl_done+=("$rl_raw")
  rl_active=0; if in_list "$h_name" "${ACTIVE_HARNESSES[@]:-}"; then rl_active=1; fi
  if [ -n "${GRID_DRY_HOME:-}" ]; then
    printf '%s\t%s\t%s\n' "$h_name" "$rl_active" "$rules_csv" >> "$GRID_DRY_HOME/.rules-wanted"
    continue
  fi
  if ! rl_file="$(harness_path "$rl_raw")"; then
    echo "wire: rules delivery failed for $rl_raw: cannot resolve the path" >&2; rules_failed=1; continue
  fi
  rl_action="$(harness_rules_action "$rl_file" "$rl_active" "$rules_csv" "$rl_raw")"
  case "$rl_action" in
    skip:*)
      echo "warning: rules ($rl_raw): skipped, $(harness_skip_text "${rl_action#skip:}")" >&2
      MANIFEST_ROWS+=("rules@$rl_raw	$h_name	-	skipped	${rl_action#skip:}") ;;
    emit|remove)
      rl_packs="$rules_csv"; [ "$rl_action" = remove ] && rl_packs=""
      # Codex reads AGENTS.override.md before AGENTS.md, so a block in AGENTS.md is inert.
      if [ "$h_name" = codex ] && [ -e "$(dirname "$rl_file")/AGENTS.override.md" ]; then
        echo "warning: rules ($rl_raw): AGENTS.override.md exists beside it; Codex reads that first, so the block has no effect" >&2
      fi
      rl_rc=0
      if ! command -v python3 >/dev/null 2>&1; then
        echo "warning: python3 not found; rules in $rl_raw not updated" >&2
        MANIFEST_ROWS+=("rules@$rl_raw	$h_name	-	skipped	python3 not found")
        continue
      fi
      rl_out="$(harness_rules_emit "$(harness_field "$h_name" rules_harness)" "$rl_packs" "$rl_file" 2>&1)" || rl_rc=$?
      if [ "$rl_rc" = 0 ]; then
        [ -z "$rl_out" ] || echo "  rules ($rl_raw): $rl_out"
      elif [ "$rl_rc" = 3 ]; then
        # Exit 3 = block over the cap: a visible skip, not a failure (the file is untouched).
        echo "warning: rules ($rl_raw): skipped, ${rl_out#rules.py emit: }" >&2
        MANIFEST_ROWS+=("rules@$rl_raw	$h_name	-	skipped	over-cap")
      elif [ "$rl_action" = remove ] && [[ "$rl_out" == *"expected exactly one BEGIN"* ]]; then
        # Removal only runs for an inactive harness (or no packs): its damaged file is
        # reported, not a failure, so a stray marker never turns every wire red.
        echo "warning: rules ($rl_raw): markers unbalanced, block not removed: $rl_out" >&2
        MANIFEST_ROWS+=("rules@$rl_raw	$h_name	-	skipped	markers-unbalanced")
      else
        echo "wire: rules delivery failed for $rl_raw ($h_name): $rl_out" >&2
        MANIFEST_ROWS+=("rules@$rl_raw	$h_name	-	failed	emit refused or failed")
        rules_failed=1
      fi ;;
  esac
done < <(harness_names)

# --- 3d. Write the wiring manifest (audit trail) ---
# One row per decision (kind, name, target, status, reason), sorted, no
# timestamp — so an unchanged wiring leaves the file byte-identical and it is
# only rewritten when it actually differs. Gitignored: it is per-machine state.
# Skipped under --check's throwaway run (GRID_SKIP_CATALOG) so a check never writes.
if [ -z "${GRID_SKIP_CATALOG:-}" ]; then
  MANIFEST="$GRID_DIR/.wired.manifest"
  new_manifest=""
  if [ "${#MANIFEST_ROWS[@]}" -gt 0 ]; then
    new_manifest="$(printf '%s\n' "${MANIFEST_ROWS[@]}" | LC_ALL=C sort)"
  fi
  if [ ! -f "$MANIFEST" ] || [ "$(cat "$MANIFEST")" != "$new_manifest" ]; then
    printf '%s\n' "$new_manifest" > "$MANIFEST"
  fi
fi

# --- 4. Refresh the skill catalogue so wiring and SKILLS.md never drift ---
# Coupled on purpose: any change to what's wired re-renders the catalogue.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/catalog.sh" ] && [ -z "${GRID_SKIP_CATALOG:-}" ] && [ -z "${GRID_NO_CATALOG:-}" ]; then
  # The tracked SKILLS.md is the PUBLIC default catalogue: render it from the tracked example
  # baseline, never from this machine's personal one, so a wire never dirties it and CI's
  # check agrees with every machine. (Tradeoff: SKILLS.md no longer shows this machine's own
  # wired set; `wire.sh` output and the symlinks do.) No example file (a mock grid) = legacy.
  catalog_baseline=""
  [ ! -f "$GRID_DIR/baseline-submodules.example.txt" ] || catalog_baseline="$GRID_DIR/baseline-submodules.example.txt"
  # env prefix is intentional; value is identical in the parent shell
  # shellcheck disable=SC2097,SC2098
  GRID_DIR="$GRID_DIR" GRID_BASELINE="$catalog_baseline" bash "$SCRIPT_DIR/catalog.sh" "$GRID_DIR/SKILLS.md"
fi

# Rules delivery (3f) finishes every other step first, then fails the run.
if [ "$rules_failed" != 0 ]; then
  echo "wire: done, but rules delivery failed (see above)" >&2
  exit 1
fi
echo "Done."
