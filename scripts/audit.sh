#!/usr/bin/env bash
# audit.sh — choose WHAT scripts/audit.py scans. It decides the target list and
# nothing else; every finding, severity and exit code comes from audit.py.
#
# Usage:
#   bash scripts/audit.sh --owned [OPTS] [TARGET...]   the-grid's own assets
#   bash scripts/audit.sh --wired [OPTS] [TARGET...]   what wire.sh would link on this machine
#   bash scripts/audit.sh --gate  [OPTS] [TARGET...]   owned + the BASELINE's wired set (CI / gate.sh)
#   --allow-partial   with --gate: when a baseline submodule is uninitialised, scan the owned
#                     assets only and exit by that result (the unscanned wired set is announced
#                     before AND after the summary). Without it that case is exit 2.
#   bash scripts/audit.sh [OPTS] TARGET...             only the given directories/files
#
# Modes may be combined (--owned --wired). Non-option arguments are extra
# targets appended to the list. Every other option is passed through to
# audit.py (--quiet, --format json, --root DIR, ...).
#
# Everything goes into ONE audit.py run so the summary and the exit code cover
# the whole selection.
#
# Env:
#   GRID_DIR      repo root (default: parent of scripts/); also read by audit.py
#   GRID_BASELINE baseline manifest (default: $GRID_DIR/baseline-submodules.txt)
#   GRID_HOST     machine key for the wire.sh overlay (--wired only; --gate ignores it)
#
# Exit: audit.py's (0 clean | 1 a high finding | 2 usage/policy error); 2 also
# when python3 or the dry-run wire fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRID_DIR="${GRID_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export GRID_DIR   # wire.sh and audit.py both honour it: one root for everything

# audit.py imports scripts/lib/miniyaml.py; keep that from leaving a
# __pycache__ in the tree (it is not gitignored).
export PYTHONDONTWRITEBYTECODE=1

command -v python3 >/dev/null 2>&1 || { echo "audit: python3 is required but not on PATH" >&2; exit 2; }

want_owned=0; want_wired=0; want_gate=0; allow_partial=0
passthru=()   # options handed to audit.py untouched
extra=()      # explicit targets

# --- argument parsing -------------------------------------------------------
# audit.py options that take a value: the value must not be mistaken for a
# target ("--format json" would otherwise add a target called "json").
while [ $# -gt 0 ]; do
  case "$1" in
    --owned) want_owned=1 ;;
    --wired) want_wired=1 ;;
    --gate)  want_gate=1 ;;
    --allow-partial) allow_partial=1 ;;
    --root|--grid-dir|--policy|--allow|--format|--baseline|--check-url)
      [ $# -ge 2 ] || { echo "audit: $1 needs a value" >&2; exit 2; }
      passthru+=("$1" "$2"); shift ;;
    --) shift; while [ $# -gt 0 ]; do extra+=("$1"); shift; done; break ;;
    -*) passthru+=("$1") ;;
    *)  extra+=("$1") ;;
  esac
  shift
done

targets=()   # the combined list, handed to audit.py in one call
baseline=""  # file passed as --baseline (the one the dry run used)

# --- owned ------------------------------------------------------------------
# Whichever of these exist; a missing one is simply not scanned.
add_owned() {
  local p
  for p in "$GRID_DIR"/skills/*/ "$GRID_DIR"/agents/*.md "$GRID_DIR/rules" "$GRID_DIR/hooks" \
           "$GRID_DIR"/agent-factory/roles/*/ "$GRID_DIR/agent-factory/_core" \
           "$GRID_DIR/plugins" "$GRID_DIR/dist"; do
    # An unmatched glob stays literal, so the -e test also drops it.
    [ -e "$p" ] && targets+=("${p%/}")
  done
  return 0
}

# --- wired ------------------------------------------------------------------
# Ask wire.sh what it WOULD link (dry home: nothing real is touched, no
# second implementation of the manifest/overlay/precedence logic), then read the
# links back. $1 = baseline file for the dry run ("" = wire.sh's own default),
# $2 = GRID_HOST for the dry run ("" = inherit).
add_wired() {
  local base="$1" host="$2" tmp t d rc=0
  tmp="$(mktemp -d)"
  # Expanded now on purpose: the trap must remember this call's tmp dir.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  # ONLY GRID_DRY_HOME redirects the targets: never pass SKILLS_DIR/AGENTS_DIR.
  # GRID_SKIP_AUDIT stops wire.sh auditing itself (recursion).
  local env_args=(GRID_DRY_HOME="$tmp/home" GRID_SKIP_AUDIT=1)
  [ -z "$base" ] || env_args+=(GRID_BASELINE="$base")
  [ -z "$host" ] || env_args+=(GRID_HOST="$host")
  env "${env_args[@]}" bash "$SCRIPT_DIR/wire.sh" >"$tmp/wire.out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "audit: dry-run wire.sh failed (exit $rc):" >&2
    cat "$tmp/wire.out" >&2
    exit 2
  fi
  for d in "$tmp/home/.claude/skills" "$tmp/home/.claude/agents"; do
    [ -d "$d" ] || continue
    while IFS= read -r t; do
      t="${t%/}"
      # The runtime-root link (e.g. gstack -> repos/gstack) is a whole repo,
      # not a skill: scanning it would pull library content into the audit.
      [ "$(dirname "$t")" = "$GRID_DIR/repos" ] && continue
      targets+=("$t")
    done < <(find "$d" -maxdepth 1 -type l -exec readlink {} \; | LC_ALL=C sort)
  done
  return 0
}

