# CLAUDE.md — python-agents-base

Conventions for any agent (Claude Code or otherwise) working autonomously in
this repo.

## Stack

Python 3.x, no domain-specific framework baked in — this is the generic
default scaffold. Don't introduce a web framework, ORM, or vector store
unless the project actually needs one (see the optional
`docker-compose.yml`); match whatever gets established in `src/` as real
code lands.

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
