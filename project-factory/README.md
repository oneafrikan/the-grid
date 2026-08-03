# project-factory

The-grid's tier for **bootstrapping whole projects** — a sibling to
[`skills-factory/`](../skills-factory/) (builds skills), [`agent-factory/`](../agent-factory/)
(composes AI personas), and [`automation-factory/`](../automation-factory/) (cuts
automation patterns into an existing repo).

## The template → project model

A `project-factory` template is a project **seed**: a standalone, self-contained
directory tree with no logic of its own — it doesn't run, wire into the-grid, or
depend on being inside `~/.the-grid/`. `cut-project.sh` copies `templates/_common/`
(see below) followed by the chosen template into a target directory to either:

- **Seed** a brand-new project (target is empty or doesn't exist yet), or
- **Retrofit** an existing project (target already has files) — additive only,
  never overwrites a file that already exists and differs from the source.

Both modes run through the same script and the same rule: never silently clobber.
Anything the retrofit can't safely place is reported at the end for manual review.

## `_common` — session-continuity scaffolding every project gets

Every project cut from this factory is assumed to end up with a GitHub issue
backlog, an `issue-loop` instance grinding it, and multiple agent sessions
working it over time — so every project needs the same context-management and
handoff shape regardless of stack. That shape lives once, in
[`templates/_common/`](templates/_common/), not copy-pasted into each template:

- `CONTEXT.md` — domain glossary and architecture decisions.
- `LEARNINGS.md` — empty ledger; target for the `mine-learnings` skill.
- `SPECS.md` — the OpenSpec convention (see below).
- `handoffs/` — dated handoff+context docs between agent sessions.
- `prompts/autonomous-coding-loop.template.md` — the pre-flight/`{{VERIFY_CMD}}`
  gap `issue-loop` leaves to the project.

### `SPECS.md` — spec-driven development, on by default

Every cut project gets [`SPECS.md`](templates/_common/SPECS.md): the
[OpenSpec](https://openspec.dev) convention — specs in `openspec/`, proposals
reviewed before code, deltas folded back on archive. It's in `_common` rather
than per-template on purpose: **spec-driven development is the default, not a
per-project decision someone has to remember to make.** A retrofit gets it too,
so the convention reaches old repos on the same pass as everything else.

`SPECS.md` is documentation and agent instructions only — it does **not** run
`openspec init`. `cut-project.sh` copies files; the `openspec` CLI owns the
directory tree it creates, and back-filling specs is a judgement call that
belongs to the first real change, not to scaffolding. `SPECS.md` spells out both
the greenfield and brownfield adoption paths and tells agents in the repo to
stop and propose rather than skip to code.

The 12 `openspec-*` skills are wired on every machine via the-grid's baseline,
but they shell out to the CLI — `npm i -g @fission-ai/openspec@latest`.

`_common` isn't a template itself (leading underscore, filtered out of
`cut-project.sh`'s template listing) — it's cut in before every template, using
the same copy-if-absent/skip-if-differs rule. A template's own `CLAUDE.md`
stays template-specific (stack conventions genuinely differ) and isn't part of
`_common`.

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
| [`python-agents-base`](templates/python-agents-base/) | The default, generic Python AI agent-**team** scaffold (orchestrator + worker, not a single agent) — no domain-specific tools or logic. Start here for anything that doesn't fit a more specific template. |
| [`python-astro-content-agent`](templates/python-astro-content-agent/) | A single Python agent that reads markdown content and builds pages for an Astro site — genuinely single-purpose, stays singular. |
| [`lamp-agents-base`](templates/lamp-agents-base/) | Not a Python agent app — a PHP/MySQL/Apache project's agent-injection kit (`CLAUDE.md` + worktree DB/port isolation scripts, on top of `_common`), cut in retrofit mode against an existing LAMP repo most of the time. |
| [`finance-agents-base`](templates/finance-agents-base/) | A generic personal-finance agent-team scaffold: watcher/analyst/strategist/guardrail/scribe roles, a human approval gate, and a versioned policy-document convention — no thresholds or trading logic baked in. |

Naming convention: **`agents`, plural**, unless a template is genuinely
single-purpose (`python-astro-content-agent`) — any project with more than
one operational role should say so in its name and its `src/` shape.

Templates are **fully independent** — none inherit from each other or share
code; they fall into three families of shape (Python agent team, single
Python agent, LAMP agent-injection kit). Each is standalone and
self-contained, matching the model above.

## Anatomy of a template

```
templates/<name>/
  README.md          # what the seeded project is, tech choices, what to fill in
  src/agents/          # the team: one folder per role, plus shared/ for common execution/state/memory
  src/tools/           # tool definitions agents can call
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

Not every template needs every folder — `python-agents-base` ships the full
shape (including `api/` and an optional `docker-compose.yml`) since it's the
generic default; `python-astro-content-agent` deliberately drops both (it's a
build tool, not a served API, and needs no external services) and collapses
`src/agents/` back to a single `src/agent/` since it's genuinely one agent.
Include only what the template's project actually needs; don't copy the full
shape by default. See each template's own `README.md` for what it includes
and why.

The anatomy above is specific to the Python-agents family.
`lamp-agents-base` is a different family — no `src/agents/`, no `main.py` —
see its own `README.md`.

## Usage

```bash
bash scripts/cut-project.sh <template> <target-dir>
```

Mode (seed vs. retrofit) is auto-detected from whether `<target-dir>` already has
files — no flag to remember. Safe to re-run: re-running after a partial retrofit
only adds whatever's still missing.

## Roadmap

- **Placeholder-fill** (project name, description) — not yet implemented; v1
  ships structural stubs only.
- **Shared boilerplate within the Python-agents family** — `python-agents-base`,
  `python-astro-content-agent`, and `finance-agents-base` still duplicate
  `src/models/`, `src/prompts/`, `src/utils/`, test scaffolding between
  themselves. Deliberately accepted for now — independence over inheritance
  for stack-specific code — but worth revisiting if it gets painful to
  maintain. (Session-continuity scaffolding, the other kind of duplication, is
  already factored out into `_common`.)
- **More templates** — Node/TS stacks, multi-agent structures, and templates
  that pair with a specific `agent-factory` role are candidates once there's a
  concrete next use.
