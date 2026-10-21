#!/usr/bin/env bash
# translate-readme.sh — (re)generate the machine translations of README.md.
#
#   translate-readme.sh --all                 every locale in scripts/lib/readme-locales.txt
#   translate-readme.sh --locale ja [--locale fr ...]
#   translate-readme.sh --dry-run ...         print what would be translated and the input size; call nothing
#   translate-readme.sh --switcher-only       rewrite the <!-- langs --> switcher everywhere; no model call
#
# OPT-IN AND PAID: one `claude -p --model sonnet` call per locale. Never run from the gate or a
# hook. Run it by hand after README prose changes (scripts/check-translations.sh says when).
#
# Per locale: normalise README.md (scripts/lib/readme-hash.sh), send it on stdin with the prompt
# from docs/translation-prompt.md, validate the reply, then write README.<locale>.md atomically
# (temp file, then mv). The script writes the header, switcher and notice; the model supplies only
# the body. Locales whose recorded source hash already matches README.md are skipped, so a second
# run with an unchanged README changes nothing.
#
# After the locales: the switcher in README.md and in every existing translation is rewritten
# (lists only files that exist), then scripts/stamp-counts.py fills the count markers.
#
# Failure: a locale whose call or validation fails leaves its old file untouched; the others still
# run; the exit status is 1. Exit 2 is a usage error.
#
# The tests set GRID_CLAUDE to a stub (tests/helpers/stubs.bash). Everything touching the locale
# file runs under LC_ALL=C and never measures the length of a UTF-8 string (labels are UTF-8).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCALES_FILE="$SCRIPT_DIR/lib/readme-locales.txt"
PROMPT_FILE="$GRID_DIR/docs/translation-prompt.md"
README="$GRID_DIR/README.md"

# shellcheck source=lib/readme-hash.sh
. "$SCRIPT_DIR/lib/readme-hash.sh"

usage() {
  echo "usage: translate-readme.sh (--all | --locale L [--locale L ...] | --switcher-only) [--dry-run]" >&2
  exit "${1:-2}"
}

ALL=0
DRY=0
SW_ONLY=0
WANT=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)           ALL=1 ;;
    --locale)        [ "$#" -ge 2 ] || usage; WANT+=("$2"); shift ;;
    --dry-run)       DRY=1 ;;
    --switcher-only) SW_ONLY=1 ;;
    -h|--help)       usage 0 ;;
    *)               usage ;;
  esac
  shift
done

# --switcher-only stands alone; otherwise exactly one of --all / --locale is needed.
if [ "$SW_ONLY" = 1 ]; then
  [ "$ALL" = 0 ] && [ "${#WANT[@]}" -eq 0 ] && [ "$DRY" = 0 ] || usage
else
  if [ "$ALL" = 1 ] && [ "${#WANT[@]}" -gt 0 ]; then usage; fi
  if [ "$ALL" = 0 ] && [ "${#WANT[@]}" -eq 0 ]; then usage; fi
fi

[ -f "$README" ] || { echo "translate-readme: $README not found" >&2; exit 1; }
[ -f "$LOCALES_FILE" ] || { echo "translate-readme: $LOCALES_FILE not found" >&2; exit 1; }

# --- locale file helpers ---------------------------------------------------------------------
# locale_label <code> — the display label, or return 1 for an unknown code.
locale_label() {
  local c l
  while IFS=$'\t' read -r c l; do
    if [ "$c" = "$1" ]; then printf '%s' "$l"; return 0; fi
  done < "$LOCALES_FILE"
  return 1
}

# ALL_CODES — every locale code, in file (= switcher) order.
ALL_CODES=()
while IFS=$'\t' read -r c l; do
  if [ -n "$c" ]; then ALL_CODES+=("$c"); fi
done < "$LOCALES_FILE"

# switcher_for <current> — the text between <!-- langs --> and <!-- /langs --> for a file whose
# language is <current> ("en" for README.md). English first, then each locale whose file exists
# (or is <current>, which exists by definition); the current language is bold. Empty when no
# translation exists at all, so a README with no translations carries no switcher.
switcher_for() {
  local current="$1" c l out item n=0 sep=" · "
  if [ "$current" = en ]; then out="**English**"; else out="[English](README.md)"; fi
  while IFS=$'\t' read -r c l; do
    [ -n "$c" ] || continue
    if [ "$c" = "$current" ]; then
      item="**$l**"
    elif [ -f "$GRID_DIR/README.$c.md" ]; then
      item="[$l](README.$c.md)"
    else
      continue
    fi
    out="$out$sep$item"
    n=$((n + 1))
  done < "$LOCALES_FILE"
  if [ "$n" -eq 0 ] && [ "$current" = en ]; then out=""; fi
  printf '%s' "$out"
}

