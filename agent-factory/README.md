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
│   ├── role.yaml           metadata: title, default/cron model, summary, owns, orchestrator
│   ├── SOUL.md             personality / voice (required)
│   ├── IDENTITY.md         nameplate extras (optional; merged over _core)
│   ├── AGENTS.md           routing + a {{ROSTER_TABLE}} slot (optional; merged over _core)
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

Then compose a team from a config. `compose.py` is a **multi-target compiler** —
one 5-file source, a different artifact shape per `--target`:

```bash
# OpenClaw target (default): 5 identity files + agents.yaml per agent
.venv/bin/python compose.py examples/full-team.yaml
.venv/bin/python compose.py examples/full-team.yaml --dry-run     # report only

# Claude Code target: orchestrators -> CC skills, specialists -> CC subagents
.venv/bin/python compose.py examples/full-team.yaml --target claude-code
.venv/bin/python compose.py examples/full-team.yaml --target claude-code --dry-run
```

Output is regenerable and idempotent: re-running with an unchanged config
produces byte-identical files (the output dir is wiped and rewritten each run).
`projects/` output is gitignored — the compose config is the tracked artefact.

> **On a machine that just pulled new source, recompose before wiring.** A `git
> pull` updates the tracked source (`compose.py`, `roles/*`, `examples/*`) but not
> the git-ignored `projects/*`, so the live agents won't reflect the change until
> you re-run `compose.py` and then `bash scripts/wire.sh`.

The `claude-code` target writes to `projects/<name>/_claude-code/`:

```
projects/<name>/_claude-code/
├── skills/<role>/SKILL.md   one per orchestrator role (orchestrator: true)
└── agents/<role>.md         one per specialist role
```

## Wiring composed agents into Claude Code

`scripts/wire.sh` (in the-grid root) symlinks the `_claude-code/` output into
your live Claude Code config — orchestrator skills into `~/.claude/skills/`,
specialist subagents into `~/.claude/agents/` — the same idempotent, grid-owned
symlink model it uses for ecosystem skills. After composing with
`--target claude-code`, run `bash scripts/wire.sh` from the-grid root.

> Skills and subagents load at the **start** of a Claude Code session — wire,
> then open a fresh session to pick them up.

## Invoking composed agents

The orchestrator/specialist split (`role.yaml` `orchestrator:`) decides *how* you
invoke a composed agent in Claude Code:

| Form | Roles (current) | How to invoke |
|------|-----------------|---------------|
| **Skill** (orchestrator) | `ceo-orchestrator`, `tech-lead`, `growth-hacker` | Slash command: `/ceo-orchestrator`, `/tech-lead`, `/growth-hacker`. Transforms the session into that role. |
| **Subagent** (specialist) | the other 17 | **Not** a slash command. Delegate to it: *"Use the backend-dev subagent to …"*, or let an orchestrator hand off to it. Claude can also auto-delegate based on the subagent's `description`. |

Typical flow: invoke `/tech-lead`, give it a feature → it writes a PRD and hands
off (async) to the specialist subagents. You rarely call a specialist directly.

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

## Rosters & delegation

An orchestrator's roster — the agents it can hand work to — is **generated from the
compose config**, not hand-written. Each orchestrator declares its reports with a
`delegates_to:` list; the delegation topology lives with the team definition as its
single source of truth:

```yaml
agents:
  - role: ceo-orchestrator
    delegates_to: [tech-lead, product-manager, growth-hacker]
  - role: tech-lead
    delegates_to: [backend-dev, frontend-dev, designer, ...]
```

`compose.py` renders a `| Agent | Owns |` table from that list and substitutes it
into the role's `AGENTS.md` at the `{{ROSTER_TABLE}}` token. The `Owns` text is each
role's `role.yaml` `owns:` field, falling back to the first sentence of its
`summary`. Behavioural routing rules (e.g. the CEO's "never reach specialists
directly") stay as authored prose in `AGENTS.md` — only the table is generated.

Validation is symmetric and loud, so a roster can never silently drift out of sync
with the team:

- a role whose `AGENTS.md` carries `{{ROSTER_TABLE}}` **must** have a `delegates_to`
  in the config (use `delegates_to: []` for a solo/demo team), and vice-versa;
- every name in `delegates_to` must be a role present on the same team.

Any violation is a hard `compose.py` error. **full-team topology:**

- `ceo-orchestrator` → `tech-lead`, `product-manager`, `growth-hacker` (the three leads)
- `tech-lead` → engineering + data/research specialists
- `growth-hacker` → the marketing arm — a player-coach lead that also runs growth experiments itself

## Status

**Claude Code delivery target is done and live.** All 20 roles are ported to the
5-file model (`examples/full-team.yaml`): 3 orchestrators (`ceo-orchestrator`,
`tech-lead`, `growth-hacker`) + 17 specialists (product-manager, project-manager,
backend-dev, frontend-dev, designer, qa-engineer, security-reviewer, devops,
data-engineer, data-analyst, data-scientist, researcher, copywriter, ad-copy, seo,
paid-search, paid-social). Orchestrator rosters are generated from each one's
`delegates_to` (see **Rosters & delegation** above). `compose.py` emits both the
OpenClaw 5-file shape and the Claude Code skill/subagent shape; `scripts/wire.sh`
wires the CC output into `~/.claude/`. The full team is wired live on wilderness —
`/tech-lead` boots and runs end-to-end.

Remaining work (see repo-root `TODO.md`):
- **OpenClaw + Paperclip targets** — 5 files → workspace + `openclaw.json`; the
  async/autonomous heartbeat loop. Deferred (Claude Code was built first).
- **Stack overlays** — `stacks/*` are still `stack.yaml` stubs with empty `fragments`.
- **Machine manifest** — gate which composed agents wire on which machine (today
  `wire.sh` wires every composed project's `_claude-code/` output).

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
