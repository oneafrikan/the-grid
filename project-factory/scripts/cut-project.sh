#!/usr/bin/env bash
# cut-project.sh — seed a new project or retrofit an existing one from a
# project-factory template.
#
# Usage:
#   cut-project.sh <template> <target-dir>
#
# Mode is auto-detected from the target directory, not passed as a flag:
#   - target doesn't exist, or exists and is empty  -> SEED
#   - target exists with files                       -> RETROFIT
#
# Every cut lays down templates/_common/ (session-continuity scaffolding every
# project needs: CONTEXT.md, LEARNINGS.md, handoffs/, the issue-loop pairing
# prompt) followed by templates/<template>/ (the stack-specific pieces). Both
# passes run the exact same copy rule: NEVER overwrite a file that already
# exists in the target and differs from the source. Retrofitting is
# additive-only — anything skipped is listed at the end so you can review and
# merge it by hand. A fresh (seed-mode) target is `git init`'d if it isn't a
# repo already; an existing target's git history is never touched.
#
# Idempotent: safe to re-run. Re-running after a partial retrofit only adds
# whatever's still missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$FACTORY_DIR/templates"
COMMON_DIR="$TEMPLATES_DIR/_common"

usage() {
  echo "Usage: cut-project.sh <template> <target-dir>"
  echo ""
  echo "Templates:"
  for t in "$TEMPLATES_DIR"/*/; do
    [[ -d "$t" ]] || continue
    name="$(basename "$t")"
    [[ "$name" == _* ]] && continue  # _common etc. — internal, not selectable
    echo "  $name"
  done
  exit 1
}

[[ $# -lt 2 ]] && usage

TEMPLATE="$1"
TARGET_ARG="$2"
TEMPLATE_DIR="$TEMPLATES_DIR/$TEMPLATE"

[[ -d "$TEMPLATE_DIR" ]] || { echo "Error: unknown template '$TEMPLATE'"; usage; }

mkdir -p "$TARGET_ARG"
TARGET_DIR="$(cd "$TARGET_ARG" && pwd)"

# Mode is only used for the summary/git-init decision below — the copy loop
# itself behaves identically either way (copy-if-absent, skip+report if
# present and different).
if [[ -z "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
  MODE="seed"
else
  MODE="retrofit"
fi

echo "Template: $TEMPLATE"
echo "Target:   $TARGET_DIR"
echo "Mode:     $MODE (auto-detected)"
echo ""

WROTE=()
SKIPPED=()
UNCHANGED=0

copy_tree() {
  local source_dir="$1"
  local src rel dest
  while IFS= read -r -d '' src; do
    rel="${src#"$source_dir"/}"
    dest="$TARGET_DIR/$rel"

    if [[ ! -e "$dest" ]]; then
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      WROTE+=("$rel")
    elif cmp -s "$src" "$dest"; then
      UNCHANGED=$((UNCHANGED + 1))
    else
      SKIPPED+=("$rel")
    fi
  done < <(find "$source_dir" -type f -print0)
}

[[ -d "$COMMON_DIR" ]] && copy_tree "$COMMON_DIR"
copy_tree "$TEMPLATE_DIR"

for f in "${WROTE[@]:-}"; do
  [[ -n "$f" ]] && echo "  wrote:     $f"
done
echo "  unchanged: $UNCHANGED file(s) already matched the template"
for f in "${SKIPPED[@]:-}"; do
  [[ -n "$f" ]] && echo "  SKIPPED (exists, differs — review manually): $f"
done

if [[ "$MODE" == "seed" ]] && [[ ! -d "$TARGET_DIR/.git" ]]; then
  git -C "$TARGET_DIR" init -q
  echo ""
  echo "  git init'd $TARGET_DIR"
fi

echo ""
echo "Done. ${#WROTE[@]} file(s) written, ${#SKIPPED[@]} skipped."
[[ ${#SKIPPED[@]} -gt 0 ]] && echo "Review the SKIPPED list above before assuming the retrofit is complete."
