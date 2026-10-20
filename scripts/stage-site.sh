#!/usr/bin/env bash
# stage-site.sh — copy exactly the files listed in site-files.txt into a fresh
# output dir, ready for the GitHub Pages artifact upload.
#
#   bash scripts/stage-site.sh [--adopt] <out-dir>
#
# Why a list and not "publish the repo": the repo root holds ~544 MB of
# third-party submodule trees (repos/) that must never be served.
#
# site-files.txt: one repo-relative path per line, blank lines and '#' comments
# ignored, a directory is copied whole.
#
# Exit codes: 0 ok, 1 a listed path does not exist, 2 a listed path is unsafe
# (absolute, contains '..' or a '.' component, names the repo root, is or goes through
# a symlink, or starts with repos/ .git or .github), the out dir is unsafe, or bad usage.
#
# The out dir is deleted and recreated, so it must never be, contain or alias the repo.
# Inside the repo only a top-level untracked '_name' is accepted (CI uses _site).
# Outside the repo the out dir must be absent, empty, or hold the sentinel file
# (.stage-site-out) that a previous run wrote; anything else exits 2 so a mistyped
# path (HOME, /tmp, a project dir) is never wiped. '--adopt' lets ONE run take over an
# existing non-empty dir; that run then writes the sentinel. The sentinel is staged into
# the site and published with it (a one-line dotfile, harmless).
#
# Env: GRID_DIR (default: parent of scripts/) — tests point it at a fixture.
set -euo pipefail
export LC_ALL=C

src="${BASH_SOURCE[0]:-$0}"
GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$src")/.." && pwd)}"
SENTINEL=".stage-site-out"
adopt=0
if [ "${1:-}" = "--adopt" ]; then adopt=1; shift; fi   # only this exact word; '-rf' stays a path
out="${1:-}"
[ -n "$out" ] || { echo "usage: stage-site.sh [--adopt] <out-dir>" >&2; exit 2; }

