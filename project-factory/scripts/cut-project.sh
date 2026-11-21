#!/usr/bin/env bash
# cut-project.sh — seed a new project or retrofit an existing one from a
# project-factory template.
#
# Usage:
#   cut-project.sh [flags] <template> <target-dir>
#   cut-project.sh --generic [flags] <target-dir>
#
#   --with-related   also copy project-factory/related.md to <target>/RELATED.md
#                    (opt-in neighbour list; same never-overwrite rule). The flag may
#                    appear anywhere among the arguments.
#   --generic        no stack template and none of _common: lay down only the generic core
#                    set (templates/_core/ plus PURPOSE.md, GUARDRAILS.md and scripts/map.py
#                    from _common) and generate MAP.md. Takes just <target-dir>.
#   --with a,b       also lay down the named optional files (design, agents, logs, humans,
#                    context, calculations, assumptions, learnings, memory). Works with or
#                    without --generic.
#   --all-optional   shorthand for --with naming all of them.
#   --grid           with --generic: also lay down the grid-coupled _common files (the
#                    bootstrap layer, see GRID_FILES below). Without --generic it is a
#                    no-op: a stack-template cut already carries all of _common.
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
# Generic mode (--generic): see the flag above. Optional files live in templates/_optional/
# (CONTEXT.md is the exception: it is already in _common, so it is read from there).
#
# LEARNINGS.md exists twice: a grid-free one in _optional/ (--with learnings) and the grid
# one in _common/ (--grid, or any stack cut). RULE, for --generic cuts: the grid one
# supersedes the generic one, in either order, with no SKIPPED noise and no loss. --grid
# overwrites IN PLACE (no delete) a target LEARNINGS.md that is a regular file, not a symlink,
# and byte-identical to the unedited generic template, and prints "replaced: LEARNINGS.md ...";
# --with learnings counts the file as unchanged when it already equals the grid one. Anything
# else (edited file, symlink, directory) is never touched and is SKIPPED as usual. A stack-
# template cut copies _common first, so over an existing unedited generic LEARNINGS.md it
# reports SKIPPED: the rule does not apply there.
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
CORE_DIR="$TEMPLATES_DIR/_core"          # generic core set, used only by --generic
OPTIONAL_DIR="$TEMPLATES_DIR/_optional"  # files laid down only when asked for
OPTIONAL_ALL="design agents logs humans context calculations assumptions learnings memory"
# Grid-coupled _common files, laid down by --grid (only with --generic). Named here, not
# discovered, so adding a file to _common never changes a --grid cut by accident. A directory
# entry is copied file by file. loop/ is the opt-in issue-loop seed, as in a stack cut.
GRID_FILES="BEHAVIOUR.md LEARNINGS.md SPECS.md AGENTS-SETUP.md .grid signals knowledge scripts/knowledge.py handoffs .claude/skills/project-review .githooks/pre-commit loop"

usage() {
  echo "Usage: cut-project.sh [flags] <template> <target-dir>"
  echo "       cut-project.sh --generic [flags] <target-dir>"
  echo ""
  echo "  --with-related   also write RELATED.md (opt-in list of neighbouring projects)"
  echo "  --generic        only the generic core docs; no stack template, no _common extras"
  echo "  --with a,b       also write optional files: $OPTIONAL_ALL"
  echo "  --all-optional   write every optional file"
  echo "  --grid           with --generic: also the grid-coupled files (signals, knowledge, SPECS, .grid, ...)"
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

# Pull the flags out of the argument list first, so the positional checks below
# (and $1/$2) behave exactly as before wherever a flag was written.
WITH_RELATED=0
GENERIC=0
GRID=0
OPTIONAL_REQ=""   # space-separated optional file names asked for
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-related) WITH_RELATED=1 ;;
    --generic) GENERIC=1 ;;
    --grid) GRID=1 ;;
    --all-optional) OPTIONAL_REQ="$OPTIONAL_REQ $OPTIONAL_ALL" ;;
    --with)
      [[ $# -ge 2 ]] || usage
      OPTIONAL_REQ="$OPTIONAL_REQ ${2//,/ }"
      shift
      ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done
# ${arr[@]+...}: an empty array is an unbound variable under `set -u` on bash 3.2.
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

# Reject an unknown optional name before anything is written.
for n in $OPTIONAL_REQ; do
  case " $OPTIONAL_ALL " in
    *" $n "*) ;;
    *) echo "Error: unknown optional file '$n' (choose from: $OPTIONAL_ALL)"; exit 1 ;;
  esac
