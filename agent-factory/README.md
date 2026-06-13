# agent-factory

Composes AI dev teams from three orthogonal inputs:

```
role  ×  stack  ×  skills   ──compose.py──▶   a ready-to-run agent team
```

- **role** — *who* the agent is (Tech Lead, Backend Dev, QA…). Stack-agnostic
  identity + an operating skill. Lives in `roles/<role>/`.
- **stack** — *what* it builds on (LAMP, modern-frontend, data-engineering…).
  An overlay. Lives in `stacks/<stack>/`.
- **skills** — bolt-on capabilities pulled from the ecosystem (Paperclip, php,
  mysql…). Lives in `skills/<skill>/`.

A **compose config** (see `examples/tech-lead.yaml`) names a project and lists
agents, each as `role + stacks[] + skills[] + model`. `compose.py` reads it and
emits one folder per agent under `projects/<name>/`, rendered to the **live
OpenClaw 5-file identity model** — `SOUL.md` (how it behaves), `IDENTITY.md` (who
it is + model), `AGENTS.md` (boot sequence + async handoff), `USER.md` (who it
serves), `MEMORY.md` (what it carries) — plus a top-level `agents.yaml` that wires
the team together and lists each agent's skills by name. A role's operating skill
(its `SKILL.md`) is referenced by name, not copied — OpenClaw wires skills from a
shared skills dir.

> Sibling `skills-factory/` is a **separate** concern (skills are built there via a
> Karpathy loop in another repo, then dropped into `skills/`). This factory only
> *composes* teams from existing parts.

## Layout

```
agent-factory/
├── _core/                  shared base templates every role inherits
│   ├── SOUL_base.md        universal personality scaffolding
│   ├── IDENTITY_base.md    nameplate token template (name/role/model/cron_model)
│   ├── AGENTS_base.md      universal boot sequence + async handoff protocol
│   ├── USER_base.md        operator/team skeleton
│   ├── MEMORY_base.md      universal memory structure
│   └── agents_base.yaml    universal runtime config template
├── roles/<role>/           role source (stack-agnostic)
│   ├── role.yaml           metadata: title, default/cron model, summary, orchestrator
│   ├── SOUL.md             personality / voice (required)
│   ├── IDENTITY.md         nameplate extras (optional; merged over _core)
│   ├── AGENTS.md           roster + routing (optional; merged over _core)
│   ├── USER.md             operator-reading notes (optional; merged over _core)
│   ├── MEMORY.md           memory seed (optional; merged over _core)
│   └── SKILL.md            the role's operating skill — required, referenced by name
├── stacks/<stack>/         stack overlay (appended to AGENTS.md)
│   └── stack.yaml          + fragment files
├── skills/<skill>/         local skill library (built elsewhere, dropped here)
├── compose.py              the factory engine
├── factory.schema.yaml     what a valid compose config looks like
├── examples/               sample compose configs
└── projects/<name>/        OUTPUT — one folder per composed agent (gitignored)
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

`SOUL.md`, `AGENTS.md`, `USER.md`, and `MEMORY.md` are merged section-by-section
with their `_core` base: shared level-2 (`## `) headings unify under one heading
(base guidance first, then the role's seed); sections unique to either side are
kept in order. This is why role templates reuse the base headings.

`IDENTITY.md` is different — it's a token template. `compose.py` substitutes
`{{name}}`, `{{role}}`, `{{model}}`, `{{cron_model}}` (from `role.yaml` + the
config) and appends the role's `IDENTITY.md` extras.

Stack overlays (when a stack is named) append to `AGENTS.md` as a trailing
"Stack overlays" section — stack conventions are operating rules.

## Status

**Engine works against the 5-file model; content is in progress.** `compose.py`
renders, merges, and writes an agent idempotently in the live OpenClaw 5-file
shape, validated end-to-end with the Tech Lead role (`examples/tech-lead.yaml`).
Remaining work: port the other roles to the 5-file model (only `role.yaml`
metadata exists so far), flesh the stack overlays (`stacks/*` are `stack.yaml`
stubs with empty `fragments`), and build the per-runtime emitters (OpenClaw is
near-native today; Claude Code skill/subagent forms are next). See repo-root
`TODO.md`.

## Runtime assumptions

- The canonical agent is the **live OpenClaw 5-file model** (SOUL / IDENTITY /
  AGENTS / USER / MEMORY) + skills — verified against the running system on
  guide-server, not the (outdated 3-file) playbook.
- Target surface is **Claude Code + ACP** (swappable coding CLI), not Claude Code
  alone. Content stays LCD (lowest common denominator) where possible.
- Memory starts as flat **MEMORY.md** / signal files; a queryable DB (gbrain)
  replaces it later. Don't hard-bake gbrain assumptions yet.
- Handoff is **async** — signal files (`signals/→agent.md`, as the live system
  does) or PR + webhook. Not a live `sessions_spawn`.
- Stacks are overlays. LAMP is one overlay among several, not the spine.
- `compose.py` is a multi-target compiler: one 5-file source → OpenClaw agent
  (near-native), Claude Code subagent (flattened `.md`), or Claude Code skill
  (boots via the AGENTS.md sequence).