# --- choose -----------------------------------------------------------------
# Baseline file the wire uses by default: $GRID_BASELINE, else the personal one.
default_base="${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}"
if [ "$want_gate" = 1 ]; then
  want_owned=1
  # The gate is baseline-only (no machine overlay) and falls back to the tracked
  # example when there is no personal baseline, so CI audits the example.
  baseline="$default_base"
  [ -f "$baseline" ] || baseline="$GRID_DIR/baseline-submodules.example.txt"
elif [ "$want_owned" = 1 ] || [ "$want_wired" = 1 ]; then
  # --owned / --wired pass the baseline only when one exists (the very file
  # wire.sh reads); with none, source checks stay at their low default.
  [ ! -f "$default_base" ] || baseline="$default_base"
fi

[ "$want_owned" = 0 ] || add_owned

# Names of the repos a wiring manifest wires, one per line: same normalisation as
# wire.sh (strip `#...` and all whitespace), then skip blanks, subtractions (`-x`)
# and typed `kind:name` entries; the repo is the text before the first `/`.
baseline_repo_names() {
  local line head
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    case "$line" in -*) continue ;; esac
    head="${line%%/*}"
    case "$head" in *:*) continue ;; esac
    printf '%s\n' "$head"
  done < "$1" | LC_ALL=C sort -u
}

partial=0
if [ "$want_gate" = 1 ]; then
  # An uninitialised BASELINE submodule (leading '-') means the wired set is incomplete:
  # never audit half of it and call it ok. Only baseline repos matter; a library-only
  # submodule is not part of the wired set. git absent or not a repo (a mock grid, a
  # tarball) is not "uninitialised": it just has no submodules.
  # Capture first: piping into `grep -q` SIGPIPEs git on long output, which
  # pipefail turns into a false "no uninitialised submodules".
  uninit=()
  if [ -f "$baseline" ]; then
    while IFS= read -r name; do
      sub_status="$( (cd "$GRID_DIR" && git submodule status -- "repos/$name" 2>/dev/null) || true)"
      if printf '%s\n' "$sub_status" | command grep -q '^-'; then
        uninit+=("$name")
      fi
    done < <(baseline_repo_names "$baseline")
  fi
  if [ ${#uninit[@]} -gt 0 ]; then
    echo "audit: wired set NOT scanned (uninitialised baseline submodules: ${uninit[*]})"
    if [ "$allow_partial" != 1 ]; then
      echo "audit: initialise them (git submodule update --init) or pass --allow-partial" >&2
      exit 2
    fi
    partial=1
  else
    add_wired "$baseline" "__baseline__"
  fi
elif [ "$want_wired" = 1 ]; then
  add_wired "${GRID_BASELINE:-}" ""
fi

# Explicit targets last; with no mode they are the whole list.
[ ${#extra[@]} -eq 0 ] || targets+=("${extra[@]}")

# --- run --------------------------------------------------------------------
# De-duplicate (first occurrence wins): an owned skill is also in the wired set
# (root skills win), and scanning it twice would double every finding.
uniq_targets=()
for t in ${targets[@]+"${targets[@]}"}; do
  dup=0
  for u in ${uniq_targets[@]+"${uniq_targets[@]}"}; do
    [ "$u" = "$t" ] && { dup=1; break; }
  done
  [ "$dup" = 1 ] || uniq_targets+=("$t")
done

# --wired alone with an EMPTY wired set (nothing to link, e.g. `grid install` into a
# grid where every source was skipped) is a clean pass, not a usage error: wire.sh
# runs this before every wire and must not block a wire that has nothing to vet.
# --owned / --gate with nothing to scan stay a usage error (audit.py exits 2).
if [ "$want_wired" = 1 ] && [ "$want_owned" = 0 ] && [ ${#uniq_targets[@]} -eq 0 ]; then
  echo "audit: nothing wired - nothing to scan"
  exit 0
fi

args=()
[ -z "$baseline" ] || args+=(--baseline "$baseline")
# User options after ours so a user's own --baseline/--root wins.
[ ${#passthru[@]} -eq 0 ] || args+=("${passthru[@]}")

# No `exec`: the EXIT trap must still remove the dry-run tmp dir.
rc=0
python3 "$SCRIPT_DIR/audit.py" ${args[@]+"${args[@]}"} ${uniq_targets[@]+"${uniq_targets[@]}"} || rc=$?
# The summary line says "ok": repeat the partial-scan notice after it so it is the last word.
[ "$partial" = 0 ] || echo "audit: wired set NOT scanned"
exit "$rc"
