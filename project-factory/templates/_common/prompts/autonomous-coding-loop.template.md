# Autonomous coding loop

Every project cut from `project-factory` is assumed to grind its own GitHub
issue backlog unattended. Once this repo has one, instantiate
automation-factory's `issue-loop` pattern into `loop/` (see
`automation-factory/patterns/issue-loop/README.md` in the-grid) rather than
duplicating loop logic here — that pattern owns STEP 1 (find work) through
STEP 5 (handoff) generically, for any stack.

This file is only the two things `issue-loop` deliberately leaves to the
project cutting it:

PRE-FLIGHT (project-specific, run before issue-loop's STEP 1 if this repo has one)
See this repo's own `CLAUDE.md` / `scripts/` for any setup a fresh iteration
needs (e.g. worktree isolation) — not every stack needs one, so there's
nothing generic to fill in here.

VERIFY_CMD for issue-loop's `{{VERIFY_CMD}}` placeholder
Fill in this project's actual check-before-commit command (test suite,
linter, `composer validate && phpunit`, etc.) — stack-specific, so it's not
prescribed here either.
