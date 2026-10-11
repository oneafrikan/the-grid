#!/usr/bin/env bash
# build-personas.sh — regenerate dist/personas/<role>.md (portable single-file personas).
#
# Each persona is a plain-Markdown rendering of one role's lean body, for pasting into a
# chat-UI Project (no harness, no frontmatter). It is produced by
# `compose.py --target portable` for every public compose config under
# agent-factory/examples/, then collected into one flat dir.
#
# Usage:
#   build-personas.sh           rebuild dist/personas/ (writes files, removes stale ones)
#   build-personas.sh --check   build into a temp dir and diff against dist/personas/;
#                               write nothing, exit 1 if the committed files are stale
#
# Rules this script enforces:
#   - GRID_PRIVATE_ROLES_DIR is set EMPTY, so a private role on this machine (or under the
#     ~/.the-grid-private fallback) can never reach the committed export.
#   - Configs are walked in C-locale order and later configs overwrite earlier ones, so a
#     role name appearing in two configs resolves the same way on every machine.
#
# Exit codes: 0 ok (or skipped: no venv); 1 stale (--check) or a compose failure; 2 bad usage.
set -euo pipefail
export LC_ALL=C

# Always run from the repo root so the relative paths below resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY=agent-factory/.venv/bin/python
OUT=dist/personas

mode=build
if [ "$#" -gt 1 ]; then echo "usage: $0 [--check]" >&2; exit 2; fi
if [ "$#" -eq 1 ]; then
  case "$1" in
    --check) mode=check ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
  esac
fi

# No venv, no PyYAML, no compose. Skip loudly rather than fail (same as the other gate checks).
if [ ! -x "$PY" ]; then
  echo "agent-factory/.venv absent, skipped (see agent-factory/README.md)"
  exit 0
fi

# Never leave the temp tree behind, even on failure.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Pin the private roles dir to empty: private roles must never be exported.
export GRID_PRIVATE_ROLES_DIR=

# Compose every public config's portable target, then flatten into $tmp/personas.
# Glob expansion order is locale-dependent, so LC_ALL=C above pins it.
mkdir -p "$tmp/personas" "$tmp/composed"
for cfg in agent-factory/examples/*.yaml; do
  "$PY" agent-factory/compose.py "$cfg" --target portable --out "$tmp/composed" >/dev/null
  # Later configs overwrite earlier ones on a name clash (cp without -n).
  for f in "$tmp"/composed/*/_portable/*.md; do
    [ -e "$f" ] || continue
    cp "$f" "$tmp/personas/"
  done
  # Wipe between configs so the next config's glob only sees its own project.
  rm -rf "$tmp/composed"
  mkdir -p "$tmp/composed"
done

if [ "$mode" = check ]; then
  # A missing dist/personas is stale too, not a diff error.
  if [ ! -d "$OUT" ] || ! diff -r "$tmp/personas" "$OUT" >/dev/null; then
    echo "STALE: $OUT does not match the roles" >&2
    diff -r "$tmp/personas" "$OUT" >&2 || true
    echo "  fix: bash scripts/build-personas.sh, then commit dist/personas" >&2
    exit 1
  fi
  echo "up to date: $OUT"
  exit 0
fi

# Sync: remove personas no longer produced, then copy the fresh set. Only *.md is touched.
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -type f -name '*.md' -delete
cp "$tmp"/personas/*.md "$OUT/"
echo "built $(find "$OUT" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') personas -> $OUT"
