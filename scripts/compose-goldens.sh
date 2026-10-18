#!/usr/bin/env bash
# compose-goldens.sh — golden-output conformance for compose.py (#23).
#
# Composes a small fixed fixture project (tests/fixtures/compose/fixture.yaml) under every
# compose target and byte-compares the result with the committed trees in
# tests/fixtures/compose/golden/<target>/. Changing compose.py, _core/, a template, models.yaml
# or openclaw/roster.json changes composed output, so it must come with `--update` in the same PR.
#
# Usage:
#   compose-goldens.sh [--check]   (default) fail if any target's output differs from its golden
#   compose-goldens.sh --update    regenerate every golden tree, then review the diff
#
# Environment:
#   GOLDEN_DIR   where the golden trees live (default tests/fixtures/compose/golden).
#                Tests point it at temp copies; everything else is pinned below.
#
# Exit codes: 0 ok (or --check skipped: no venv); 1 drift / failed update / --update without venv;
# 2 bad usage.
set -euo pipefail
export LC_ALL=C

# Always run from the repo root so the relative fixture paths below resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Pin everything that could make output machine-dependent, overriding whatever the caller (or
# their shell profile) exported:
#   - fixture roles shadow real role names (GRID_PRIVATE_ROLES_DIR beats the public roles/ tree
#     and the ~/.the-grid-private fallback)
#   - the neutral public identity, so no personal value or hostname lands in a tracked file
#   - the repo's models.yaml, not an ambient override
export GRID_PRIVATE_ROLES_DIR=tests/fixtures/compose/roles
export GRID_USER_CONFIG=agent-factory/user.public.yaml
export GRID_MODELS_FILE=agent-factory/models.yaml

PY=agent-factory/.venv/bin/python
FIXTURE=tests/fixtures/compose/fixture.yaml
GOLDEN_DIR="${GOLDEN_DIR:-tests/fixtures/compose/golden}"

# One golden tree per compose target. When compose.py gains a new --target, append it here and
# run --update; do not build a second golden harness. Targets must not share one --out: each
# emitter wipes and rewrites its own directory under it.
TARGETS=(claude-code openclaw paperclip openclaw-native portable codex opencode gemini-cli)

usage() {
  echo "usage: $0 [--check | --update]" >&2
  exit 2
}

mode=check
if [ "$#" -gt 1 ]; then usage; fi
if [ "$#" -eq 1 ]; then
  case "$1" in
    --check) mode=check ;;
    --update) mode=update ;;
    *) usage ;;
  esac
fi

# No venv, no PyYAML, no compose. A check skips loudly (same as gate.sh); an update that silently
# did nothing would be worse than a failure.
if [ ! -x "$PY" ]; then
  if [ "$mode" = check ]; then
    echo "venv absent, skipped"
    exit 0
  fi
  echo "venv absent: build agent-factory/.venv first (see agent-factory/README.md)" >&2
  exit 1
fi

failed=0
for t in "${TARGETS[@]}"; do
  if [ "$mode" = check ]; then
    # compose.py --check renders into a temp dir and reports missing / unexpected / stale
    # files relative to the golden tree. Keep going so every drifting target is reported.
    if ! "$PY" agent-factory/compose.py "$FIXTURE" --target "$t" --out "$GOLDEN_DIR/$t" --check; then
      failed=1
    fi
  else
    # Wipe first so a file removed from the output does not linger in the golden tree.
    rm -rf "${GOLDEN_DIR:?}/$t"
    if ! "$PY" agent-factory/compose.py "$FIXTURE" --target "$t" --out "$GOLDEN_DIR/$t"; then
      failed=1
    fi
  fi
done

if [ "$failed" -ne 0 ]; then
  if [ "$mode" = check ]; then
    echo "fix: bash scripts/compose-goldens.sh --update, then review the diff"
  fi
  exit 1
fi