# --- temp files ------------------------------------------------------------------------------
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/readme-translate.XXXXXX")" || exit 1
CUR_TMP=""   # a temp file inside GRID_DIR (same filesystem as its target, so mv is atomic)
cleanup() {
  rm -rf "$SCRATCH"
  if [ -n "$CUR_TMP" ]; then rm -f "$CUR_TMP"; fi
}
trap cleanup EXIT

# write_switcher <file> <switcher text> — replace the text inside the file's first
# <!-- langs -->...<!-- /langs --> pair. A file without the pair, or already correct, is left
# alone (no rewrite, so its mtime and bytes stay put).
write_switcher() {
  local f="$1" sw="$2"
  [ -f "$f" ] || return 0
  grep -q '<!-- langs -->.*<!-- /langs -->' "$f" || return 0
  CUR_TMP="$(mktemp "$GRID_DIR/.readme-switcher.XXXXXX")" || return 1
  # The text goes through the environment, not -v, so awk does not interpret escapes in it.
  if ! SWITCHER="$sw" awk '
      BEGIN { open = "<!-- langs -->"; shut = "<!-- /langs -->" }
      !done {
        s = index($0, open); e = index($0, shut)
        if (s > 0 && e > s) {
          $0 = substr($0, 1, s - 1 + length(open)) ENVIRON["SWITCHER"] substr($0, e)
          done = 1
        }
      }
      { print }' "$f" > "$CUR_TMP"; then
    return 1
  fi
  if cmp -s "$CUR_TMP" "$f"; then rm -f "$CUR_TMP"; CUR_TMP=""; return 0; fi
  chmod 644 "$CUR_TMP" && mv "$CUR_TMP" "$f" || return 1
  CUR_TMP=""
  echo "switcher: updated $(basename "$f")"
}

# rewrite_all_switchers — README.md plus every existing translation named in the locale file.
rewrite_all_switchers() {
  local c rc=0
  write_switcher "$README" "$(switcher_for en)" || rc=1
  for c in "${ALL_CODES[@]}"; do
    write_switcher "$GRID_DIR/README.$c.md" "$(switcher_for "$c")" || rc=1
  done
  return "$rc"
}

if [ "$SW_ONLY" = 1 ]; then
  rewrite_all_switchers || { echo "translate-readme: switcher rewrite failed" >&2; exit 1; }
  exit 0
fi

# --- choose the locales ----------------------------------------------------------------------
TARGETS=()
if [ "$ALL" = 1 ]; then
  TARGETS=("${ALL_CODES[@]}")
else
  for c in "${WANT[@]}"; do
    locale_label "$c" >/dev/null || { echo "translate-readme: unknown locale '$c' (see scripts/lib/readme-locales.txt)" >&2; exit 2; }
    TARGETS+=("$c")
  done
fi

SRC_HASH="$(readme_source_hash "$README")"
NORM="$SCRATCH/readme.norm"
readme_normalise "$README" > "$NORM"

# is_current <code> — README.<code>.md exists and records the current source hash.
is_current() {
  local f="$GRID_DIR/README.$1.md"
  [ -f "$f" ] && [ "$(readme_header_hash "$f")" = "$SRC_HASH" ]
}

if [ "$DRY" = 1 ]; then
  # Input = normalised README on stdin + the prompt argument. Bytes, not tokens: no estimate of
  # the model's tokenizer is attempted.
  bytes=$(( $(wc -c < "$NORM") + $(wc -c < "$PROMPT_FILE") ))
  for c in "${TARGETS[@]}"; do
    if is_current "$c"; then echo "skip $c (current)"; else echo "translate $c"; fi
  done
  echo "estimated input per locale: $bytes bytes"
  exit 0
fi

[ -f "$PROMPT_FILE" ] || { echo "translate-readme: $PROMPT_FILE not found" >&2; exit 1; }

# --- validation ------------------------------------------------------------------------------
# fence_count <file> — lines that open or close a ``` fence.
fence_count() { grep -c '^ *```' "$1"; }

# count_markers <file> — the sorted list of count-marker tags (opening and closing).
count_markers() { grep -oE '<!--/?count[:a-z_]*-->' "$1" | sort; }

