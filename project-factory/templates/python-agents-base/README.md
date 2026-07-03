# python-agents-base (template)

The default, generic scaffold for a Python AI **agent team** — plural, not a
single agent, because any real project ends up with more than one operational
agent (an orchestrator plus whatever does the actual work, at minimum). No
domain-specific tools or logic baked in. Seeded from `project-factory`.
Everything here is a **structural stub**: folders and one-line placeholder
files, no business logic. Fill in the pieces below as the project takes shape.

Independent from [`python-astro-content-agent`](../python-astro-content-agent/)
— not a base class it inherits from, just the same family of shape (that one
stays a single agent; it's genuinely single-purpose). Start here for any new
Python agent project that doesn't fit a more specific template; use
`python-astro-content-agent` (or add a new template) when the project has a
clear, narrower, single-agent purpose from day one.

## Shape

- `CLAUDE.md`, `CONTEXT.md`, `LEARNINGS.md`, `handoffs/`, `prompts/` — agent
  conventions and session-continuity scaffolding. The last four come from
  `_common` (shared across every `project-factory` template, not duplicated
  here) — see [`project-factory/README.md`](../../README.md).
- `src/agents/` — the team. `orchestrator/` decides what needs doing and
  delegates; `worker/` does the actual task work; `shared/` holds the
  execution loop, state, and memory both roles use. Add more role folders as
  the team grows — don't cram a second role into `orchestrator/` or
  `worker/`.
- `src/tools/` — tool definitions agents can call. Ships with illustrative
  stubs (`search.py`, `calculator.py`, `weather.py`) — delete what you don't
  need, add what you do.
- `src/models/` — LLM client + embeddings client wrappers.
- `src/prompts/` — system + agent prompt templates.
- `src/utils/` — helpers, logging, config parsing.
- `src/api/` — optional API layer to expose the team (FastAPI/Flask). Delete
  if this is CLI-only.
- `data/` — sample data, a knowledge base dir, and eval datasets.
- `tests/` — unit tests for the agents, tools, and API.
- `logs/` — runtime output (gitignored — `.gitkeep` only).
- `main.py` — entry point: CLI / API server / playground.
- `docker-compose.yml` — optional, for local services (DB, Redis, vector DB).
  Ships commented out; uncomment/edit only if the project actually needs one.

## Setup

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in your API keys — never commit .env itself
python main.py
```
