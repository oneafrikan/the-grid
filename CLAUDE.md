# the-grid — Claude context

Skill management repo for Claude Code. Owns skills directly and pulls others
from sibling repos via git submodules. `wire.sh` creates symlinks into
`~/.claude/skills/` so Claude picks them up.

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

- `wire.sh` — the wiring script. Idempotent. Safe to re-run after any change.
- `catalog.sh` — regenerates `SKILLS.md`, a human-readable catalogue of every
  wired skill (name + summary, grouped by source). Deterministic output.
- `SKILLS.md` — generated reference list of all skills. Never edit by hand.
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

All 24 tests must stay green. Tests use temp dirs — they never touch the real `~/.claude/skills/`.

## wire.sh contract

- `GRID_DIR` env var overrides the repo root (default: script's own directory).
- `SKILLS_DIR` env var overrides the target (default: `~/.claude/skills/`).
- Only manages symlinks that point into `GRID_DIR` — never touches foreign symlinks.
- Skills in `repos/*/` are discovered at **any depth** via `find` (flat, `skills/`,
  `skills/<category>/`, etc.) — wire.sh symlinks each dir containing a `SKILL.md`,
  skipping a `SKILL.md` sitting at a repo root.

## About

the-grid is Gareth's brainchild — a personal, evolving system for organising and
wiring up his Claude skills. Intended to eventually be a public repo. Treat it as
an extension of how Gareth thinks and works, and keep it tidy as it grows.
