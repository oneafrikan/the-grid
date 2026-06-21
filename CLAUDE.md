# the-grid — Claude context

the-grid is Gareth's wiring hub for the AI-agent ecosystem — Claude / OpenClaw /
Paperclip / Hermes / opencode and friends. **It is not skills-only**: skills are
the first asset type it wires, but the remit is broader (commands, agents, MCP
servers, plugins, configs may follow). It owns some assets directly and pulls many
more from sibling repos via git submodules.

`wire.sh` symlinks **skills** into `~/.claude/skills/` so Claude picks them up. It
also wires **composed agents** from `agent-factory/` (see below): orchestrator
skills into `~/.claude/skills/`, specialist subagents into `~/.claude/agents/`. To
keep the active set sane while still indexing the whole ecosystem, the-grid splits
submodules into two tiers:

- **Wired** — a small curated allowlist whose skills are symlinked live into
  `~/.claude/skills/`. The allowlist is **layered**: a shared
  `baseline-submodules.txt` (wired on every machine) plus an optional per-machine
  overlay at `machines/<hostname>.txt` (host = `hostname -s`) that adds or
  subtracts entries. wire.sh unions baseline + overlay.
- **Library** — everything else: indexed in `SKILLS.md` and searchable by
  `skill-scout`, but **not** wired (so a session isn't drowned in thousands of
  skills). Promote a library repo to wired by adding its name to the baseline.

## What lives where (ownership principle)

- **Root-level dirs are for skills Gareth owns or has edited for his own purposes.**
  Only put a skill at the repo root if it's original to the-grid, or if it's an
  upstream skill that's been deliberately forked/edited and must not track upstream.
- **Everything else is managed upstream** in `repos/*` submodules and wired on
  demand. Don't copy an upstream skill into the root just to use it — the submodule
  copy gets wired automatically.
- If a root skill is byte-identical to (or merely an older snapshot of) a submodule
  copy, it's redundant: delete the root dir and let the submodule own the slot.
- When root and submodule both provide the same skill name, **the root copy wins**
  (wire.sh wires repos first, root last). That's the escape hatch for an edited fork.

## Key files

- `BOOTSTRAP.md` — **full machine boot sequence**: clone → submodules → wire skills → compose agents → wire agents. Start here on a new machine.
- `scripts/wire.sh` — the wiring script. Idempotent. Tears down all grid-owned symlinks
  and rebuilds the wired set each run (so un-wiring a repo actually removes it).
- `baseline-submodules.txt` — the baseline allowlist of submodules whose skills are
  wired live on **every** machine. Anything not listed is library-only. Also gates
  composed projects via `project:<name>` entries. Delete the file to wire everything (legacy).
- `machines/<hostname>.txt` — per-machine overlay layered on the baseline (`hostname -s`).
  Adds (`repo`, `repo/skill`, `project:<name>`) or subtracts (`-repo`, `-repo/skill`,
  `-project:<name>`) for that host only. Absent overlay → baseline as-is.
- `scripts/catalog.sh` — regenerates `SKILLS.md`: wired skills in full detail, library
  repos as counts, reference (no-skill) repos in a footer. Deterministic output.
- `SKILLS.md` — generated index of the whole ecosystem. Never edit by hand.
- `tests/` — bats test suite. Run with `tests/lib/bats-core/bin/bats tests/`.
- `repos/` — sibling skill repos as git submodules. Each submodule may contain multiple skill dirs.
- `TODO.md` — current outstanding work.

## Adding a skill

Create a directory at the repo root with a `SKILL.md` inside it. Frontmatter requires `name:` and `description:`. Then run `bash scripts/wire.sh`.

## Regenerating the skill catalogue

```bash
bash scripts/catalog.sh        # rewrites SKILLS.md from every SKILL.md's frontmatter
```

`scripts/wire.sh` calls `scripts/catalog.sh` automatically as its final step, so wiring and
`SKILLS.md` never drift — you rarely need to run it by hand. Output is sorted and
timestamp-free, so an unchanged skill set yields an identical file (clean diffs).
A repo-root `SKILL.md` (gstack marker) is excluded, matching wire.sh.

## Adding a sibling repo

```bash
git submodule add <repo-url> repos/<name>
git submodule update --init
bash scripts/wire.sh
```