# The out dir is recreated with rm -rf below, so resolve it to a physical path first and
# refuse anything that is, contains or aliases the repo. A string compare is not enough:
# '$GRID_DIR//', a symlink to the repo and a parent of the repo all name the same tree.
# Resolution walks up to the nearest existing ancestor so a not-yet-created out dir works.
# Every path is canonicalised to ONE leading slash before any comparison: a shell may print a
# physical path as '//x' (a '//'-prefixed argument, a symlink to '/'), which would never string-
# match '/x'. '--' keeps a relative name that starts with '-' from being read as an option.
canon_slashes() {
  local p="$1"
  while [ "${p#//}" != "$p" ]; do p="${p#/}"; done
  printf '%s' "$p"
}
resolve_phys() {
  local p="$1" rest=""
  while [ ! -d "$p" ]; do
    rest="/$(basename -- "$p")$rest"
    p="$(dirname -- "$p")"
  done
  p="$(cd -P -- "$p" && pwd -P)"
  p="$(canon_slashes "$p")"
  [ "$p" = "/" ] && p=""
  printf '%s\n' "$p$rest"
}
out_trim="$out"
while [ "${#out_trim}" -gt 1 ] && [ "${out_trim%/}" != "$out_trim" ]; do out_trim="${out_trim%/}"; done
case "$out_trim" in
  ..|*/..|*/../*|../*) echo "stage-site: refusing out dir '$out' ('..' not allowed)" >&2; exit 2 ;;
esac
grid_phys="$(canon_slashes "$(cd -P -- "$GRID_DIR" && pwd -P)")"
out_phys="$(resolve_phys "$out_trim")"
[ -n "$out_phys" ] || { echo "stage-site: refusing out dir '$out' (filesystem root)" >&2; exit 2; }
# out is, or is an ancestor of, the repo (this also covers GRID_DIR/.git).
case "$grid_phys/" in
  "$out_phys"/*) echo "stage-site: refusing out dir '$out': it is, or contains, the repo ($grid_phys)" >&2; exit 2 ;;
esac
# out is inside the repo: only a top-level '_name' that is not tracked may be wiped.
case "$out_phys" in
  "$grid_phys"/*)
    rel="${out_phys#"$grid_phys"/}"
    top="${rel%%/*}"
    case "$top" in
      _*) ;;
      *) echo "stage-site: refusing out dir '$out': inside the repo only a top-level '_name' is allowed (CI uses _site)" >&2; exit 2 ;;
    esac
    # A tracked '_dir' (for example _retired) must never be wiped by a staging run.
    if [ -n "$(git -C "$grid_phys" ls-files -- "$top" 2>/dev/null)" ]; then
      echo "stage-site: refusing out dir '$out': '$top' is tracked in the repo" >&2; exit 2
    fi ;;
esac

# The out dir will be wiped: only an absent or empty dir, or one marked by a previous run,
# is safe. A plain file, a symlinked sentinel or any other content is refused unless --adopt.
if [ -e "$out_phys" ]; then
  if [ ! -d "$out_phys" ]; then
    echo "stage-site: refusing out dir '$out': it exists and is not a directory" >&2; exit 2
  fi
  if [ -f "$out_phys/$SENTINEL" ] && [ ! -L "$out_phys/$SENTINEL" ]; then
    :   # written by a previous run
  elif [ -n "$(find "$out_phys" -mindepth 1 -print -quit)" ] && [ "$adopt" -ne 1 ]; then
    echo "stage-site: refusing out dir '$out': it is not empty and has no $SENTINEL marker (pass --adopt to take it over)" >&2; exit 2
  fi
fi

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
  orig="$line"                                         # for messages: '.', './' look alike once normalised
  while [ "${line#./}" != "$line" ]; do line="${line#./}"; done   # './repos/x' must not dodge the rules
  while [ "${line%/}" != "$line" ]; do line="${line%/}"; done      # 'dir/' and 'a/./' normalise too
  case "$line" in
    /*)                          echo "stage-site: absolute path not allowed: $line" >&2; exit 2 ;;
    *..*)                        echo "stage-site: '..' not allowed: $line" >&2; exit 2 ;;
    ""|.|./*|*/.|*/./*)          # a '.' entry would publish the whole repo root
                                 echo "stage-site: '.' path not allowed: $orig" >&2; exit 2 ;;
    repos|repos/*|.git*)                               # .git* also covers .github
                                 echo "stage-site: forbidden path: $line" >&2; exit 2 ;;
  esac
  if [ ! -e "$GRID_DIR/$line" ] && [ ! -L "$GRID_DIR/$line" ]; then
    echo "stage-site: listed path does not exist: $line" >&2; exit 1
  fi
  # Symlinks: a link in the repo could publish a file from outside the site list (cp would
  # copy the link, and the Pages upload follows it). Refuse the entry, any parent of it that
  # is a link, and any link below a directory entry.
  walk="$GRID_DIR"
  IFS=/ read -r -a parts <<< "$line"
  for part in "${parts[@]}"; do
    walk="$walk/$part"
    if [ -L "$walk" ]; then
      echo "stage-site: symlink not allowed: $line (at ${walk#"$GRID_DIR"/})" >&2; exit 2
    fi
  done
  if [ -n "$(find "$GRID_DIR/$line" -type l -print -quit)" ]; then
    echo "stage-site: symlink inside listed directory not allowed: $line" >&2; exit 2
  fi
  paths+=("$line")
done < "$list"

# Pass 2: recreate the output dir empty and copy each path to the same
# relative location (so a second run removes stale files from the first).
# From here on only the canonical physical path is used (the one the guards judged), never
# the raw argument spelling.
out="$out_phys"
rm -rf -- "$out"
mkdir -p -- "$out"
printf 'staged by scripts/stage-site.sh; safe to wipe on the next run\n' > "$out/$SENTINEL"
for p in ${paths[@]+"${paths[@]}"}; do
  mkdir -p -- "$out/$(dirname -- "$p")"
  cp -R -P -- "$GRID_DIR/$p" "$out/$p"
done
# Belt and braces: nothing in the staged tree may be a link, whatever pass 1 missed.
if [ -n "$(find "$out" -type l -print -quit)" ]; then
  rm -rf -- "$out"
  echo "stage-site: staged tree contains a symlink; removed $out" >&2; exit 2
fi
echo "stage-site: staged ${#paths[@]} path(s) into $out"
