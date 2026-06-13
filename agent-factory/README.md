# agent-factory

Composes AI dev teams from three orthogonal inputs:

```
role  ×  stack  ×  skills   ──compose.py──▶   a ready-to-run agent team
```

- **role** — *who* the agent is (Tech Lead, Backend Dev, QA…). Stack-agnostic
  identity + operating manual. Lives in `roles/<role>/`.
- **stack** — *what* it builds on (LAMP, modern-frontend, data-engineering…).
  An overlay injected into a role's SKILL.md. Lives in `stacks/<stack>/`.
- **skills** — bolt-on capabilities pulled from the ecosystem (Paperclip, php,
  mysql…). Lives in `skills/<skill>/`.

A **compose config** (see `docs/architect-agent-composition.yaml` for an example)
names a project and lists agents, each as `role + stacks[] + skills[] + model`.
`compose.py` reads it and emits one folder per agent under `projects/<name>/`,
each containing the rendered `SOUL.md`, `SKILL.md`, `MEMORY.md`, plus a top-level
`agents.yaml` wiring them together.

> Sibling `skills-factory/` is a **separate** concern (skills are built there via a
> Karpathy loop in another repo, then dropped into `skills/`). This factory only
> *composes* teams from existing parts.

## Layout

```
agent-factory/
├── _core/                  shared base templates every role inherits
│   ├── SOUL_base.md        universal personality scaffolding
│   ├── MEMORY_base.md      universal memory structure
│   └── agents_base.yaml    universal runtime config template
├── roles/<role>/           role source (stack-agnostic)
│   ├── role.yaml           metadata: default model, base skills, summary
│   ├── SOUL.md             identity template
│   ├── SKILL.md            operating manual (with stack injection points)
│   └── MEMORY.md           memory seed template
├── stacks/<stack>/         stack overlay injected into a role's SKILL.md
│   └── stack.yaml          + fragment files
├── skills/<skill>/         local skill library (built elsewhere, dropped here)
├── compose.py              the factory engine (STUB — see file)
├── factory.schema.yaml     what a valid compose config looks like
└── projects/<name>/        OUTPUT — one folder per composed team
```

## Running it

`compose.py` needs PyYAML. Install it once into a project venv:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Then compose a team from a config:

```bash
.venv/bin/python compose.py examples/tech-lead.yaml            # writes projects/demo-tech-lead/
.venv/bin/python compose.py examples/tech-lead.yaml --dry-run  # report only, writes nothing
```

Output is regenerable and idempotent: re-running with an unchanged config
produces byte-identical files (the project dir is wiped and rewritten each run).
`projects/` output is gitignored — the compose config is the tracked artefact.

### How merging works

`SOUL.md` and `MEMORY.md` are merged section-by-section with the `_core` base:
shared level-2 (`## `) headings unify under one heading (base guidance first,
then the role's seed); sections unique to either side are kept in order. This is
why role templates reuse the base headings. `SKILL.md` is the role's operating
manual with any stack overlay(s) appended.

## Status

**Engine works; content is in progress.** `compose.py` renders, merges, and
writes a team idempotently, validated end-to-end with the Tech Lead role
(`examples/tech-lead.yaml`). Remaining work: port the other roles (only
`role.yaml` metadata exists so far), flesh the stack overlays (`stacks/*` are
`stack.yaml` stubs with empty `fragments`), and add keyed inline stack injection
at the `<!-- STACK: ... -->` markers (today overlays append as a trailing
section). See repo-root `TODO.md`.

## Runtime assumptions (decided 2026-06-13)

- Target surface is **Claude Code + ACP** (swappable coding CLI), not Claude Code
  alone. SKILL.md content should stay LCD (lowest common denominator) where possible.
- Memory starts as flat **MEMORY.md** / signals files; a queryable DB (gbrain)
  replaces it later. Don't hard-bake gbrain assumptions yet.
- Handoff supports **both** `sessions_spawn()` (live) and PR + webhook (async).
- Stacks are overlays. LAMP is one overlay among several, not the spine.
