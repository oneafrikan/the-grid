# the-grid

> ## TL;DR
>
> **the-grid turns Claude Code from an empty chat box into a ready-equipped workspace, and keeps it identical on every machine you use.**
>
> **The problem:** the useful stuff for AI coding agents (skills, agent roles, prompts) is scattered across hundreds of repos. You find it by hand, copy it around, and it goes stale. Install everything and your session drowns in it.
>
> **What it does:** clone once, run one command, and you get:
>
> 1. **~130 curated skills as slash commands** (`/standup`, `/review`, `/ship`, `/skill-scout`…). Another ~100 are searchable but kept switched off.
> 2. **38 ready-made AI roles you can call on:** a dev team (tech lead, backend, QA, security…), a finance desk, a Socratic tutor (`/morpheus`), and a front door (`/tron`) that tells you which one to use.
> 3. **Templates** to start new projects with specs and agents already wired in.
>
> **How:** one script symlinks everything into `~/.claude/` and keeps one opt-out session-end hook in `~/.claude/settings.json` (see [How wire.sh works](#how-wiresh-works)). No installs, and the same setup follows you across laptops and servers.
>
> **Today vs next:** **Claude Code** is the default and the tested target. Codex CLI, OpenCode and Gemini CLI also get skills, subagents and rule packs through opt-in `harness:<name>` entries ([docs/harnesses.md](docs/harnesses.md)); Cursor gets rule packs only. None of those four has been smoke-tested on a real install yet.
>
> **Think of it as:** dotfiles for your AI assistant. **Start here:** after install, run `/tron`.

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

— Kevin Flynn, *TRON: Legacy* (2010)

the-grid is a personal wiring hub for an AI-agent ecosystem — Claude, OpenClaw, Paperclip, and friends. It's not a framework; it's one person's opinionated system for organising and activating skills, agents, and machines. Fork it for your own.

## What you get

**232 skills indexed, 132 wired live** (14 built by Gareth, 118 from curated
upstream repos) **+ 100 more in a searchable library** — plus 38 composed AI
agents across 4 ready-to-run teams (7 orchestrators, 31 specialists). Every agent
role follows a written contract (checked by `compose.py --lint-roles`) and can be
given a tool allowlist in its `role.yaml`.

A sample across domains:

| Domain | Examples |
|---|---|
| Engineering & review | `code-reviewer`, `debugging-wizard`, `architecture-designer`, `security-reviewer` |
| Spec-driven planning | 12 `openspec-*` skills — explore → propose → apply → verify → archive |
| Process & planning | `brainstorming`, `grill-me`, `triage`, `feature-forge` |
| Workflow & quality gates | `review`, `qa`, `ship`, `design-review`, `benchmark` |
| Docs & office formats | `docx`, `pptx`, `xlsx`, `internal-comms` |
| Anti-overengineering | the `ponytail` family — minimum-diff implementer mode |
| Navigating the-grid itself | `skill-scout`, `grid-help`, `mine-learnings`, `handoff` |

Composed agent teams (built by `agent-factory/`, invoked as slash commands or
delegated subagents): **`core`** — cross-desk infra (issue triage, a librarian,
a general researcher, a platform engineer, and `/tron`, the front door); **`grid`** — a dev-team roster, three orchestrators
(`/grid-tech-lead`, `/grid-ceo-orchestrator`, `/grid-growth-hacker`) delegating
to specialists like backend-dev, security-reviewer, qa-engineer, and
data-scientist; **`finance-desk`** — a personal-finance pipeline;
**`learning-desk`** — `/morpheus` (Socratic tutor for any topic), `/oracle` (learns
about you, privately) and `tank` (agent-to-agent lessons). Compose your own team
from the same roles.

This is a sample, not the full list — browse everything in
**[SKILLS.md](SKILLS.md)**, or ask **`/skill-scout`** to search it for you.

## How it works

One script, `scripts/wire.sh`, symlinks skills — and agents composed by
`agent-factory/` — into `~/.claude/skills/` and `~/.claude/agents/` so Claude
picks them up automatically. No installs, no config files to write by hand. It
also adds one generated SessionEnd hook (auto-handoff) to
`~/.claude/settings.json`, on by default; the off switch is in
[How wire.sh works](#how-wiresh-works).

Everything above is produced by one of four sibling factories, each owning a
different asset type:

| Factory | Produces | Deployed via |
|---------|----------|---------------|
| `agent-factory/` | Composed AI agents (`role × stack × skills`) — 4 public projects (`core`, `grid`, `finance-desk`, `learning-desk`; 38 roles, 7 orchestrators + 31 specialists) plus any private desk composed separately | `scripts/wire.sh` (Claude Code target; opt-in `harness:<name>` entries add Codex, OpenCode, Gemini CLI and others) |
| `automation-factory/` | Reusable automation patterns (e.g. `issue-loop`) | `bash scripts/instantiate.sh issue-loop <repo> --profile work`: cut into a target repo's tracked `loop/` folder; the loop opens PRs and never merges |
| `project-factory/` | Whole new project scaffolds from a template | `project-factory/scripts/cut-project.sh` (seed or retrofit) |
| Skill wiring | the curated skill set (`skills/` plus the `repos/` submodules) | `scripts/wire.sh`, steered by `baseline-submodules.txt` and `machines/<host>.txt` |

There is deliberately **no fifth factory for specs** — OpenSpec already fills
that role; see "Spec-driven development" below.

## Getting started

One command — clone, then run `bootstrap.sh` (syncs submodules → wires skills):

```bash
git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid \
  && bash ~/.the-grid/scripts/bootstrap.sh
```

Using your own fork? Put its URL in place of `oneafrikan/the-grid`.

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
and composed orchestrators are too (`/tron`, `/morpheus`, `/oracle`, `/grid-tech-lead`,
`/grid-ceo-orchestrator`…) — specialist agents are subagents you delegate to, not commands.
Not sure where to start? Run **`/tron`**: it asks what you want to do and points you to the right one.

**Lost? The help skills are the entry point:**

| Command | Answers |
|---|---|
| `/tron` | I have a goal — which skill or agent should I use? (checks what is wired on this machine) |
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
    example.txt         ← tracked starting point for an overlay
    <host>.txt          ← GITIGNORED overlay (adds/subtracts on the baseline)
    <host>.local.txt    ← GITIGNORED overlay — private project gates
  docs/                 ← reference docs and resources
    SOURCES.md          ← generated: upstream URL per submodule (never edit)
    model-selection.md  ← which model for which job, with prices + benchmarks
    agent-retro.md      ← review loop that starts from the run record
    reference-repos.md, reference-resources.md ← curated external references
  agent-factory/        ← composes AI dev-team agents (role × stack × skills); live
    models.yaml         ← the one tier-to-model map for generated agents
    run_evals.py        ← runs the golden cases in evals/ (opt-in, spend-capped)
    deploy_hooks.py     ← writes guard/auto-handoff hooks into settings files
  evals/                ← golden cases that check how agent roles behave
  automation-factory/   ← reusable automation patterns (e.g. issue-loop), cut into target repos
  project-factory/      ← scaffolds brand-new projects from a template
                        ← seed or retrofit with project-factory/scripts/cut-project.sh <template> <dir>
  hooks/                ← Claude Code guard hooks + the auto-handoff hook (see hooks/README.md)
  rules/                ← path-scoped coding-convention rule packs, opt-in (docs/rules.md)
  plugins/              ← GENERATED Claude Code plugin bundles (scripts/build-plugins.py; never hand-edit)
  contexts/             ← opt-in working-mode prompts (claude-dev / claude-research / claude-review)
  dist/                 ← GENERATED portable single-file personas (scripts/build-personas.sh)
  openspec/             ← OpenSpec changes (proposals, design, tasks) for the-grid itself
  signals/              ← claims filed for the knowledge flow, plus agent handoffs (signals/README.md)
  knowledge/            ← recorded claims by stage; canon/ is human-approved (knowledge/README.md)
  _retired/             ← archive, not gated or deployed; removal is pending the operator's GitHub-side cleanup
  repos/                ← sibling repos as git submodules
    gstack/             (each may contain many skill dirs)
    openclaw/
    paperclip/
    ...
  scripts/
    grid                ← submodule-free install CLI (install, lock, doctor, repair, ...; BOOTSTRAP.md)
    bootstrap.sh        ← one-shot setup: submodules → wire (--with-agents: compose too)
    wire.sh             ← creates ~/.claude/skills/ + ~/.claude/agents/ symlinks (idempotent)
    catalog.sh          ← regenerates SKILLS.md
    sources.sh          ← regenerates docs/SOURCES.md; --check link-checks every URL
    reconcile.sh        ← moves stale skill shadows aside (dated backup dir) on a new machine
    check-grid.sh       ← full bats suite + broken-symlink scan (CI / pre-push gate)
    instantiate.sh      ← cuts an automation-factory pattern into a target repo (issue-loop; idempotent)
    rules.py            ← lints, lists and emits the rule packs (rules/)
    audit.sh, audit.py  ← the vetting scan that wire.sh runs before touching any link
    gate.sh             ← the commit gate: shellcheck, catalog, role lint, composed output, tests
    map.py              ← generates MAP.md; `status` prints stage and signal counts (never edit MAP.md)
    run-record.sh       ← appends one line per agent run to a local private log
  tests/
    test_wiring.bats, test_catalog.bats, test_skill_format.bats, test_repo_health.bats
    test_compose_lint.bats, test_authoring_variants.bats, test_schema_tools_models.bats
    test_deploy.bats, test_eval_cases.bats, test_run_record.bats
    test_project_factory.bats, test_checks.bats, test_gate.bats
    lib/bats-core/      ← test runner (submodule, no install needed)
  CLAUDE.md               ← full project context for Claude sessions
  SKILLS.md               ← generated skill index (never edit by hand)
  MAP.md                  ← generated session-start map (scripts/map.py; never edit by hand)
  PURPOSE.md, GUARDRAILS.md, BEHAVIOUR.md ← what the grid is for, its must-nots, its agent-behaviour additions (drafts until approved)
  LEARNINGS.md            ← durable lessons mined from project history
  policy.yaml             ← vetting policy read by scripts/audit.py
  grid.yaml, grid.lock    ← where wired skills come from, and the pinned commits (scripts/grid)
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

Runs the full bats suite (one-line PASS/FAIL — full output only on failure; it takes
many minutes, roughly 15 on CI) and scans for broken grid-owned symlinks. Exits
non-zero if anything's wrong, so it works as a CI / pre-push gate. A `pre-commit`
hook (in `.githooks/`, activated by `bootstrap.sh`) runs `scripts/gate.sh` before
every commit; bypass with
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

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, broken symlink detection, the role contract and its lint, per-project agent deploys, the run record, and the golden-case runner (against a stub, never a real model). All tests use temp dirs and never touch the real `~/.claude/skills/`. `bash scripts/gate.sh` runs the full commit gate.

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

Before step 1 it runs the vetting audit and refuses to change anything if a wired
skill fails it. Besides symlinks, `wire.sh` also writes `.wired.manifest` in this
repo and keeps one generated **auto-handoff** SessionEnd hook entry in
`~/.claude/settings.json` (`agent-factory/deploy_hooks.py --user`; your own hooks and
keys are left alone, but the first write reformats the file as 2-space-indented JSON).
The hook is **on by default**: when a session ends it may run one headless Claude call
to write a handoff note. To switch it off, add `-hook:auto-handoff` to the baseline or
your machine overlay (`machines/<host>.txt`) and re-run `wire.sh`, which removes the
entry; details in [hooks/README.md](hooks/README.md).

Opt-in coding-convention rule packs (`rules:<pack>` manifest entries) are documented in [docs/rules.md](docs/rules.md).

Step 4 wires whatever `compose.py` last produced. Because that output is
git-ignored, a freshly pulled machine must **recompose first** (see
[BOOTSTRAP.md](BOOTSTRAP.md)) or `wire.sh` will wire a stale/empty agent set.

Override paths via env vars (used by tests):

```bash
GRID_DIR=/path/to/grid SKILLS_DIR=/path/to/skills bash scripts/wire.sh
```

## Reconciling a machine (removing stale shadows)

`wire.sh` won't clobber a real directory that shadows a grid skill (safety). On a fresh machine those shadows are often stale copies. `reconcile.sh` moves them aside so the-grid owns the slot, then re-wires.

```bash
bash scripts/reconcile.sh           # dry run — list shadowing dirs
bash scripts/reconcile.sh --force   # move them to a dated backup dir (audit gate first, sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".

## Roadmap

Shipped today: the **Claude Code** target is built and wired live.
`compose.py --target` also accepts `openclaw`, `openclaw-native`, `paperclip`,
`codex`, `gemini-cli`, `opencode` and `portable` (single-file personas, committed
under `dist/personas/`). Skills, subagents and rule packs reach Codex CLI, OpenCode
and Gemini CLI through opt-in `harness:<name>` manifest entries
([docs/harnesses.md](docs/harnesses.md)); Cursor gets rule packs only
(`scripts/rules.py emit --harness cursor`), not an agent target.

Not built, or not yet verified — tracked in [Issues](../../issues):

| Direction | Status |
|---|---|
| Real-install smoke tests of the Codex, OpenCode and Gemini CLI targets | Not done; the vendor docs were read, not exercised ([docs/harnesses.md](docs/harnesses.md)) |
| Amp | Blocked — custom-agent mechanism needs verifying first |
| OpenSpec **stores** (cross-repo planning) | Open decision, deliberately not adopted |

The compose model is a multi-target compiler: one source (the OpenClaw 5-file
identity model — SOUL/IDENTITY/AGENTS/USER/MEMORY + skills) emitting to
different runtimes. Adding a target means writing an emitter, not re-authoring
any agent.

Model routing across providers (OpenRouter and friends) is a live question, not
a built feature — see [docs/model-selection.md](docs/model-selection.md) for the
current price/capability picture and the open evidence gaps in it.

## Status & expectations

This is one person's working system, shared because the mechanics are reusable —
not a supported product. Concretely:

- **It will change under you.** No versioning, no deprecation cycle.
- **It is opinionated.** The wiring model, the four factories, and the compose
  format are all one person's choices, not a consensus design.
- **Personal config is gitignored, not mixed in.** `baseline-submodules.txt`,
  `machines/<host>.txt`, and the dev-journal `LOGS/` convention are all personal
  and untracked — you get a generic `.example` starting point for the first two
  and owe nothing for the third. A fork never inherits Gareth's machine names,
  account routing, or notes.
- **Fork rather than depend.** The wiring model — manifest, symlinks,
  compose-then-wire — is the transferable part. Copy it and point it at your own
  skills.
- **`wire.sh` only ever replaces symlinks that point into this repo.** It won't
  clobber a real directory or a foreign symlink in `~/.claude/skills/`. It also
  edits `~/.claude/settings.json` (the auto-handoff hook, on by default; see
  "How wire.sh works"). Read it before running it anyway; it writes to your home
  directory.

## License

[MIT](LICENSE) — covers the-grid's own code (`scripts/`, `agent-factory/`,
root-owned `skills/`, etc.). Submodules under `repos/` are separate upstream
projects with their own licenses.
