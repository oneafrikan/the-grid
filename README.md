```

████████╗██╗  ██╗███████╗    ██████╗ ██████╗ ██╗██████╗ 
╚══██╔══╝██║  ██║██╔════╝    ██╔════╝██╔══██╗██║██╔══██╗
   ██║   ███████║█████╗      ██║  ███╗██████╔╝██║██║  ██║
   ██║   ██╔══██║██╔══╝      ██║   ██║██╔══██╗██║██║  ██║
   ██║   ██║  ██║███████╗    ╚██████╔╝██║  ██║██║██████╔╝
   ╚═╝   ╚═╝  ╚═╝╚══════╝     ╚═════╝ ╚═╝  ╚═╝╚═╝╚══════╝
 _______________________________________________________
 \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ \_ _/

```

```
The Grid.
A digital frontier.
I tried to picture clusters of information as they moved through the computer.
What did they look like?
Ships? Motorcycles?
Were the circuits like freeways?
I kept dreaming of a world I thought I'd never see.
And then, one day...
I got in.
```

# the-grid

the-grid is a personal wiring hub for an AI-agent ecosystem — Claude, OpenClaw, Paperclip, and friends. It's not a framework; it's one person's opinionated system for organising and activating skills, agents, and machines. Fork it for your own.

## What you get

