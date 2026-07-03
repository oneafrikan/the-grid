# CLAUDE.md — python-astro-content-agent

Conventions for any agent (Claude Code or otherwise) working autonomously in
this repo.

## Stack

Python 3.x, CLI/build-time tool — no served API, no external services. Reads
`content/`, writes into a sibling Astro project. Don't add `src/api/` or a
`docker-compose.yml`; this project deliberately has neither.

## Autonomous loop

This repo pairs with automation-factory's `issue-loop` pattern (see
`_common`'s `prompts/autonomous-coding-loop.template.md`) — its
`{{VERIFY_CMD}}` should be:

```
pytest
```

## Other context files

- `CONTEXT.md` — domain glossary and architecture decisions.
- `LEARNINGS.md` — gotchas mined from this project's own history.
- `handoffs/` — read the most recent dated file here before starting work in a
  new session; write one before ending a session that isn't finished.
