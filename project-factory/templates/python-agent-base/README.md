# python-agent-base (template)

The default, generic scaffold for a Python AI agent — no domain-specific tools
or logic baked in. Seeded from `project-factory`. Everything here is a
**structural stub**: folders and one-line placeholder files, no business logic.
Fill in the pieces below as the project takes shape.

Independent from [`python-astro-content-agent`](../python-astro-content-agent/)
— not a base class it inherits from, just the same family of shape. Start here
for any new Python agent that doesn't fit a more specific template; use
`python-astro-content-agent` (or add a new template) when the project has a
clear, narrower purpose from day one.

## Shape

- `src/agent/` — core agent loop, execution, state, memory.
- `src/tools/` — tool definitions the agent can call. Ships with illustrative
  stubs (`search.py`, `calculator.py`, `weather.py`) — delete what you don't
  need, add what you do.
- `src/models/` — LLM client + embeddings client wrappers.
- `src/prompts/` — system + agent prompt templates.
- `src/utils/` — helpers, logging, config parsing.
- `src/api/` — optional API layer to expose the agent (FastAPI/Flask). Delete
  if this agent is CLI-only.
- `data/` — sample data, a knowledge base dir, and eval datasets.
- `tests/` — unit tests for the agent, tools, and API.
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
