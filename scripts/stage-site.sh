#!/usr/bin/env bash
# stage-site.sh — copy exactly the files listed in site-files.txt into a fresh
# output dir, ready for the GitHub Pages artifact upload.
#
#   bash scripts/stage-site.sh <out-dir>
#
# Why a list and not "publish the repo": the repo root holds ~544 MB of
# third-party submodule trees (repos/) that must never be served.
#
# site-files.txt: one repo-relative path per line, blank lines and '#' comments
# ignored, a directory is copied whole.
#
# Exit codes: 0 ok, 1 a listed path does not exist, 2 a listed path is unsafe
# (absolute, contains '..', or starts with repos/ .git or .github) or bad usage.
#
# Env: GRID_DIR (default: parent of scripts/) — tests point it at a fixture.
set -euo pipefail
export LC_ALL=C

src="${BASH_SOURCE[0]:-$0}"
GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$src")/.." && pwd)}"
out="${1:-}"
[ -n "$out" ] || { echo "usage: stage-site.sh <out-dir>" >&2; exit 2; }
# The out dir is recreated with rm -rf below: never let it be the repo itself.
case "${out%/}" in
  ""|.|..|"${GRID_DIR%/}") echo "stage-site: refusing out dir '$out'" >&2; exit 2 ;;
esac
list="$GRID_DIR/site-files.txt"
[ -f "$list" ] || { echo "stage-site: no $list" >&2; exit 1; }

# Pass 1: validate every line before touching the output dir, so a bad list
# never leaves a half-staged site behind.
paths=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"                                   # strip comment
  line="${line#"${line%%[![:space:]]*}"}"              # ltrim
  line="${line%"${line##*[![:space:]]}"}"              # rtrim
  [ -n "$line" ] || continue
  line="${line#./}"                                    # './repos/x' must not dodge the rules
  case "$line" in
    /*)                          echo "stage-site: absolute path not allowed: $line" >&2; exit 2 ;;
    *..*)                        echo "stage-site: '..' not allowed: $line" >&2; exit 2 ;;
    repos|repos/*|.git*)                               # .git* also covers .github
                                 echo "stage-site: forbidden path: $line" >&2; exit 2 ;;
  esac
  if [ ! -e "$GRID_DIR/$line" ]; then
    echo "stage-site: listed path does not exist: $line" >&2; exit 1
  fi
  paths+=("$line")
done < "$list"

# Pass 2: recreate the output dir empty and copy each path to the same
# relative location (so a second run removes stale files from the first).
rm -rf "$out"
mkdir -p "$out"
for p in ${paths[@]+"${paths[@]}"}; do
  mkdir -p "$out/$(dirname "$p")"
  cp -R "$GRID_DIR/$p" "$out/$p"
done
echo "stage-site: staged ${#paths[@]} path(s) into $out"