A newly added submodule is **library by default** (indexed, not wired). To wire its
skills live everywhere, add its `repos/<name>` dir name to `baseline-submodules.txt`
(or to a single machine's `machines/<host>.txt` overlay) and re-run
`bash scripts/wire.sh`. This keeps `~/.claude/skills/` small even as the-grid indexes
thousands of ecosystem skills.

### Reference submodules (indexes, not skill collections)

Some submodules are awesome-lists / indexes with **no `SKILL.md` files** (e.g.
`repos/voltagent` — VoltAgent's `awesome-openclaw-skills`, a categorised index of
OpenClaw-ecosystem skills). These are kept for browsing and as a source for
`skill-scout`, not for wiring. They need no special config: wire.sh wires nothing
from them (no skills to find), and catalog.sh auto-detects the empty case and lists
them under "Reference submodules" in `SKILLS.md` instead of an empty skill section.
Refresh one with `git submodule update --remote repos/<name>`.

## Reconciling a machine (removing stale shadows)

`wire.sh` won't clobber a *real* directory that shadows a grid skill (safety).
On a fresh machine those shadows are often stale, root-owned copies. `reconcile.sh`
removes them so the-grid owns the slot, then re-wires. It parses wire.sh's own
`skip (real dir, not managed)` output, so it never hardcodes names.

```bash
bash scripts/reconcile.sh          # dry run — list shadowing dirs
bash scripts/reconcile.sh --force  # remove them (sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

All 30 tests must stay green. Tests use temp dirs — they never touch the real `~/.claude/skills/` or `~/.claude/agents/`.

## wire.sh contract

- `GRID_DIR` env var overrides the repo root (default: script's own directory).
- `SKILLS_DIR` env var overrides the skills target (default: `~/.claude/skills/`).
- `AGENTS_DIR` env var overrides the subagents target (default: `~/.claude/agents/`).
- Only manages symlinks that point into `GRID_DIR` — never touches foreign symlinks.
- Skills in `repos/*/` are discovered at **any depth** via `find` (flat, `skills/`,
  `skills/<category>/`, etc.) — wire.sh symlinks each dir containing a `SKILL.md`,
  skipping a `SKILL.md` sitting at a repo root.
- Only submodules in the manifest (`baseline-submodules.txt` + `machines/<host>.txt`
  overlay) are wired; the rest are library-only. If no manifest exists, all repos are
  wired (legacy fallback). `catalog.sh` reads the **baseline only** (machine-agnostic,
  deterministic `SKILLS.md`).
- **Machine key:** `GRID_HOST` env var overrides the overlay host (default `hostname -s`).
- **Composed agents:** wire.sh also wires `agent-factory/projects/*/_claude-code/`
  output — orchestrator skills into `SKILLS_DIR`, specialist subagents into
  `AGENTS_DIR`. Gated per machine by `project:<name>` manifest entries; with no
  `project:` entry anywhere, every composed project wires (legacy). The baseline
  currently pins `project:full-team` (see `agent-factory/` and issue #1).

## agent-factory (composed agents)

`agent-factory/` composes AI dev-team agents from a single config
(`role × stack × skills`). `compose.py` is a multi-target compiler: one source (the
live OpenClaw 5-file identity model — SOUL/IDENTITY/AGENTS/USER/MEMORY + skills)
emits to different runtimes via `--target`. The **Claude Code** target is built and
wired live: orchestrator roles (`role.yaml orchestrator: true`) → CC **skills**
(invoke with `/<role>`); specialist roles → CC **subagents** (delegate to them, or
an orchestrator hands off). OpenClaw + Paperclip (autonomous) targets are the next
work. See `agent-factory/README.md` and `LOGS/2026-06-16-handoff-agent-factory.md`.

**Orchestrator rosters are generated, not hand-written.** Each orchestrator declares
its reports via `delegates_to:` in the compose config (the delegation topology lives
with the team, the single source of truth). `compose.py` renders a roster table from
that list and injects it at the `{{ROSTER_TABLE}}` token in the role's `AGENTS.md`
(`owns` text = `role.yaml owns:` override, else the summary's first sentence). Validation
is symmetric and loud: a token with no `delegates_to` (or vice-versa), or a delegate not
on the team, is a hard compose error — so a roster can never silently drift out of sync
with the team. full-team topology: `ceo → tech-lead, product-manager, growth-hacker`;
`tech-lead → eng + data/research`; `growth-hacker → the marketing arm` (a player-coach
orchestrator).

> **Rollout note:** `agent-factory/projects/*` is git-ignored (regenerable output). A
> machine picks up roster/topology changes only after `git pull` **then re-running
> `compose.py`** (BOOTSTRAP step 4) and `wire.sh` — pulling alone is not enough.

## About

the-grid is Gareth's brainchild — a personal, evolving system for organising and
wiring up his Claude skills. Intended to eventually be a public repo. Treat it as
an extension of how Gareth thinks and works, and keep it tidy as it grows.
