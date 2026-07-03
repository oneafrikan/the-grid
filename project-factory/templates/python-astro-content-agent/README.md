# python-astro-content-agent (template)

A Python agent that reads markdown content and builds pages for an Astro site.
Seeded from `project-factory` — this file (and everything else in this tree) is
a **structural stub**: folders and one-line placeholder files, no business logic
yet. Fill in the pieces below as the project takes shape.

## Shape

- `src/agent/` — the agent loop: read content → decide what needs building →
  write Astro pages → report what changed.
- `src/tools/` — `read_markdown.py` (parse `content/` into structured docs),
  `build_astro_page.py` (write `.astro`/`.mdx` output), `deploy.py` (optional —
  Netlify/Vercel/GitHub Pages, stub only).
- `src/models/` — the LLM client wrapper (Claude, via the Anthropic SDK).
- `src/prompts/` — system + agent prompt templates.
- `src/utils/` — helpers, logging, config parsing.
- `content/` — sample markdown input to build from during development.
- `tests/` — unit tests for the agent loop and tools.
- `logs/` — runtime output (gitignored — `.gitkeep` only).
- `main.py` — CLI entry point: run the agent once, or watch `content/` and rebuild on change.

**Deliberately omitted** (not needed for a build-tool agent — add if the project
grows into one):
- `src/api/` — no served API; this is a CLI/build-time tool, not a web service.
- `docker-compose.yml` — no external services (no DB, no vector store).

## Composing this project (after seeding)

This template only scaffolds the tree. To make it a working agent:

1. Compose an `agent-factory` persona for this project's agent identity, if it
   should behave like one of the-grid's composed roles (optional — a bare
   `src/agent/agent.py` implementation is enough on its own).
2. Wire in relevant skills — `publishing-astro-websites` (from
   `repos/spillwave-astro` in the-grid) covers Astro Content Collections,
   Markdown/MDX, and deployment; pull its guidance into `src/prompts/` or
   reference it directly while implementing.
3. Once this repo has a GitHub issue backlog, `automation-factory`'s
   `issue-loop` pattern can grind through it unattended — see
   `automation-factory/patterns/issue-loop/README.md`.

## Where the actual Astro site lives

This repo is the **content-building agent**, not the Astro site itself. Point
`build_astro_page.py`'s output at a sibling Astro project (or generate one) —
decide this when implementing; not fixed by the template.

## Setup

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in your Anthropic API key
python main.py
```
