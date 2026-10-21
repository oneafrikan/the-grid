#!/usr/bin/env bash
# readme-hash.sh — sourced by translate-readme.sh and check-translations.sh.
#
# One definition of "the English README as the translators see it", so the script that
# writes a translation and the script that checks it can never disagree about staleness.
#
#   readme_normalise <file>     the README with the <!-- langs --> block and every count-marker
#                               value removed (stdout). Switcher edits and skill-count changes
#                               therefore never mark a translation stale; only prose edits do.
#   readme_source_hash <file>   sha256 of that normalised text (first field only).
#   readme_header_hash <file>   the source-sha256 recorded in a translation's header, or nothing.
#
# The sed program is pinned byte for byte by the openspec change `front-door` (design.md,
# "Translations"): do not "tidy" it. Callers also run under LC_ALL=C: the locale file holds
# UTF-8 labels and nothing here ever measures a string's length.

readme_normalise() {
  LC_ALL=C sed -E -e 's#<!-- langs -->.*<!-- /langs -->##' -e 's#(<!--count:[a-z_]+-->)[^<]*(<!--/count-->)#\1\2#g' "$1"
}

readme_source_hash() {
  local sum
  # shasum ships with macOS and perl; sha256sum with GNU coreutils. Either is enough.
  if command -v shasum >/dev/null 2>&1; then
    sum="$(readme_normalise "$1" | shasum -a 256)"
  else
    sum="$(readme_normalise "$1" | sha256sum)"
  fi
  printf '%s\n' "${sum%% *}"
}

# The header is line 1 of a translation:
#   <!-- machine-translated from README.md; source-sha256=<64 hex>; locale=ja; do not edit by hand -->
readme_header_hash() {
  head -n 1 "$1" | LC_ALL=C sed -n 's#.*source-sha256=\([0-9a-f]*\);.*#\1#p'
}
