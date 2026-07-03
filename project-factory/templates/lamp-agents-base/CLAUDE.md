# CLAUDE.md — lamp-agents-base

Conventions for any agent (Claude Code or otherwise) working autonomously in
this repo.

## Stack

PHP 8.x, MySQL/MariaDB, Apache/Nginx, raw PDO with prepared statements,
Composer. No Node backend, no ORM (no Prisma), no framework unless one is
already present in the target repo. Frontend, if touched: vanilla JS,
Alpine.js, or Tailwind — no React/Vue/Next.js.

## Worktree isolation — non-negotiable

Never point this project at the shared/default database from inside a git
worktree. Before any DB read or write:

```bash
bash scripts/worktree-setup.sh
```

This allocates an isolated MySQL schema and `APP_PORT` for the current
worktree only, written to `.env.local` (gitignored). Parallel agents working
in other worktrees get their own schema and port automatically — this is what
prevents them from clashing. Read `DB_NAME` and `APP_PORT` from `.env.local`,
never hardcode them.

## Autonomous loop

This repo pairs with automation-factory's `issue-loop` pattern (see
`prompts/autonomous-coding-loop.template.md`) — its pre-flight step is
`bash scripts/worktree-setup.sh` above, and its `{{VERIFY_CMD}}` should be:

```
composer validate && php -l $(git diff --name-only -- '*.php') && vendor/bin/phpunit
```

## Other context files

- `CONTEXT.md` — domain glossary and architecture decisions.
- `LEARNINGS.md` — gotchas mined from this project's own history.
- `handoffs/` — read the most recent dated file here before starting work in a
  new session; write one before ending a session that isn't finished.
