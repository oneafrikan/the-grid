# the-grid

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


the-grid is a personal wiring hub for an AI-agent ecosystem — Claude, OpenClaw, Paperclip, and friends. It's not a framework; it's one person's opinionated system for organising and activating skills, agents, and machines. Fork it for your own. Skills are the first asset type it manages, but the remit is broader: agents, machines, MCP servers, and prompts are already growing in.

The core mechanic: a single script (`scripts/wire.sh`) symlinks skills into `~/.claude/skills/` so Claude picks them up automatically — no installs, no config files.

## Repo layout

```
~/.the-grid/
  skills/               ← skills owned by the-grid (original or forked)
    standup/
      SKILL.md
    rubber-duck/
      SKILL.md
    ...
  agents/               ← agent definitions (growing)
  machines/             ← machine-specific configs (growing)
  docs/                 ← reference docs, playbooks, resources
  prompts/              ← reusable prompts
  agent-factory/        ← scaffolding for composing AI dev teams (early)
  skills-factory/       ← scaffolding for generating new skills (early)
  repos/                ← sibling repos as git submodules
    gstack/             (each may contain many skill dirs)
    openclaw/
    paperclip/
    ...
  scripts/
    wire.sh             ← creates ~/.claude/skills/ symlinks (idempotent)
    catalog.sh          ← regenerates SKILLS.md
    reconcile.sh        ← removes stale skill shadows on a new machine
  tests/
    test_wiring.bats
    test_skill_format.bats
    test_catalog.bats
    test_repo_health.bats
    lib/bats-core/      ← test runner (submodule, no install needed)
  SKILLS.md             ← generated skill index (never edit by hand)
  wired-submodules.txt  ← allowlist: which repos are wired live
  TODO.md
```

## Bootstrap (new machine)

```bash
git clone https://github.com/<your-username>/the-grid.git ~/.the-grid
cd ~/.the-grid
git submodule update --init --recursive
bash scripts/wire.sh
```

That's it. Skills are live immediately.

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

A newly added submodule is **library-only** by default (indexed in `SKILLS.md`, not symlinked). To wire its skills live, add its name to `wired-submodules.txt` and re-run `bash scripts/wire.sh`.

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, and broken symlink detection. All tests use temp dirs and never touch the real `~/.claude/skills/`.

## How wire.sh works

Skills are split into two tiers:

- **Wired** — repos listed in `wired-submodules.txt`. Their skills are symlinked live into `~/.claude/skills/`.
- **Library** — everything else: indexed in `SKILLS.md` and searchable via `skill-scout`, but not symlinked. Keeps the active skill set sane even as the-grid indexes thousands of ecosystem skills.

On each run, `scripts/wire.sh`:

1. Tears down all grid-owned symlinks (anything pointing into this repo).
2. Re-wires skills from repos in `wired-submodules.txt`, discovered at any nesting depth.
3. Wires `skills/` last — root skills override any same-named repo skill.
4. Leaves symlinks pointing elsewhere untouched.
5. Regenerates `SKILLS.md` via `catalog.sh`.

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
