# lamp-agent-base (template)

A PHP/MySQL/Apache (LAMP) project scaffold with the pieces needed to run an
autonomous coding agent against it — not a full LAMP app framework. Seeded
from `project-factory`, most often in **retrofit mode** against an existing
LAMP repo (`cut-project.sh` never overwrites a file that already exists and
differs). Structural stubs only: no business logic — the value here is the
agent-injection kit, not a PHP app. Session-continuity scaffolding
(`CONTEXT.md`, `LEARNINGS.md`, `handoffs/`, the loop pairing prompt) comes
from `_common` — see [`project-factory/README.md`](../../README.md) — not
from this template; this README covers only what's LAMP-specific.

## Shape

- `CLAUDE.md` — stack conventions the agent must follow (PHP/PDO/Composer, no
  Node backend), the worktree-isolation rule, and this repo's `{{VERIFY_CMD}}`
  for the `_common` loop prompt.
- `scripts/worktree-setup.sh` / `worktree-teardown.sh` / `db-migrate.sh` —
  working, idempotent scripts. Each git worktree gets its own MySQL schema and
  port, derived deterministically from the worktree's path, so parallel
  autonomous agents never clash on a shared DB or port.
- `db/schema.sql`, `public/index.php`, `composer.json`, `src/` — minimal LAMP
  app stubs, only used when seeding a brand-new project; skipped in retrofit
  mode if the target already has its own.
- `logs/` — runtime output (gitignored, `.gitkeep` only).
- `tests/` — empty, for the target project's own test suite.

**Deliberately omitted:** no Python `src/agent/` layer like the other two
templates — the "agent" here is Claude Code operating directly on the PHP
codebase via `CLAUDE.md` + the isolation scripts, not a separate service.

## Composing this project (after cutting)

1. Run `scripts/worktree-setup.sh` once per worktree before doing any DB work.
2. Once this repo has a GitHub issue backlog, instantiate
   `automation-factory`'s `issue-loop` pattern into `loop/`, and fill in
   `_common`'s `prompts/autonomous-coding-loop.template.md` with the
   pre-flight step and `{{VERIFY_CMD}}` from this template's `CLAUDE.md`.
3. Optional: compose `agent-factory`'s `lamp` stack overlay
   (`agent-factory/stacks/lamp/stack.yaml`) if this project also uses a
   composed persona (e.g. `/backend-dev`), rather than duplicating stack
   conventions between `CLAUDE.md` and the overlay by hand.

## Setup

```bash
cp .env.example .env          # fill in shared DB_HOST/DB_USER/DB_PASS
bash scripts/worktree-setup.sh # allocates this worktree's DB_NAME + APP_PORT
bash scripts/db-migrate.sh     # applies db/schema.sql
composer install
php -S 127.0.0.1:$APP_PORT -t public
```
