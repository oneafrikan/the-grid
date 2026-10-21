#!/usr/bin/env bats
# Tests for scripts/build-site-assets.sh and assets/favicon.svg.
# The build test needs ImageMagick with a WebP delegate and skips cleanly without it.

load helpers/setup

SCRIPT="$REPO_ROOT/scripts/build-site-assets.sh"

# Echo the ImageMagick binary that can write WebP, or nothing.
find_im() {
  local im
  for im in magick convert; do
    if command -v "$im" >/dev/null 2>&1 && "$im" -list format 2>/dev/null | grep -i webp >/dev/null; then
      printf '%s\n' "$im"
      return 0
    fi
  done
  return 0
}

@test "no arguments is a usage error (exit 2)" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}

@test "a PATH without ImageMagick exits 3 with install hints" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/src.png"
  PATH="$(path_without magick convert identify)" run bash "$SCRIPT" "$BATS_TEST_TMPDIR/src.png" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 3 ]
  [[ "$output" == *"apt install imagemagick"* ]]
}

@test "builds hero.webp and og.jpg, and a second run gives identical bytes" {
  local im
  im="$(find_im)"
  [ -n "$im" ] || skip "ImageMagick with WebP support is not installed"

  # Synthetic 2816x1536 RGB gradient using only the python3 stdlib.
  python3 -I -c '
import struct, sys, zlib
w, h = 2816, 1536
rows = b"".join(b"\x00" + bytes(((x * 255) // w, (y * 255) // h, 128)[c] for x in range(w) for c in range(3)) for y in range(h))
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
' "$BATS_TEST_TMPDIR/src.png"

  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/src.png" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$BATS_TEST_TMPDIR/out/hero.webp")" -lt 300000 ]
  [ "$("$im" identify -format '%wx%h' "$BATS_TEST_TMPDIR/out/og.jpg" 2>/dev/null || identify -format '%wx%h' "$BATS_TEST_TMPDIR/out/og.jpg")" = "1200x630" ]

  first="$(cksum "$BATS_TEST_TMPDIR"/out/hero.webp "$BATS_TEST_TMPDIR"/out/og.jpg)"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/src.png" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cksum "$BATS_TEST_TMPDIR"/out/hero.webp "$BATS_TEST_TMPDIR"/out/og.jpg)" = "$first" ]
}

@test "favicon.svg is well-formed XML under 2 KB" {
  python3 -I -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$REPO_ROOT/assets/favicon.svg"
  [ "$(wc -c < "$REPO_ROOT/assets/favicon.svg")" -lt 2048 ]
}
