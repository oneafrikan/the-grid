#!/usr/bin/env bash
#
# sources.sh — generate (and link-check) docs/SOURCES.md: the canonical upstream
# URL for every submodule the-grid tracks.
#
# One line per submodule, nothing else. This is deliberately NOT a research
# bibliography — docs/reference-repos.md and docs/reference-resources.md are
# frozen May-2026 research snapshots and are not maintained. SOURCES.md is the
# opposite: fully generated from .gitmodules, so it can never drift from what
# the repo actually tracks.
#
# Usage:
#   bash scripts/sources.sh              # write docs/SOURCES.md
#   bash scripts/sources.sh /tmp/x.md    # write somewhere else (tests)
#   bash scripts/sources.sh --check      # LINT: HEAD every URL, report failures
#   bash scripts/sources.sh --check-drift  # is docs/SOURCES.md current? offline, read-only;
#                                        # exit 0 current, 1 stale, 2 error. Defaults to the
#                                        # tracked example baseline; GRID_BASELINE pins another.
#   bash scripts/sources.sh -h | --help  # this usage; writes nothing
#
# A leading dash is always an option: an unknown one is a usage error (exit 2) before any file
# is touched, so a mistyped flag never becomes the name of an output file.
# With no submodules in .gitmodules every mode fails ("no submodules"): this repo always
# tracks some, so an empty list means a broken checkout, never a vacuous pass. The exit is 1,
# except --check-drift, where 1 already means "stale" and so this error is 2.
#
# --check is the rot detector. Upstream repos get renamed, deleted, or made
# private, and a submodule URL keeps pointing at nothing without any local
# symptom until someone runs `git submodule update --init` on a fresh machine.
# Exit code is non-zero if any URL fails, so it can gate CI.
#
# Output is deterministic (sorted, no timestamp) so re-running produces an
# identical file unless .gitmodules or the baseline changed — same contract as
# catalog.sh. All sorts pin LC_ALL=C so macOS and Linux agree on byte order.

set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# usage: print the Usage block of this file's header (the single source of the text).
usage() { sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CHECK_MODE=0
DRIFT_MODE=0
COMMITTED="$GRID_DIR/docs/SOURCES.md"
OUT="$COMMITTED"
OUT_GIVEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)       CHECK_MODE=1 ;;
    --check-drift) DRIFT_MODE=1 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "sources.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)             [ "$OUT_GIVEN" -eq 0 ] || { echo "sources.sh: more than one output path" >&2; usage >&2; exit 2; }
                   OUT="$1"; OUT_GIVEN=1 ;;
  esac
  shift
done
# The two checks write nothing and exclude each other, so a path or a second mode is a mistake.
if [ $((CHECK_MODE + DRIFT_MODE)) -gt 1 ] || { [ $((CHECK_MODE + DRIFT_MODE)) -eq 1 ] && [ "$OUT_GIVEN" -eq 1 ]; }; then
  echo "sources.sh: --check and --check-drift take no output path and exclude each other" >&2
  usage >&2; exit 2
fi

# Baseline: GRID_BASELINE pins it (same override wire.sh, catalog.sh and budget.py take). The
# committed SOURCES.md is rendered from the TRACKED example baseline, so --check-drift defaults
# to that file (the only baseline CI has); plain generation keeps defaulting to the personal one.
# A pin naming a missing file is an error (exit 2), never a silent "everything wired" render.
if [ -n "${GRID_BASELINE:-}" ]; then
  BASELINE="$GRID_BASELINE"
elif [ "$DRIFT_MODE" -eq 1 ]; then
  BASELINE="$GRID_DIR/baseline-submodules.example.txt"
else
  BASELINE="$GRID_DIR/baseline-submodules.txt"
fi
if [ -n "${GRID_BASELINE:-}" ] || [ "$DRIFT_MODE" -eq 1 ]; then
  [ -f "$BASELINE" ] || { echo "sources.sh: baseline not found: $BASELINE" >&2; exit 2; }
fi

if [ "$DRIFT_MODE" -eq 1 ]; then
  # Read-only: render into a temp file, compare at the end, never touch docs/SOURCES.md.
  [ -f "$COMMITTED" ] || { echo "sources.sh: no $COMMITTED to compare against" >&2; exit 2; }
  OUT="$(mktemp)"
  trap 'rm -f "$OUT"' EXIT
fi

GITMODULES="$GRID_DIR/.gitmodules"
[ -f "$GITMODULES" ] || { echo "sources.sh: no .gitmodules at $GITMODULES" >&2; exit "$((1 + DRIFT_MODE))"; }

