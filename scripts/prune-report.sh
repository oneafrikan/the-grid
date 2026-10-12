#!/usr/bin/env bash
# prune-report.sh - thin wrapper around scripts/usage/prune_report.py.
#
#   scripts/prune-report.sh [--window-days 90] [--rare 2] [--min-days 14]
#                           [--usage-dir DIR] [--out FILE] [--json]
#
# Read-only: prints a report on stdout (or --out) proposing what to drop from the
# baseline given the per-host usage files. --usage-dir defaults to
# ${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}/usage. GRID_DIR overrides the repo
# root (default: this script's own checkout).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_DIR="${GRID_DIR:-$(cd "$here/.." && pwd)}"
export GRID_DIR
# The report must change no file, so never write .pyc files into the checkout.
export PYTHONDONTWRITEBYTECODE=1

exec python3 "$here/usage/prune_report.py" "$@"