# rel_links <file> — sorted unique relative link targets, fragments stripped.
rel_links() {
  grep -oE '\]\([^)[:space:]]+\)' "$1" \
    | sed -e 's/^](//' -e 's/)$//' \
    | grep -vE '^(https?:|mailto:|#)' \
    | sed -e 's/#.*$//' \
    | sort -u
}

# validate_output <file> — 0 if the reply is safe to write, else 1 with the reason on stderr.
validate_output() {
  local raw="$1" first missing
  [ -s "$raw" ] || { echo "empty output" >&2; return 1; }
  first="$(head -n 1 "$raw")"
  case "$first" in
    "# "*) ;;
    *) echo "output does not start with a '# ' heading" >&2; return 1 ;;
  esac
  if [ "$(fence_count "$NORM")" != "$(fence_count "$raw")" ]; then
    echo "code fence count differs from the source" >&2; return 1
  fi
  if [ "$(count_markers "$NORM")" != "$(count_markers "$raw")" ]; then
    echo "count markers differ from the source" >&2; return 1
  fi
  rel_links "$NORM" > "$SCRATCH/links.src"
  rel_links "$raw" > "$SCRATCH/links.out"
  missing="$(comm -23 "$SCRATCH/links.src" "$SCRATCH/links.out")"
  if [ -n "$missing" ]; then
    echo "relative links missing from the output: $(printf '%s' "$missing" | tr '\n' ' ')" >&2; return 1
  fi
  return 0
}

# --- one locale ------------------------------------------------------------------------------
# translate_one <code> — 0 on success (file written), 1 on any failure (old file untouched).
translate_one() {
  local code="$1" label prompt raw="$SCRATCH/reply.$1" err="$SCRATCH/err.$1" cmd
  label="$(locale_label "$code")" || return 1
  prompt="$(cat "$PROMPT_FILE")"
  prompt="$prompt"$'\n\n'"Target locale: $code ($label)."

  # An array, so the empty --tools "" argument survives and nothing is word-split.
  cmd=("${GRID_CLAUDE:-claude}" -p --model sonnet --max-budget-usd 1 --no-session-persistence --tools "" --disable-slash-commands "$prompt")
  if ! "${cmd[@]}" < "$NORM" > "$raw" 2> "$err"; then
    echo "translator call failed: $(head -n 3 "$err" | tr '\n' ' ')" >&2
    return 1
  fi
  validate_output "$raw" || return 1

  CUR_TMP="$(mktemp "$GRID_DIR/.README.XXXXXX")" || return 1
  {
    printf '<!-- machine-translated from README.md; source-sha256=%s; locale=%s; do not edit by hand -->\n' "$SRC_HASH" "$code"
    printf '<!-- langs -->%s<!-- /langs -->\n\n' "$(switcher_for "$code")"
    printf '> Machine-translated from the [English README](README.md). The English version is authoritative.\n\n'
    cat "$raw"
    # Ensure the file ends with a newline whatever the model did.
    if [ -n "$(tail -c 1 "$raw")" ]; then printf '\n'; fi
  } > "$CUR_TMP" || return 1
  chmod 644 "$CUR_TMP" && mv "$CUR_TMP" "$GRID_DIR/README.$code.md" || return 1
  CUR_TMP=""
  echo "wrote README.$code.md"
}

FAILED=0
for c in "${TARGETS[@]}"; do
  if is_current "$c"; then
    echo "skip $c (current)"
    continue
  fi
  if ! translate_one "$c"; then
    echo "translate-readme: FAILED $c (old file kept)" >&2
    CUR_TMP=""
    FAILED=$((FAILED + 1))
  fi
done

rewrite_all_switchers || { echo "translate-readme: switcher rewrite failed" >&2; FAILED=$((FAILED + 1)); }

# Count markers in the new translations come back empty (they were blanked for the hash);
# stamp-counts.py fills them from the same sources as the English README.
if command -v python3 >/dev/null 2>&1 && [ -f "$GRID_DIR/scripts/stamp-counts.py" ]; then
  ( cd "$GRID_DIR" && GRID_DIR="$GRID_DIR" python3 scripts/stamp-counts.py ) \
    || { echo "translate-readme: stamp-counts.py failed" >&2; FAILED=$((FAILED + 1)); }
else
  echo "translate-readme: python3 or scripts/stamp-counts.py absent - counts not stamped" >&2
fi

[ "$FAILED" -eq 0 ] || exit 1
exit 0