# --- Baseline manifest → wired / partial / library tier ----------------------
# Same baseline wire.sh and catalog.sh read. Per-machine overlays are ignored on
# purpose: SOURCES.md must be machine-agnostic, like SKILLS.md.
#
# Entry grammar handled here mirrors wire.sh: `repo`, `repo/skill`, and the
# `-repo` / `-repo/skill` subtractions. `project:` entries gate composed
# agent-factory output, not submodules, so they're skipped entirely.
WIRED_REPOS=()
WIRED_SKILLS=()
DENY_REPOS=()
wire_all_repos=1

if [ -f "$BASELINE" ]; then
  wire_all_repos=0
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    case "$line" in
      project:*|-project:*) continue ;;          # composed projects, not submodules
      *:*)                  continue ;;          # typed entries (rules:, -rules:, harness:, hook:, ...) are not repos
      -*/*)                 continue ;;          # per-skill subtraction — tier is still "wired"
      -*)                   DENY_REPOS+=("${line#-}") ;;
      */*)                  WIRED_SKILLS+=("$line") ;;
      *)                    WIRED_REPOS+=("$line") ;;
    esac
  done < "$BASELINE"
fi

repo_tier() {
  local n="$1" r s
  for r in "${DENY_REPOS[@]:-}"; do [ "$r" = "$n" ] && { echo "library"; return; }; done
  [ "$wire_all_repos" -eq 1 ] && { echo "wired"; return; }
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && { echo "wired"; return; }; done
  for s in "${WIRED_SKILLS[@]:-}"; do [[ "$s" == "$n/"* ]] && { echo "partial"; return; }; done
  echo "library"
}

# --- Normalise a clone URL to a browsable https URL --------------------------
# .gitmodules mixes two forms — `https://github.com/o/r.git` and the SSH form
# `git@github.com:o/r.git`. The SSH form is neither clickable in markdown nor
# fetchable by curl, so render/check an https equivalent. .gitmodules itself is
# left alone: the clone URL is a real setting, this is only for display.
#
# NOTE the SSH form is also a portability trap on machines where the default
# github.com identity is not the account that can read the repo — see the
# "SSH-form remotes" note emitted into the document below.
to_browse_url() {
  local u="$1"
  # A bare slash can't be written inline as a ${var/pat/rep} replacement (bash
  # reads it as part of the pattern syntax), so hold it in a variable.
  local slash='/'
  case "$u" in
    # git@host:o/r → host:o/r → host/o/r → https://host/o/r
    # The colon must become a slash BEFORE the scheme is prefixed, or the
    # replacement hits the ':' in "https://" instead of the host separator.
    git@*:*)     u="${u#git@}"; u="https://${u/:/$slash}" ;;
    ssh://git@*) u="https://${u#ssh://git@}" ;;
  esac
  u="${u%.git}"
  printf '%s' "$u"
}

# --- Read .gitmodules → "path<TAB>clone_url<TAB>browse_url" -------------------
# git config -f is used rather than parsing the INI by hand so submodule names
# containing dots or spaces don't break us.
read_submodules() {
  local key path url name
  git config -f "$GITMODULES" --get-regexp '^submodule\..*\.path$' \
  | while IFS=' ' read -r key path; do
      name="${key#submodule.}"; name="${name%.path}"
      url="$(git config -f "$GITMODULES" --get "submodule.$name.url" || true)"
      [ -n "$url" ] || continue
      printf '%s\t%s\t%s\n' "$path" "$url" "$(to_browse_url "$url")"
    done
}

# No submodule entries: `read_submodules` fails under pipefail when git finds none, so check up
# front and say so, in every mode (an empty list would otherwise write a table-less file with a
# silent exit 1, or make --check pass with "0 checked").
if [ -z "$(read_submodules || true)" ]; then
  echo "sources.sh: no submodules in .gitmodules" >&2
  exit "$((1 + DRIFT_MODE))"
fi

# --- --check: HEAD every URL -------------------------------------------------
if [ "$CHECK_MODE" -eq 1 ]; then
  echo "Link-checking every submodule URL in .gitmodules …"
  echo ""
  failures=0
  total=0
  while IFS=$'\t' read -r path clone_url url; do
    [ -n "$path" ] || continue
    total=$((total + 1))
    # A URL that starts with "-" would be read by curl as an option. .gitmodules is trusted,
    # but a bad value must be a FAIL line, not an argument: curl is never called with it.
    case "$url" in
      -*) printf '  FAIL %s %-40s %s\n' "000" "$path" "$url"; failures=$((failures + 1)); continue ;;
    esac
    # -L follow redirects (repos get renamed and 301 — that's a pass, but we
    #    report the final URL so .gitmodules can be updated).
    # -I HEAD only; --max-time so one dead host can't hang the whole run.
    # A single curl call gets both the code and the effective URL — two calls
    # would double the request count against GitHub for no benefit.
    # The trailing \n in -w is required: without it `read` hits EOF, returns
    # non-zero, and `set -e` kills the whole run on the first URL.
    read -r code final < <(curl -sS -I -L --max-time 20 -o /dev/null \
      -w '%{http_code} %{url_effective}\n' -- "$url" 2>/dev/null || echo "000 $url")
    if [ "$code" = "200" ]; then
      if [ "${final%/}" != "${url%/}" ]; then
        printf '  MOVED   %-40s %s\n' "$path" "$url"
        printf '          %-40s -> %s\n' "" "$final"
      else
        printf '  ok      %-40s %s\n' "$path" "$url"
      fi
    else
      printf '  FAIL %s %-40s %s\n' "$code" "$path" "$url"
      failures=$((failures + 1))
    fi
  done < <(read_submodules | LC_ALL=C sort)
  echo ""
  echo "$total checked, $failures failed."
  [ "$failures" -eq 0 ] || exit 1
  exit 0
