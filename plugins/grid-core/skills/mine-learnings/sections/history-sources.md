   - `git log` — commit messages, favoring conventional-commit prefixes
     (`fix:`, `revert:`, `hotfix:`) and messages describing a workaround or
     root cause. Cap on large histories (e.g. since the last tag, or the
     last ~300 commits) and say so explicitly if capped — never silently
     truncate.
   - Repo docs: `README.md`, `CHANGELOG.md`, `docs/**/*.md`.
   - Repo logs/handoff dirs if present: `LOGS/`, `logs/`, `notes/`,
     `.claude/logs/` (check what actually exists — don't assume a name).
   - Existing `CLAUDE.md` content, so already-stated rules aren't re-derived
     as "new" learnings.
