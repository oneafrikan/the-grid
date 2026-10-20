#!/usr/bin/env bash
# cut-project.sh — seed a new project or retrofit an existing one from a
# project-factory template.
#
# Usage:
#   cut-project.sh [--with-related] <template> <target-dir>
#
#   --with-related   also copy project-factory/related.md to <target>/RELATED.md
#                    (opt-in neighbour list; same never-overwrite rule). The flag may
#                    appear anywhere among the arguments.
#
# Mode is auto-detected from the target directory, not passed as a flag:
#   - target doesn't exist, or exists and is empty  -> SEED
#   - target exists with files                       -> RETROFIT
#
# Every cut lays down templates/_common/ (session-continuity scaffolding every
# project needs: CONTEXT.md, LEARNINGS.md, handoffs/, and the opt-in issue-loop
# seed loop/loop.conf.seed + loop/ENABLE.md) followed by templates/<template>/
# (the stack-specific pieces). Both passes run the exact same copy rule: NEVER overwrite a file that already
# exists in the target and differs from the source. Retrofitting is
# additive-only — anything skipped is listed at the end so you can review and
# merge it by hand. A fresh (seed-mode) target is `git init`'d if it isn't a
# repo already; an existing target's git history is never touched.
#
# Charter files (change `charter-files`): _common also carries PURPOSE.md, GUARDRAILS.md,
# BEHAVIOUR.md, signals/, knowledge/, scripts/map.py and a .githooks/pre-commit shim.
# MAP.md is NOT a template file (it would be wrong the moment any file differs): this
# script generates it after the copy by running the target's own scripts/map.py, and only
# when MAP.md was absent before the cut. CLAUDE.md is never edited; a retrofit whose
# CLAUDE.md lacks the trailhead marker gets the block printed to paste. A seed sets
# core.hooksPath=.githooks; a retrofit never touches git config and prints the command.
#
# Idempotent: safe to re-run. Re-running after a partial retrofit only adds
# whatever's still missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$FACTORY_DIR/templates"
COMMON_DIR="$TEMPLATES_DIR/_common"

usage() {
  echo "Usage: cut-project.sh [--with-related] <template> <target-dir>"
  echo ""
  echo "  --with-related   also write RELATED.md (opt-in list of neighbouring projects)"
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

# Pull --with-related out of the argument list first, so the positional checks below
# (and $1/$2) behave exactly as before wherever the flag was written.
WITH_RELATED=0
POSITIONAL=()
for arg in "$@"; do
  if [[ "$arg" == "--with-related" ]]; then
    WITH_RELATED=1
  else
    POSITIONAL+=("$arg")
  fi
done
# ${arr[@]+...}: an empty array is an unbound variable under `set -u` on bash 3.2.
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

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

# copy_one <src file> <path relative to the target> — the one copy rule: write if absent,
# count if identical, SKIP (and report) if present and different. Never overwrites.
copy_one() {
  local src="$1" rel="$2"
  local dest="$TARGET_DIR/$rel"

  if [[ ! -e "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    WROTE+=("$rel")
  elif cmp -s "$src" "$dest"; then
    UNCHANGED=$((UNCHANGED + 1))
  else
    SKIPPED+=("$rel")
  fi
}

copy_tree() {
  local source_dir="$1"
  local src
  while IFS= read -r -d '' src; do
    copy_one "$src" "${src#"$source_dir"/}"
  done < <(find "$source_dir" -type f -print0)
}

# MAP.md is generated, not copied (project-factory copies files only), and only if it was
# absent before this cut: an existing map is the project's, whatever it holds.
MAP_EXISTED=0
if [[ -e "$TARGET_DIR/MAP.md" ]]; then MAP_EXISTED=1; fi

[[ -d "$COMMON_DIR" ]] && copy_tree "$COMMON_DIR"
copy_tree "$TEMPLATE_DIR"

# Opt-in neighbour list. It lives outside templates/ so no default cut can copy it.
if [[ "$WITH_RELATED" == 1 ]]; then
  copy_one "$FACTORY_DIR/related.md" "RELATED.md"
fi

# Generate MAP.md with the target's own scripts/map.py, but only when that file is the
# seeded copy (written or unchanged this run): a project's different map.py is not ours to
# run. A failure or a missing python3 is a warning with the fix, never a failed cut.
MAP_NOTE=""
if [[ "$MAP_EXISTED" == 0 ]] && [[ -f "$COMMON_DIR/scripts/map.py" ]] \
   && [[ -f "$TARGET_DIR/scripts/map.py" ]] && cmp -s "$COMMON_DIR/scripts/map.py" "$TARGET_DIR/scripts/map.py"; then
  if ! command -v python3 >/dev/null 2>&1; then
    MAP_NOTE="warning: python3 not found, MAP.md not generated; run: python3 scripts/map.py"
  elif python3 "$TARGET_DIR/scripts/map.py" --root "$TARGET_DIR" >/dev/null 2>&1; then
    WROTE+=("MAP.md")
  else
    MAP_NOTE="warning: scripts/map.py failed, MAP.md not generated; run: python3 scripts/map.py"
  fi
fi

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
  # A repo we just created is ours to configure: arm the seeded pre-commit shim.
  git -C "$TARGET_DIR" config core.hooksPath .githooks
  echo "  set core.hooksPath=.githooks (the pre-commit shim checks MAP.md)"
fi

echo ""
echo "Done. ${#WROTE[@]} file(s) written, ${#SKIPPED[@]} skipped."
# `if`, not `[[ ]] && echo`: the && form made a clean run (nothing skipped) exit 1.
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "Review the SKIPPED list above before assuming the retrofit is complete."
fi

# MAP.md could not be generated (no python3, or map.py failed): say how to do it by hand.
if [[ -n "$MAP_NOTE" ]]; then
  echo ""
  echo "$MAP_NOTE"
fi

# A retrofit never changes git config. If the shim is there but not armed, print the command.
if [[ "$MODE" == "retrofit" ]] && [[ -f "$TARGET_DIR/.githooks/pre-commit" ]] \
   && [[ "$(git -C "$TARGET_DIR" config --get core.hooksPath 2>/dev/null || true)" != ".githooks" ]]; then
  echo ""
  echo "To arm the pre-commit MAP.md check, run in the target:"
  echo "  git config core.hooksPath .githooks"
fi

# CLAUDE.md is never edited here (it may hold the project's own conventions, and the copy
# rule cannot merge text). If the target's lacks the trailhead block, print it to paste.
if [[ -f "$TARGET_DIR/CLAUDE.md" ]] && ! grep -qF '<!-- charter-trailhead -->' "$TARGET_DIR/CLAUDE.md"; then
  echo ""
  echo "CLAUDE.md has no trailhead block (cut-project.sh never edits it); paste at the top of CLAUDE.md:"
  echo ""
  cat "$FACTORY_DIR/trailhead.md"
fi