fi

# --- Generate the document ---------------------------------------------------
mkdir -p "$(dirname "$OUT")"

{
  printf '# the-grid — sources\n\n'
  printf '> Generated by `scripts/sources.sh` from `.gitmodules`.\n'
  printf '> **Do not edit by hand** — re-run `bash scripts/sources.sh` after adding or removing a submodule.\n'
  printf '> Check for rot with `bash scripts/sources.sh --check` (HEADs every URL, non-zero exit on failure).\n\n'
  printf 'The canonical upstream for every repo the-grid tracks — one line per submodule, nothing else.\n'
  printf 'Tier is read from `baseline-submodules.txt` (baseline only, so this file stays machine-agnostic):\n\n'
  printf -- '- **wired** — every skill in the repo is symlinked live on every machine.\n'
  printf -- '- **partial** — only the skills named in the baseline are wired.\n'
  printf -- '- **library** — indexed and searchable (`skill-scout`), not wired.\n\n'
  printf 'For the per-skill breakdown see [`SKILLS.md`](../SKILLS.md). For the frozen May-2026 research\n'
  printf 'bibliography (not maintained, kept for provenance) see [`reference-resources.md`](reference-resources.md).\n\n'

  printf '| Submodule | Tier | Upstream |\n'
  printf '|---|---|---|\n'
  ssh_form=0
  while IFS=$'\t' read -r path clone_url url; do
    [ -n "$path" ] || continue
    tier="$(repo_tier "$(basename "$path")")"
    # tests/lib/* are build dependencies (bats), not ecosystem sources — label
    # them so they don't read as a skill repo that someone forgot to wire.
    case "$path" in tests/*) tier="tooling" ;; esac
    # Mark SSH-form clone URLs — see the note below the table.
    case "$clone_url" in git@*|ssh://*) ssh_form=$((ssh_form + 1)); tier="$tier ᵍ" ;; esac
    printf '| `%s` | %s | <%s> |\n' "$path" "$tier" "$url"
  done < <(read_submodules | LC_ALL=C sort)
  printf '\n'

  if [ "$ssh_form" -gt 0 ]; then
    printf 'ᵍ Clone URL in `.gitmodules` is the SSH form (`git@github.com:…`), not HTTPS — %s of them.\n' "$ssh_form"
    printf 'The link above is the browsable HTTPS equivalent; the clone URL itself is unchanged.\n'
    printf 'These only clone on a machine whose **default** `github.com` SSH identity can read the repo,\n'
    printf 'so `git submodule update --init` can fail on a new machine even though every repo is public.\n\n'
  fi

  # External tooling the wired skills hard-depend on but that is NOT a submodule
  # (installed via a package manager). Kept short on purpose — if a wired skill
  # will silently no-op without an external binary, it belongs here.
  printf '## External dependencies (not submodules)\n\n'
  printf 'Installed per-machine, not vendored. A wired skill that shells out to one of these\n'
  printf 'is inert until it is installed — see `BOOTSTRAP.md`.\n\n'
  printf '| Dependency | Needed by | Install | Home |\n'
  printf '|---|---|---|---|\n'
  printf '| `openspec` CLI | every `repos/openspec` skill (`allowed-tools: Bash(openspec:*)`) | `npm i -g @fission-ai/openspec@latest` (Node >= 20.19.0) | <https://openspec.dev> |\n'
  printf '\n'
} > "$OUT"

if [ "$DRIFT_MODE" -eq 1 ]; then
  # Exit 0 current, 1 stale (a short diff says how), 2 error (handled above).
  if cmp -s "$OUT" "$COMMITTED"; then
    echo "sources: docs/SOURCES.md is current"
    exit 0
  fi
  diff -u "$COMMITTED" "$OUT" | head -n 40 >&2 || true
  echo "sources: docs/SOURCES.md is stale; regenerate with: bash scripts/sources.sh" >&2
  exit 1
fi

count="$(read_submodules | wc -l | tr -d ' ')"
echo "Wrote $OUT ($count submodules)."
