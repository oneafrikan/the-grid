# CLAUDE.md — finance-agents-base

Conventions for any agent (Claude Code or otherwise) working autonomously in
this repo.

## Stack

Python 3.x, no domain-specific framework baked in — this is the generic
personal-finance default. Don't wire up broker/bank write access, ORM, or a
web framework unless the project actually needs one.

## Never hold write access to money — non-negotiable

No agent in this team ever executes anything that moves money. Read-only
data sources in (`src/tools/data_feed.py`), proposals out (`src/approval/`).
A human is the only thing that ever touches a broker, bank, or payment API.
If a task seems to require write access to a financial account, stop and
flag it — don't add credentials to `.env` to make it work.

## Guardrail is code, not prompts

`src/agents/guardrail/rules.py` enforces `POLICY.md`'s hard limits in pure
Python, with tests. Hard limits enforced by an LLM are hard limits enforced
by a probability distribution — don't move a limit check into a prompt
because it's easier to express there.

## Autonomous loop

This repo pairs with automation-factory's `issue-loop` pattern (see
`_common`'s `prompts/autonomous-coding-loop.template.md`) for maintaining
*this codebase* — its `{{VERIFY_CMD}}` should be:

```
pytest
```

This is separate from the watcher's own runtime heartbeat (cron/scheduler),
which is a deployment concern, not something `issue-loop` drives.

## Other context files

- `CONTEXT.md` — domain glossary and architecture decisions.
- `LEARNINGS.md` — gotchas mined from this project's own history.
- `handoffs/` — read the most recent dated file here before starting work in a
  new session; write one before ending a session that isn't finished.
- `POLICY.md` — the policy every agent's behavior is subordinate to. If
  `POLICY.md` doesn't exist yet, nothing here should be run for real.
