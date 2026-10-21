#!/usr/bin/env bash
# build-site-assets.sh — render the landing-page images from one source PNG.
#
#   bash scripts/build-site-assets.sh <source.png> [outdir=assets]
#
# Outputs (in outdir):
#   hero.webp  1600 px wide, quality 80 stepping down to 70 until under 300 KB
#   og.jpg     1200x630 cover crop (centre gravity), quality 82, under 250 KB
#
# Why ImageMagick only: one image dependency keeps the render a single command
# for the operator. favicon.svg is hand-written and committed; the raster icons
# are rendered from it by hand (see openspec/changes/front-door/tasks.md 6.2).
#
# Metadata is stripped and nothing time-dependent is embedded, so a second run on
# the same source and ImageMagick version gives identical bytes. Outputs are built
# in a temp dir and moved into place only when both pass their size limits, so a
# failed run never leaves a half-written or oversized asset behind.
#
# Sizes are measured with `wc -c < file` because `stat` differs on BSD and GNU.
# Written for bash 3.2 (macOS): no associative arrays, no ${var,,}, no mapfile.
#
# Exit codes: 0 ok, 2 usage error or unreadable source, 3 ImageMagick or its
# WebP support is missing, 4 hero.webp cannot get under 300 KB, 5 og.jpg is
# not under 250 KB.
set -euo pipefail
export LC_ALL=C

HERO_MAX=300000   # bytes; "300 KB" is read as decimal so the page weight budget holds
OG_MAX=250000     # bytes

usage() {
  echo "usage: build-site-assets.sh <source.png> [outdir=assets]" >&2
  exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
src="$1"
outdir="${2:-assets}"

# ImageMagick 7 ships `magick`; v6 ships `convert`. Prefer `magick`.
if command -v magick >/dev/null 2>&1; then
  im=magick
elif command -v convert >/dev/null 2>&1; then
  im=convert
else
  im=""
fi

hints() {
  cat >&2 <<'EOF'
build-site-assets.sh: ImageMagick with WebP support is required. Install it with:
  brew install imagemagick     (macOS)
  apt install imagemagick      (Debian/Ubuntu)
  pacman -S imagemagick        (Arch)
EOF
  exit 3
}

[ -n "$im" ] || hints
# A WebP delegate is not guaranteed even when ImageMagick is installed. No -q so grep
# reads all of the listing (an early exit would SIGPIPE the producer under pipefail).
"$im" -list format 2>/dev/null | grep -i webp >/dev/null || hints

[ -f "$src" ] && [ -r "$src" ] || { echo "build-site-assets.sh: cannot read source: $src" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/site-assets.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# hero.webp: first quality (80, 75, 70) that lands under the limit wins. Below 70 the
# wordmark shows artefacts, so there is no further step.
hero_ok=0
for q in 80 75 70; do
  "$im" "$src" -strip -resize 1600x -quality "$q" -define webp:method=6 "$tmp/hero.webp"
  size="$(wc -c < "$tmp/hero.webp")"
  size="${size//[[:space:]]/}"   # BSD wc pads with spaces
  if [ "$size" -lt "$HERO_MAX" ]; then hero_ok=1; break; fi
done
if [ "$hero_ok" -ne 1 ]; then
  echo "build-site-assets.sh: hero.webp is $size bytes at quality 70 (limit $HERO_MAX); use a simpler source" >&2
  exit 4
fi

# og.jpg: `^` fills the box on the short side, then the centred -extent crops the overflow.
"$im" "$src" -strip -resize 1200x630^ -gravity center -extent 1200x630 -quality 82 "$tmp/og.jpg"
size="$(wc -c < "$tmp/og.jpg")"
size="${size//[[:space:]]/}"
if [ "$size" -ge "$OG_MAX" ]; then
  echo "build-site-assets.sh: og.jpg is $size bytes (limit $OG_MAX)" >&2
  exit 5
fi

mkdir -p "$outdir"
mv -f "$tmp/hero.webp" "$outdir/hero.webp"
mv -f "$tmp/og.jpg" "$outdir/og.jpg"
echo "wrote $outdir/hero.webp and $outdir/og.jpg"