**239 skills indexed, 137 wired live** (14 built by Gareth, 123 from curated
upstream repos) **+ 102 more in a searchable library** — plus 34 composed AI
agents across 3 ready-to-run teams (4 orchestrators, 30 specialists), each held to a
written contract (see [Governed agents](#governed-agents)).

A sample across domains:

| Domain | Examples |
|---|---|
| Engineering & review | `code-reviewer`, `debugging-wizard`, `architecture-designer`, `security-reviewer` |
| Spec-driven planning | 12 `openspec-*` skills — explore → propose → apply → verify → archive |
| Process & planning | `brainstorming`, `to-prd`, `triage`, `feature-forge` |
| Workflow & quality gates | `review`, `qa`, `ship`, `design-review`, `benchmark` |
| Docs & office formats | `docx`, `pptx`, `xlsx`, `internal-comms` |
| Anti-overengineering | the `ponytail` family — minimum-diff implementer mode |
| Navigating the-grid itself | `skill-scout`, `grid-help`, `mine-learnings`, `handoff` |

Composed agent teams (built by `agent-factory/`, invoked as slash commands or
delegated subagents): **`core`** — cross-desk infra (issue triage, a librarian,
a general researcher, a platform engineer); **`grid`** — a dev-team roster (not yet benchmarked), three orchestrators
(`/grid-tech-lead`, `/grid-ceo-orchestrator`, `/grid-growth-hacker`) delegating
to specialists like backend-dev, security-reviewer, qa-engineer, and
data-scientist; **`finance-desk`** — a personal-finance pipeline. Compose your
own team from the same roles.

This is a sample, not the full list — browse everything in
**[SKILLS.md](SKILLS.md)**, or ask **`/skill-scout`** to search it for you.

## Governed agents

The 34 agents are not left to improvise. Each one is held to a written contract, and
the parts that can be checked mechanically are checked. This is governance of how the
agents behave (limits, rules, records), informed by recent talks and open-source work on
running AI agents inside engineering teams.

| Principle | What the grid does | How it is held |
|---|---|---|
| One written contract for every agent | All 34 roles have a ranked "what to get right hardest" list and hard rules, including four shared ones: verify before claiming, say what is planned versus built, report failures verbatim, never grade your own work | `compose.py --lint-roles` fails if a rule is dropped |
| Independent check | Each role names who verifies its work; orchestrators read a specialist's evidence before accepting it; release gates cannot be overridden | Written rule, lint checks it is present |
| Limit what an agent can touch | `tools:` allowlist in `role.yaml`: `security-reviewer` and `qa-engineer` cannot Edit or Write; `finance-strategist` can only read; `finance-risk-officer` can only read and compute | Enforced by Claude Code at deploy time |
| Earn autonomy in steps | A role marked `unattended: true` must preview before it writes, state its autonomy level, record each run, and use one outward channel; `gh-triage` records a preview on its first run against a repo and writes nothing | Lint checks the rules are present |
| Record runs | `scripts/run-record.sh` appends one JSON line per run (role, operator, action, outcome, cost) to a local private log; `docs/agent-retro.md` is the review loop that starts from it | Built; fills as unattended roles run |
| Govern model swaps | `agent-factory/models.yaml` maps each tier to a model (optional pinning); a role off the default tier needs a `model_rationale`; `docs/model-selection.md` tracks prices and retirement dates | Lint checks the rationale |
| Measure before and after | `evals/` holds golden cases run by `agent-factory/run_evals.py`: opt-in, spend-capped, tools switched off | 14 cases; 13 hold, 1 showed a real improvement |

```bash
agent-factory/.venv/bin/python agent-factory/compose.py --lint-roles       # the contract and the limits
agent-factory/.venv/bin/python agent-factory/run_evals.py --dry-run        # plan and worst-case spend, no model call
GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --yes   # real runs: costs money
```

**What this does not claim.** The lint proves a rule exists, not that it is well worded. A tool
allowlist narrows a role; it does not sandbox it (a shell can still write files). Most golden cases
are tripwires: they passed before and after. There is no evidence yet that the agents do better work
on real tasks, only that the rules hold and one unsafe behaviour is fixed.

**Not applied yet.** Workflows as code on a shared runner, durable execution, tracing and per-agent
cost, a per-action autonomy ladder, specs with non-goals and a ready check, and completion claims
verified in code.

## How it works

One script, `scripts/wire.sh`, symlinks skills — and agents composed by
`agent-factory/` — into `~/.claude/skills/` and `~/.claude/agents/` so Claude
picks them up automatically. No installs, no config files.

Everything above is produced by one of four sibling factories, each owning a
different asset type:

| Factory | Produces | Deployed via |
|---------|----------|---------------|
| `skills-factory/` | New skills (built via a Karpathy loop elsewhere, dropped into `skills/`) | `scripts/wire.sh` symlinks |
| `agent-factory/` | Composed AI agents (`role × stack × skills`) — 3 public projects (`core`, `grid`, `finance-desk`; 34 roles, 4 orchestrators + 30 specialists) plus any private desk composed separately | `scripts/wire.sh` (Claude Code target); OpenClaw + Paperclip targets next |
| `automation-factory/` | Reusable automation patterns (e.g. `issue-loop`) | Cut into a target repo's tracked `loop/` folder |
| `project-factory/` | Whole new project scaffolds from a template | `scripts/cut-project.sh` (seed or retrofit) |

There is deliberately **no fifth factory for specs** — OpenSpec already fills
that role; see "Spec-driven development" below.

## Getting started

One command — clone, then run `bootstrap.sh` (syncs submodules → wires skills):

```bash
git clone https://github.com/<your-username>/the-grid.git ~/.the-grid \
  && bash ~/.the-grid/scripts/bootstrap.sh
```

Add `--with-agents` to also compose **and** wire the agent team in the same run:

```bash
bash ~/.the-grid/scripts/bootstrap.sh --with-agents
```

Prefer the manual steps? They're equivalent:

```bash
cd ~/.the-grid
git submodule update --init --recursive
bash scripts/wire.sh
```

That's it. Skills are live immediately. For the full sequence (including the
agent-factory compose step), see **[BOOTSTRAP.md](BOOTSTRAP.md)**.

## Daily usage

Once wired, every skill is a slash command (`/standup`, `/skill-scout`, `/ponytail`…)
and composed orchestrators are too (`/grid-tech-lead`, `/grid-ceo-orchestrator`…) — specialist
agents are subagents you delegate to, not commands.

**Lost? The help skills are the entry point:**

| Command | Answers |
|---|---|
| `/grid-help` | Which slash command or subagent do I want? How do the factories differ? |
| `/openspec-help` | Which of the 12 openspec skills do I want? How do I add specs to this repo? |
| `/ponytail-help` | Which ponytail mode do I want? |

Full walkthrough — orchestrators vs specialists, the four factories in practice,
promoting a library skill to wired: **[USAGE.md](USAGE.md)**.

Picking a model for a job (prices, independent benchmarks, worked cost maths):
**[docs/model-selection.md](docs/model-selection.md)**.

## Spec-driven development (OpenSpec)

the-grid wires [OpenSpec](https://openspec.dev) ([Fission-AI/openspec](https://github.com/Fission-AI/openspec), MIT)
on every machine: 12 `openspec-*` skills covering
`explore → propose → apply → verify → archive`. Specs live in the repo as plain
markdown, so a plan survives the session that produced it.

OpenSpec already *is* the spec factory, so the-grid adds only two thin layers:

- `project-factory/templates/_common/SPECS.md` — the convention plus agent
  instructions, laid down on **every** cut project, seed or retrofit. Spec-driven
  is the default rather than a per-project decision someone has to remember.
- `agent-factory/_core/AGENTS_base.md` — a boot-sequence check for `SPECS.md` /
  `openspec/`. One edit reaches every composed agent. Conditional: repos without
  those markers are untouched.

`/openspec-help` is the reference card; `/spec-scout` audits adoption and
reports spec↔code drift.

> **External dependency.** These skills shell out to a CLI that is *not*
> vendored — without it they dead-end immediately:
> ```bash
> npm install -g @fission-ai/openspec@latest   # needs Node >= 20.19.0
> ```
> `openspec init` is optional: `openspec new change` bootstraps `openspec/` on
> its own.

## Private projects

Not everything belongs in a public repo. `agent-factory` can compose a project
whose **roles and compose config live entirely outside this repo**, via
`GRID_PRIVATE_ROLES_DIR` (see `compose.py`'s `role_dir()`), gated by a
`project:<name>` entry in `machines/<host>.local.txt` — which is gitignored, so
even the gate stays out of git history.

Composed output lands in the same `agent-factory/projects/` as everything else
and wires identically. Nothing about the mechanism is private; only the content
is. That separation is the point — fork this repo and your own private desk
never touches its history.

> ⚠ `compose.py` **overwrites** `projects/<name>/` wholesale. Recomposing the
> public projects while a private project's roles are unreachable destroys that
> project's composed output, and the next `wire.sh` removes its symlinks. Check
> `machines/<host>.local.txt` against `ls agent-factory/projects/` before
> recomposing.

## Repo layout

```
~/.the-grid/
  skills/               ← skills owned by the-grid (original or forked)
    standup/
      SKILL.md
    rubber-duck/
      SKILL.md
    ...
  agents/               ← hand-authored root-owned agents (personas/behavior-modifiers)
  machines/             ← per-machine skill/project overlays
    <host>.txt          ← committed overlay (adds/subtracts on the baseline)
    <host>.local.txt    ← GITIGNORED overlay — private project gates
  docs/                 ← reference docs, playbooks, resources
    SOURCES.md          ← generated: upstream URL per submodule (never edit)
    model-selection.md  ← which model for which job, with prices + benchmarks
  prompts/              ← reusable prompts
  agent-factory/        ← composes AI dev-team agents (role × stack × skills); live
    models.yaml         ← the one tier-to-model map for generated agents
    run_evals.py        ← runs the golden cases in evals/ (opt-in, spend-capped)
  evals/                ← golden cases that check how agent roles behave
  skills-factory/       ← scaffolding for generating new skills (early)
  automation-factory/   ← reusable automation patterns (e.g. issue-loop), cut into target repos
  project-factory/      ← scaffolds brand-new projects from a template
  repos/                ← sibling repos as git submodules
    gstack/             (each may contain many skill dirs)
    openclaw/
    paperclip/
    ...
  scripts/
    wire.sh             ← creates ~/.claude/skills/ + ~/.claude/agents/ symlinks (idempotent)
    catalog.sh          ← regenerates SKILLS.md
    sources.sh          ← regenerates docs/SOURCES.md; --check link-checks every URL
    reconcile.sh        ← removes stale skill shadows on a new machine
    cut-project.sh      ← seeds/retrofits a project-factory template
    gate.sh             ← the commit gate: shellcheck, catalog, role lint, composed output, tests
    run-record.sh       ← appends one line per agent run to a local private log
  tests/
    test_wiring.bats
    test_skill_format.bats
    test_catalog.bats
    test_repo_health.bats
    lib/bats-core/      ← test runner (submodule, no install needed)
  CLAUDE.md               ← full project context for Claude sessions
  SKILLS.md               ← generated skill index (never edit by hand)
  LEARNINGS.md            ← durable lessons mined from project history
  baseline-submodules.example.txt ← tracked starting point; copy to the line below
  baseline-submodules.txt ← GITIGNORED, personal — your own baseline allowlist
  machines/example.txt    ← tracked starting point; copy to machines/<host>.txt
  machines/<host>.txt     ← GITIGNORED, personal — your own per-machine overlay
  TODO.md                 ← issue map; open work lives in GitHub Issues
```

`LOGS/` (a dev-journal convention some skills write to) is gitignored too —
nothing in the-grid requires it, and it isn't part of the layout above.

## Checking grid health

```bash
bash scripts/check-grid.sh
```

Runs the bats suite (one-line PASS/FAIL — full output only on failure) and scans
for broken grid-owned symlinks. Exits non-zero if anything's wrong, so it works
as a CI / pre-push gate. A `pre-commit` hook (in `.githooks/`, activated by
`bootstrap.sh`) runs the same tests before every commit; bypass with
`git commit --no-verify` or `GRID_SKIP_HOOK=1`.

Link rot is checked separately — upstream repos get renamed, deleted, or made
private with no local symptom until a fresh machine tries to clone:

```bash
bash scripts/sources.sh --check    # HEADs every submodule URL, non-zero on failure
```

> **Already set up, just pulled new changes?** See BOOTSTRAP.md →
> *Updating an existing machine*. Key gotcha: `agent-factory/projects/*` is
> git-ignored, so changes to composed agents/rosters need a **recompose** then
> re-wire — `git pull` alone won't refresh them.

## Adding a skill directly to the-grid

Skills owned by the-grid (original work or deliberate forks) live in `skills/`.

```bash
mkdir ~/.the-grid/skills/my-skill
cat > ~/.the-grid/skills/my-skill/SKILL.md <<'EOF'
---
name: my-skill
description: One-line description and trigger phrases.
---

# My Skill
...
EOF
bash ~/.the-grid/scripts/wire.sh
```

Root-level skills win over any same-named skill in a submodule — that's the escape hatch for an edited fork. Don't copy an upstream skill here just to use it; add the repo as a submodule and wire it instead.

## Adding a sibling repo as a submodule

```bash
cd ~/.the-grid
git submodule add <repo-url> repos/some-skill-repo
git submodule update --init
bash scripts/wire.sh
```

A newly added submodule is **library-only** by default (indexed in `SKILLS.md`, not symlinked). To wire its skills live on every machine, add its name to `baseline-submodules.txt` (or to a single machine's `machines/<host>.txt` overlay) and re-run `bash scripts/wire.sh`.

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, broken symlink detection, the role contract and its lint (tool allowlists, the unattended rules, the model map), per-project agent deploys, the run record, and the golden-case runner (against a stub, never a real model). All tests use temp dirs and never touch the real `~/.claude/skills/`. `bash scripts/gate.sh` runs the full commit gate.

## How wire.sh works

Skills are split into two tiers:

- **Wired** — repos in the manifest: a shared `baseline-submodules.txt` (every machine) plus an optional per-machine overlay `machines/<host>.txt` (keyed on `hostname -s`) that adds/subtracts entries. Their skills are symlinked live into `~/.claude/skills/`.
- **Library** — everything else: indexed in `SKILLS.md` and searchable via `skill-scout`, but not symlinked. Keeps the active skill set sane even as the-grid indexes thousands of ecosystem skills.

On each run, `scripts/wire.sh`:

1. Tears down all grid-owned symlinks (anything pointing into this repo).
2. Re-wires skills from the manifest (baseline + this machine's overlay), discovered at any nesting depth.
3. Wires `skills/` last — root skills override any same-named repo skill.
4. Wires composed **agents** from `agent-factory/projects/*/_claude-code/` — orchestrator skills into `~/.claude/skills/`, specialist subagents into `~/.claude/agents/`.
5. Leaves symlinks pointing elsewhere untouched.
6. Regenerates `SKILLS.md` via `catalog.sh`.

Step 4 wires whatever `compose.py` last produced. Because that output is
git-ignored, a freshly pulled machine must **recompose first** (see
[BOOTSTRAP.md](BOOTSTRAP.md)) or `wire.sh` will wire a stale/empty agent set.

Override paths via env vars (used by tests):

```bash
GRID_DIR=/path/to/grid SKILLS_DIR=/path/to/skills bash scripts/wire.sh
```

## Reconciling a machine (removing stale shadows)

`wire.sh` won't clobber a real directory that shadows a grid skill (safety). On a fresh machine those shadows are often stale copies. `reconcile.sh` removes them so the-grid owns the slot, then re-wires.

```bash
bash scripts/reconcile.sh           # dry run — list shadowing dirs
bash scripts/reconcile.sh --force   # remove them (sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".

## Roadmap

Shipped today: the **Claude Code** target is built and wired live.
`compose.py --target` also accepts `openclaw`, `openclaw-native`, and
`paperclip`.

Planned, not built — tracked in [Issues](../../issues):

| Direction | Status |
|---|---|
| `opencode` compose target | Researched, scoped, not implemented |
| OpenAI Codex CLI target | Scoped |
| Gemini CLI target | Scoped |
| Cursor | Validating whether the claude-code output is reusable as-is |
| Amp | Blocked — custom-agent mechanism needs verifying first |
| Portable single-file personas for chat-UI Projects | Scoped |
| OpenSpec **stores** (cross-repo planning) | Open decision, deliberately not adopted |

The compose model is a multi-target compiler: one source (the OpenClaw 5-file
identity model — SOUL/IDENTITY/AGENTS/USER/MEMORY + skills) emitting to
different runtimes. Adding a target means writing an emitter, not re-authoring
any agent.

Model routing across providers (OpenRouter and friends) is a live question, not
a built feature — see [docs/model-selection.md](docs/model-selection.md) for the
current price/capability picture and the open evidence gaps in it.

Governance work still ahead (see [Governed agents](#governed-agents)): workflows as
code on a shared runner, durable execution, tracing and per-agent cost, a per-action
autonomy ladder, specs with non-goals and a ready check, and completion claims
verified in code.

## Status & expectations

This is one person's working system, shared because the mechanics are reusable —
not a supported product. Concretely:

- **It will change under you.** No versioning, no deprecation cycle.
- **It is opinionated.** The wiring model, the four factories, and the compose
  format are all one person's choices, not a consensus design.
- **The agents are governed, not benchmarked.** Rules, tool limits and checks keep
  them in line; nothing yet shows they do better work on real tasks.
- **Personal config is gitignored, not mixed in.** `baseline-submodules.txt`,
  `machines/<host>.txt`, and the dev-journal `LOGS/` convention are all personal
  and untracked — you get a generic `.example` starting point for the first two
  and owe nothing for the third. A fork never inherits Gareth's machine names,
  account routing, or notes.
- **Fork rather than depend.** The wiring model — manifest, symlinks,
  compose-then-wire — is the transferable part. Copy it and point it at your own
  skills.
- **`wire.sh` only ever touches symlinks that point into this repo.** It won't
  clobber a real directory or a foreign symlink in `~/.claude/skills/`. Read it
  before running it anyway; it writes to your home directory.

## License

[MIT](LICENSE) — covers the-grid's own code (`scripts/`, `agent-factory/`,
root-owned `skills/`, etc.). Submodules under `repos/` are separate upstream
projects with their own licenses.
