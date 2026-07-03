#!/usr/bin/env bash
# db-migrate.sh — applies db/schema.sql against this worktree's isolated schema.
# Run scripts/worktree-setup.sh first so .env.local (DB_NAME) exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_LOCAL="$PROJECT_ROOT/.env.local"
[[ -f "$ENV_LOCAL" ]] || { echo "No .env.local — run scripts/worktree-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_LOCAL"; source "$PROJECT_ROOT/.env"; set +a

mysql -h "${DB_HOST:-127.0.0.1}" -P "${DB_PORT:-3306}" -u "${DB_USER:-root}" ${DB_PASS:+-p"$DB_PASS"} \
  "${DB_NAME}" < "$PROJECT_ROOT/db/schema.sql"

echo "Migrated schema.sql into ${DB_NAME}"
