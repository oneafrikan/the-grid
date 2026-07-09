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
the-grid is a personal wiring hub for an AI-agent ecosystem — Claude, OpenClaw, Paperclip, and friends. It's not a framework; it's one person's opinionated system for organising and activating skills, agents, and machines. Fork it for your own. Skills are the first asset type it manages, but the remit is broader: agents, machines, MCP servers, prompts, and reusable automations are already growing in.

The core mechanic: a single script (`scripts/wire.sh`) symlinks skills — and agents composed by `agent-factory/` — into `~/.claude/skills/` and `~/.claude/agents/` so Claude picks them up automatically — no installs, no config files.

## The four factories

Four sibling scaffolds, each owning a different asset type:

| Factory | Produces | Deployed via |
|---------|----------|---------------|
| `skills-factory/` | New skills (built via a Karpathy loop elsewhere, dropped into `skills/`) | `scripts/wire.sh` symlinks |
| `agent-factory/` | Composed AI dev-team agents (`role × stack × skills`) — 27 roles today: 4 orchestrators (CC skills) + 23 specialists (CC subagents) | `scripts/wire.sh` (Claude Code target); OpenClaw + Paperclip targets next |
| `automation-factory/` | Reusable automation patterns (e.g. `issue-loop`) | Cut into a target repo's tracked `loop/` folder |
| `project-factory/` | Whole new project scaffolds from a template | `scripts/cut-project.sh` (seed or retrofit) |

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
  machines/             ← per-machine skill/project overlays (machines/<host>.txt)
  docs/                 ← reference docs, playbooks, resources
  prompts/              ← reusable prompts
  agent-factory/        ← composes AI dev-team agents (role × stack × skills); live
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
    reconcile.sh        ← removes stale skill shadows on a new machine
    cut-project.sh      ← seeds/retrofits a project-factory template
  tests/
    test_wiring.bats
    test_skill_format.bats
    test_catalog.bats
    test_repo_health.bats
    lib/bats-core/      ← test runner (submodule, no install needed)
  CLAUDE.md               ← full project context for Claude sessions
  SKILLS.md               ← generated skill index (never edit by hand)
  LEARNINGS.md            ← durable lessons mined from project history
  baseline-submodules.txt ← baseline allowlist: wired on every machine
  machines/<host>.txt     ← per-machine overlay (adds/subtracts on the baseline)
  TODO.md                 ← issue map; open work lives in GitHub Issues
```

## Bootstrap (new machine)

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

## Checking grid health

```bash
bash scripts/check-grid.sh
```

Runs the bats suite (one-line PASS/FAIL — full output only on failure) and scans
for broken grid-owned symlinks. Exits non-zero if anything's wrong, so it works
as a CI / pre-push gate. A `pre-commit` hook (in `.githooks/`, activated by
`bootstrap.sh`) runs the same tests before every commit; bypass with
`git commit --no-verify` or `GRID_SKIP_HOOK=1`.

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

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, and broken symlink detection. All tests use temp dirs and never touch the real `~/.claude/skills/`.

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
