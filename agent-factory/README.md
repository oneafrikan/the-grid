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

## Status

**Scaffold stage.** Structure + stubs are in place; `compose.py` is not yet
functional. Build order: scaffold → port Tech Lead role → flesh compose.py →
add stack overlays → iterate. See repo-root `TODO.md`.

## Runtime assumptions (decided 2026-06-13)

- Target surface is **Claude Code + ACP** (swappable coding CLI), not Claude Code
  alone. SKILL.md content should stay LCD (lowest common denominator) where possible.
- Memory starts as flat **MEMORY.md** / signals files; a queryable DB (gbrain)
  replaces it later. Don't hard-bake gbrain assumptions yet.
- Handoff supports **both** `sessions_spawn()` (live) and PR + webhook (async).
- Stacks are overlays. LAMP is one overlay among several, not the spine.
