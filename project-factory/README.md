# project-factory

The-grid's tier for **bootstrapping whole projects** — a sibling to
[`skills-factory/`](../skills-factory/) (builds skills), [`agent-factory/`](../agent-factory/)
(composes AI personas), and [`automation-factory/`](../automation-factory/) (cuts
automation patterns into an existing repo).

## The template → project model

A `project-factory` template is a project **seed**: a standalone, self-contained
directory tree with no logic of its own — it doesn't run, wire into the-grid, or
depend on being inside `~/.the-grid/`. `cut-project.sh` copies a template into a
target directory to either:

- **Seed** a brand-new project (target is empty or doesn't exist yet), or
- **Retrofit** an existing project (target already has files) — additive only,
  never overwrites a file that already exists and differs from the template.

Both modes run through the same script and the same rule: never silently clobber.
Anything the retrofit can't safely place is reported at the end for manual review.

This is deliberately narrow in scope. `cut-project.sh` only scaffolds a directory
tree. It does not decide what AI personas, skills, or automations the project
uses — that composition happens **after** seeding, as a separate step, using the
other three factories exactly as you would in any other repo (wire in a skill,
compose an `agent-factory` persona for the project's own agent identity, cut an
`automation-factory` pattern like `issue-loop` once the repo has a GitHub issue
backlog). A seeded project is a completely normal repo from that point on — it
has no ongoing dependency on `project-factory` or the-grid.

## Templates

| Template | What it scaffolds |
|----------|--------------------|
| [`python-astro-content-agent`](templates/python-astro-content-agent/) | A Python agent that reads markdown content and builds pages for an Astro site. |

## Anatomy of a template

```
templates/<name>/
  README.md          # what the seeded project is, tech choices, what to fill in
  src/agent/          # core agent loop, execution, state
  src/tools/           # tool definitions the agent can call
  src/models/          # LLM client and model config
  src/prompts/          # system/agent prompt templates
  src/utils/             # helpers, logging, config parsing
  tests/                  # unit/integration tests
  content/ (or data/)      # sample input content / fixtures
  logs/                     # .gitkeep only — runtime output, gitignored
  main.py                    # entry point
  requirements.txt
  .env.example
  .gitignore
```

Not every template needs every folder — `python-astro-content-agent` has no
`api/` (it's a build tool, not a served API) and no `docker-compose.yml` (no
external services). Include only what the template's project actually needs;
don't copy the full shape by default. See each template's own `README.md` for
what it includes and why.

## Usage

```bash
bash scripts/cut-project.sh <template> <target-dir>
```

Mode (seed vs. retrofit) is auto-detected from whether `<target-dir>` already has
files — no flag to remember. Safe to re-run: re-running after a partial retrofit
only adds whatever's still missing.

## Roadmap

- **Placeholder-fill** (project name, description) — not yet implemented; v1
  ships structural stubs only. Add if a second template makes the duplication
  worth automating.
- **More templates** — `python-astro-content-agent` is the first. Node/TS
  stacks, multi-agent structures, and templates that pair with a specific
  `agent-factory` role are candidates once there's a concrete second use.
