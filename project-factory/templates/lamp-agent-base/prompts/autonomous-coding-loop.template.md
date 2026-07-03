# Autonomous coding loop — LAMP pre-flight addendum

This project pairs with automation-factory's `issue-loop` pattern for the
main autonomous loop (see `automation-factory/patterns/issue-loop/README.md`
in the-grid) — instantiate that pattern into this repo's `loop/` folder
rather than duplicating loop logic here. The addendum below is the one
LAMP-specific step the generic pattern doesn't know about: per-worktree DB
and port isolation.

PRE-FLIGHT (every iteration, before issue-loop's STEP 1)
Run: bash scripts/worktree-setup.sh
This allocates (or re-confirms) an isolated MySQL schema and `APP_PORT` for
THIS worktree only, written to `.env.local`. Parallel agents in other
worktrees never share a schema or port with this one.

VERIFY_CMD suggestion for issue-loop's {{VERIFY_CMD}} placeholder:
  composer validate && php -l $(git diff --name-only -- '*.php') && vendor/bin/phpunit

TEARDOWN (when a worktree is removed — not part of the per-issue loop)
Run: bash scripts/worktree-teardown.sh
