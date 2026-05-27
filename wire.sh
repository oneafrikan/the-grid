#!/usr/bin/env bash
# wire.sh — link skills from the-grid into ~/.claude/skills/
# Not yet implemented. Tests in tests/ define the expected behaviour.
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")" && pwd)}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"

echo "wire.sh: not yet implemented" >&2
exit 1