done

if [[ "$GENERIC" == 1 ]]; then
  # No stack template: the only positional is the target.
  [[ $# -eq 1 ]] || usage
  TEMPLATE="(generic core set)"
  TARGET_ARG="$1"
else
  [[ $# -lt 2 ]] && usage
  TEMPLATE="$1"
  TARGET_ARG="$2"
  TEMPLATE_DIR="$TEMPLATES_DIR/$TEMPLATE"
  [[ -d "$TEMPLATE_DIR" ]] || { echo "Error: unknown template '$TEMPLATE'"; usage; }
fi

mkdir -p "$TARGET_ARG"
TARGET_DIR="$(cd "$TARGET_ARG" && pwd)"

# Mode is only used for the summary/git-init decision below — the copy loop
# itself behaves identically either way (copy-if-absent, skip+report if
# present and different).
# Finder junk (.DS_Store, AppleDouble ._* files) does not make a folder "non-empty":
# a Finder-made new folder holding only that is still a seed (git init, hooksPath).
if [[ -z "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 ! -name .DS_Store ! -name '._*' -print 2>/dev/null | head -n 1)" ]]; then
  MODE="seed"
else
  MODE="retrofit"
fi

echo "Template: $TEMPLATE"
echo "Target:   $TARGET_DIR"
echo "Mode:     $MODE (auto-detected)"
echo ""

WROTE=()
REPLACED=()   # unedited generic LEARNINGS.md overwritten in place by the grid ledger
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
  # Skip Finder junk so it is never copied from a template tree into a project.
  done < <(find "$source_dir" -type f ! -name .DS_Store ! -name '._*' -print0)
}

# MAP.md is generated, not copied (project-factory copies files only), and only if it was
# absent before this cut: an existing map is the project's, whatever it holds.
MAP_EXISTED=0
if [[ -e "$TARGET_DIR/MAP.md" ]]; then MAP_EXISTED=1; fi

if [[ "$GENERIC" == 1 ]]; then
  # Generic core set only. PURPOSE.md, GUARDRAILS.md and scripts/map.py are shared with
  # _common, so they are copied from there by name rather than duplicated in _core/.
  copy_tree "$CORE_DIR"
  for rel in PURPOSE.md GUARDRAILS.md scripts/map.py; do
    copy_one "$COMMON_DIR/$rel" "$rel"
  done
  # Grid layer, only when asked. Same copy rule; directories keep their relative path.
  if [[ "$GRID" == 1 ]]; then
    # LEARNINGS.md rule (see header): an unedited generic LEARNINGS.md is overwritten in
    # place by the grid one. No deletion: only a regular, non-symlink file that is
    # byte-identical to the generic template qualifies, so nothing of the operator's is lost.
    LEARN_REPLACED=0
    if [[ -f "$TARGET_DIR/LEARNINGS.md" && ! -L "$TARGET_DIR/LEARNINGS.md" ]] \
       && cmp -s "$OPTIONAL_DIR/LEARNINGS.md" "$TARGET_DIR/LEARNINGS.md"; then
      cp "$COMMON_DIR/LEARNINGS.md" "$TARGET_DIR/LEARNINGS.md"
      REPLACED+=("LEARNINGS.md (unedited generic template -> grid ledger)")
      LEARN_REPLACED=1
    fi
    for rel in $GRID_FILES; do
      # Already handled above; copy_one would count it as unchanged a second time.
      [[ "$rel" == "LEARNINGS.md" && "$LEARN_REPLACED" == 1 ]] && continue
      if [[ -d "$COMMON_DIR/$rel" ]]; then
        while IFS= read -r -d '' src; do
          copy_one "$src" "${src#"$COMMON_DIR"/}"
        done < <(find "$COMMON_DIR/$rel" -type f ! -name .DS_Store ! -name '._*' -print0)
      else
        copy_one "$COMMON_DIR/$rel" "$rel"
      fi
    done
  fi
else
  [[ -d "$COMMON_DIR" ]] && copy_tree "$COMMON_DIR"
  copy_tree "$TEMPLATE_DIR"
  # --grid adds nothing here: _common above is already the whole grid layer.
  if [[ "$GRID" == 1 ]]; then
    echo "note: --grid has no effect without --generic (a stack-template cut already includes it)"
    echo ""
  fi
fi

# Optional files, only when asked. Same copy rule; a name given twice is copied once.
SEEN=" "
for n in $OPTIONAL_REQ; do
  case "$SEEN" in *" $n "*) continue ;; esac
  SEEN="$SEEN$n "
  file="$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]').md"
  # Already reported SKIPPED by an earlier pass (_common or --grid): do not report it twice.
  already=0
  for sk in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    [[ "$sk" == "$file" ]] && already=1
  done
  [[ "$already" == 1 ]] && continue
  src="$OPTIONAL_DIR/$file"
  [[ -f "$src" ]] || src="$COMMON_DIR/$file"   # CONTEXT.md already lives in _common
  # LEARNINGS.md rule (see header): the grid one in _common wins, so a target that already
  # holds it is unchanged, not "differs".
  if [[ "$file" == "LEARNINGS.md" ]] && [[ -f "$TARGET_DIR/$file" ]] \
     && cmp -s "$COMMON_DIR/$file" "$TARGET_DIR/$file"; then
    UNCHANGED=$((UNCHANGED + 1))
    continue
  fi
  copy_one "$src" "$file"
done

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
  elif python3 "$TARGET_DIR/scripts/map.py" --include-untracked --root "$TARGET_DIR" >/dev/null 2>&1; then
    WROTE+=("MAP.md")
  else
    MAP_NOTE="warning: scripts/map.py failed, MAP.md not generated; run: python3 scripts/map.py"
  fi
elif [[ "$MAP_EXISTED" == 0 ]] && [[ -f "$TARGET_DIR/scripts/map.py" ]]; then
  # The project has its own, different map.py (it sits in SKIPPED): not ours to run.
  MAP_NOTE="note: scripts/map.py differs from the seeded copy, MAP.md not generated; run: python3 scripts/map.py"
fi

for f in "${WROTE[@]:-}"; do
  [[ -n "$f" ]] && echo "  wrote:     $f"
done
for f in ${REPLACED[@]+"${REPLACED[@]}"}; do
  echo "  replaced: $f"
done
echo "  unchanged: $UNCHANGED file(s) already matched the template"
for f in "${SKIPPED[@]:-}"; do
  [[ -n "$f" ]] && echo "  SKIPPED (exists, differs — review manually): $f"
done

if [[ "$MODE" == "seed" ]] && [[ ! -d "$TARGET_DIR/.git" ]]; then
  git -C "$TARGET_DIR" init -q
  echo ""
  echo "  git init'd $TARGET_DIR"
  # A repo we just created is ours to configure: arm the seeded pre-commit shim
  # (a bare generic cut seeds no shim, so there is nothing to arm; --grid seeds one).
  if [[ -f "$TARGET_DIR/.githooks/pre-commit" ]]; then
    git -C "$TARGET_DIR" config core.hooksPath .githooks
    echo "  set core.hooksPath=.githooks (the pre-commit shim checks MAP.md)"
  fi
fi

echo ""
echo "Done. $((${#WROTE[@]} + ${#REPLACED[@]})) file(s) written, ${#SKIPPED[@]} skipped."
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
   && cmp -s "$COMMON_DIR/.githooks/pre-commit" "$TARGET_DIR/.githooks/pre-commit" \
   && [[ "$(git -C "$TARGET_DIR" config --get core.hooksPath 2>/dev/null || true)" != ".githooks" ]]; then
  echo ""
  echo "To arm the pre-commit MAP.md check, run in the target:"
  echo "  git config core.hooksPath .githooks"
fi

# CLAUDE.md is never edited here (it may hold the project's own conventions, and the copy
# rule cannot merge text). If the target's lacks the trailhead block, print it to paste.
# Generic mode seeds its own CLAUDE.md and the trailhead block is not part of it: skip.
if [[ "$GENERIC" == 0 ]] && [[ -f "$TARGET_DIR/CLAUDE.md" ]] && ! grep -qF '<!-- charter-trailhead -->' "$TARGET_DIR/CLAUDE.md"; then
  echo ""
  echo "CLAUDE.md has no trailhead block (cut-project.sh never edits it); paste at the top of CLAUDE.md:"
  echo ""
  cat "$FACTORY_DIR/trailhead.md"
fi
