#!/usr/bin/env bash
# check-translations.sh [--strict] — are the README translations current?
#
# For each locale in scripts/lib/readme-locales.txt whose README.<locale>.md exists, compare the
# source-sha256 in its header with the hash of README.md now (scripts/lib/readme-hash.sh: the
# switcher block and count values are ignored, so only prose edits make a translation stale).
#
#   STALE <locale>     the file exists but was made from different README prose  -> exit 1
#   MISSING <locale>   --strict only: no file for that locale                    -> exit 1
#
# A missing file is otherwise ignored, so a repo with no translations passes. scripts/gate.sh runs
# this WITHOUT --strict and only warns; --strict is for the release task.
# Fix a stale file with: bash scripts/translate-readme.sh --all   (opt-in, costs tokens)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCALES_FILE="$SCRIPT_DIR/lib/readme-locales.txt"

# shellcheck source=lib/readme-hash.sh
. "$SCRIPT_DIR/lib/readme-hash.sh"

STRICT=0
case "${1:-}" in
  "")       ;;
  --strict) STRICT=1 ;;
  *)        echo "usage: check-translations.sh [--strict]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: check-translations.sh [--strict]" >&2; exit 2; }

[ -f "$GRID_DIR/README.md" ] || { echo "check-translations: README.md not found" >&2; exit 1; }
[ -f "$LOCALES_FILE" ] || { echo "check-translations: $LOCALES_FILE not found" >&2; exit 1; }

SRC_HASH="$(readme_source_hash "$GRID_DIR/README.md")"
bad=0
# shellcheck disable=SC2034  # the label column is read only to split the line
while IFS=$'\t' read -r code label; do
  [ -n "$code" ] || continue
  f="$GRID_DIR/README.$code.md"
  if [ ! -f "$f" ]; then
    if [ "$STRICT" = 1 ]; then echo "MISSING $code"; bad=1; fi
    continue
  fi
  # A file with no readable header hash counts as stale too: it was not made by the script.
  if [ "$(readme_header_hash "$f")" != "$SRC_HASH" ]; then
    echo "STALE $code"
    bad=1
  fi
done < "$LOCALES_FILE"

exit "$bad"
