# the-grid — Claude context

Skill management repo for Claude Code. Owns skills directly and pulls others
from sibling repos via git submodules. `wire.sh` creates symlinks into
`~/.claude/skills/` so Claude picks them up.

## Key files

- `wire.sh` — the wiring script. Idempotent. Safe to re-run after any change.
- `tests/` — bats test suite. Run with `tests/lib/bats-core/bin/bats tests/`.
- `repos/` — sibling skill repos as git submodules. Each submodule may contain multiple skill dirs.
- `TODO.md` — current outstanding work.

## Adding a skill

Create a directory at the repo root with a `SKILL.md` inside it. Frontmatter requires `name:` and `description:`. Then run `bash wire.sh`.

## Adding a sibling repo

```bash
git submodule add <repo-url> repos/<name>
git submodule update --init
bash wire.sh
```

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

All 15 tests must stay green. Tests use temp dirs — they never touch the real `~/.claude/skills/`.

## wire.sh contract

- `GRID_DIR` env var overrides the repo root (default: script's own directory).
- `SKILLS_DIR` env var overrides the target (default: `~/.claude/skills/`).
- Only manages symlinks that point into `GRID_DIR` — never touches foreign symlinks.
- Skills in `repos/*/` are wired one level deep (repo → skill-dir → SKILL.md).

## GitHub

Repo: `git@github.com:gkwilderness/the-grid.git` (Wilderness account, default SSH host).
