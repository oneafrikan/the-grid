# the-grid — Claude context

the-grid is Gareth's wiring hub for the AI-agent ecosystem — Claude / OpenClaw /
Paperclip / Hermes / opencode and friends. **It is not skills-only**: skills are
the first asset type it wires, but the remit is broader (commands, agents, MCP
servers, plugins, configs may follow). It owns some assets directly and pulls many
more from sibling repos via git submodules.

Today, `wire.sh` symlinks **skills** into `~/.claude/skills/` so Claude picks them
up. To keep the active set sane while still indexing the whole ecosystem, the-grid
splits submodules into two tiers:

- **Wired** — a small curated allowlist (`wired-submodules.txt`) whose skills are
  symlinked live into `~/.claude/skills/`.
- **Library** — everything else: indexed in `SKILLS.md` and searchable by
  `skill-scout`, but **not** wired (so a session isn't drowned in thousands of
  skills). Promote a library repo to wired by adding its name to the allowlist.

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

- `wire.sh` — the wiring script. Idempotent. Tears down all grid-owned symlinks
  and rebuilds the wired set each run (so un-wiring a repo actually removes it).
- `wired-submodules.txt` — the allowlist of submodules whose skills are wired live.
  Anything not listed is library-only. Delete the file to wire everything (legacy).
- `catalog.sh` — regenerates `SKILLS.md`: wired skills in full detail, library
  repos as counts, reference (no-skill) repos in a footer. Deterministic output.
- `SKILLS.md` — generated index of the whole ecosystem. Never edit by hand.
- `tests/` — bats test suite. Run with `tests/lib/bats-core/bin/bats tests/`.
- `repos/` — sibling skill repos as git submodules. Each submodule may contain multiple skill dirs.
- `TODO.md` — current outstanding work.

## Adding a skill

Create a directory at the repo root with a `SKILL.md` inside it. Frontmatter requires `name:` and `description:`. Then run `bash wire.sh`.

## Regenerating the skill catalogue

```bash
bash catalog.sh        # rewrites SKILLS.md from every SKILL.md's frontmatter
```

`wire.sh` calls `catalog.sh` automatically as its final step, so wiring and
`SKILLS.md` never drift — you rarely need to run it by hand. Output is sorted and
timestamp-free, so an unchanged skill set yields an identical file (clean diffs).
A repo-root `SKILL.md` (gstack marker) is excluded, matching wire.sh.

## Adding a sibling repo

```bash
git submodule add <repo-url> repos/<name>
git submodule update --init
bash wire.sh
```

A newly added submodule is **library by default** (indexed, not wired). To wire its
skills live, add its `repos/<name>` dir name to `wired-submodules.txt` and re-run
`bash wire.sh`. This keeps `~/.claude/skills/` small even as the-grid indexes
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
bash reconcile.sh          # dry run — list shadowing dirs
bash reconcile.sh --force  # remove them (sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

All 28 tests must stay green. Tests use temp dirs — they never touch the real `~/.claude/skills/`.

## wire.sh contract

- `GRID_DIR` env var overrides the repo root (default: script's own directory).
- `SKILLS_DIR` env var overrides the target (default: `~/.claude/skills/`).
- Only manages symlinks that point into `GRID_DIR` — never touches foreign symlinks.
- Skills in `repos/*/` are discovered at **any depth** via `find` (flat, `skills/`,
  `skills/<category>/`, etc.) — wire.sh symlinks each dir containing a `SKILL.md`,
  skipping a `SKILL.md` sitting at a repo root.
- Only submodules in `wired-submodules.txt` are wired; the rest are library-only.
  If the file is absent, all repos are wired (legacy fallback). `catalog.sh` reads
  the same file to label wired vs library.

## About

the-grid is Gareth's brainchild — a personal, evolving system for organising and
wiring up his Claude skills. Intended to eventually be a public repo. Treat it as
an extension of how Gareth thinks and works, and keep it tidy as it grows.
