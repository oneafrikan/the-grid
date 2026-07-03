#!/usr/bin/env bash
# worktree-teardown.sh — drops this worktree's isolated schema, removes .env.local.
#
# Recomputes the schema name from the CURRENT worktree path rather than
# trusting .env.local's contents, so a stale or hand-edited .env.local can
# never point teardown at the wrong (possibly still-in-use) schema.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WT_PATH="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)"

HASH="$(printf '%s' "$WT_PATH" | cksum | cut -d' ' -f1)"
DB_NAME="lampapp_${HASH}"

ENV_FILE="$PROJECT_ROOT/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$PROJECT_ROOT/.env.example"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

mysql -h "${DB_HOST:-127.0.0.1}" -P "${DB_PORT:-3306}" -u "${DB_USER:-root}" ${DB_PASS:+-p"$DB_PASS"} \
  -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"

rm -f "$PROJECT_ROOT/.env.local"
echo "Worktree teardown complete: dropped ${DB_NAME}, removed .env.local"
