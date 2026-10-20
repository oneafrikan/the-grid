<!-- charter-trailhead -->
## Start here

- Session start: read `PURPOSE.md` and `MAP.md`.
- Before acting (editing, committing, opening a PR): read `GUARDRAILS.md`.
- Recording a claim or filing a signal: read `signals/README.md` (stages, warrant rule, file format).
- Before building a new capability or adding a dependency: read `RELATED.md` if it exists.
- Everything else: find it through `MAP.md` ("Read when" column); do not read what it does not point you to.
<!-- /charter-trailhead -->

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

This repo can opt in to automation-factory's `issue-loop` pattern (off by default; see
`loop/ENABLE.md`). Set `VERIFY_CMD` in `loop/loop.conf`, seeded from
`loop/loop.conf.seed`, to:

```
pytest
```

## Other context files

- `CONTEXT.md` — domain glossary and architecture decisions.
- `LEARNINGS.md` — gotchas mined from this project's own history.
- `handoffs/` — read the most recent dated file here before starting work in a
  new session; write one before ending a session that isn't finished.
