# the-grid

Centralised skill management for Claude Code, inspired by Tron.

Skills are directories containing a `SKILL.md`. This repo owns some directly and pulls others in from sibling repos via git submodules. A single script (`wire.sh`) symlinks everything into `~/.claude/skills/` so Claude picks them up automatically.

```
~/.the-grid/
  standup/          ← skill owned by the-grid
    SKILL.md
  rubber-duck/
    SKILL.md
  repos/            ← sibling repos as git submodules
    gstack/         (each contains skill dirs)
    gbrain/
  tests/
    test_wiring.bats
    test_skill_format.bats
    test_repo_health.bats
    helpers/setup.bash
    lib/bats-core/  ← test runner (submodule, no install needed)
  wire.sh           ← creates ~/.claude/skills/ symlinks
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

```bash
mkdir ~/.the-grid/my-skill
cat > ~/.the-grid/my-skill/SKILL.md <<'EOF'
---
name: my-skill
description: One-line description and trigger phrases.
---

# My Skill
...
EOF
bash ~/.the-grid/wire.sh
```

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
cd ~/.the-grid
tests/lib/bats-core/bin/bats tests/
```

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, and broken symlink detection.

## How wire.sh works

Skills are split into two tiers:

- **Wired** — repos listed in `wired-submodules.txt`. Their skills are symlinked live into `~/.claude/skills/`.
- **Library** — everything else: indexed in `SKILLS.md` and searchable, but not symlinked.

On each run, wire.sh:

1. Tears down all grid-owned symlinks (anything pointing into this repo).
2. Re-wires skills from repos in `wired-submodules.txt`, discovered at any nesting depth.
3. Wires root-level skills last — they override any same-named repo skill.
4. Leaves symlinks pointing elsewhere untouched.
5. Regenerates `SKILLS.md` via `catalog.sh`.

Override paths via env vars (used by tests):

```bash
GRID_DIR=/path/to/grid SKILLS_DIR=/path/to/skills bash scripts/wire.sh
```
